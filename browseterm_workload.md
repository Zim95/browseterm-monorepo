# browseterm_workload — platform components + credential re-architecture

Design doc for a §7 hardening effort with three coupled parts:

1. **status_monitor** — replace the per-pod `status_sidecar` with ONE central pod-status watcher.
2. **Secret migration** — stop shipping DB/object-store credentials through pod env; move them to
   Kubernetes Secrets that the user pod can never read.
3. **`browseterm_workload` repo** — consolidate the four background/platform components
   (`cert-manager`, `reaper`, `snapshot_job`, `status_monitor`) into one repo.

Format follows `network_policies.md`: **problem → solution → implementation.**

The through-line: today the untrusted user pod carries database credentials. The env-split
(`SIDECAR_ONLY_ENV_PREFIXES` in `pod_manager.py`) was a band-aid. This effort removes the credentials
from the tenant blast radius **entirely**, and as the payoff lets us **delete the
`allow-egress-postgres` NetworkPolicy** — because the user pod will no longer have any reason to reach
Postgres.

---

## Part 1 — status_monitor (central pod-status watcher)

### 1.1 Problem faced

`status_sidecar` runs as a **second container inside every user pod**. It watches its own pod
(`field_selector=metadata.name={pod_name}`) and writes `pod.status.phase` to the container's DB row,
keyed by a `CONTAINER_ID` env injected at creation. It works, but the per-pod placement is the root of
three problems:

- **Credentials in the blast radius.** The sidecar needs DB creds to write status, and it shares the
  pod's network + (until the env-split) its env with the user's root shell. NetworkPolicy is
  *pod-level*, so we cannot network-isolate "only the sidecar reaches Postgres" while it lives in the
  user pod — which is exactly why `allow-egress-postgres` has to leave :5432 open to the whole pod.
- **Cost scales with tenants.** One sidecar container **per user pod** = N status-writer processes and
  N DB connections. Wasteful and a DB-connection ceiling.
- **Duplicated RBAC/SA surface.** Every user pod gets a ServiceAccount + Role + RoleBinding
  (`_ensure_status_sidecar_rbac`) and runs under the sidecar's SA — whose token is mounted into the
  untrusted container too.

### 1.2 Solution thought of

**One cluster-wide `status_monitor` Deployment** that watches *all* user pods across *all* namespaces
and writes each one's phase to the DB. This is a minimal Kubernetes controller. The **reaper** is the
reference implementation to copy — it is already a standalone pod that reads creds from Secrets via the
API (`K8sSecretsReader`) and talks to the DB / gRPC.

**The one hard part — identity.** The per-pod sidecar knew *which* container it was responsible for
from its injected `CONTAINER_ID`. A central watcher sees a stream of pod events with no per-pod env, so
it must answer *"this pod → which DB row?"* for every event. The write path requires it:

```python
container_ops.update(filters={"id": container_id}, data={"status": ContainerStatus(phase)})
```

**Answer: stamp `container_id` onto the pod as a label at creation time.** The monitor then reads
`pod.metadata.labels["browseterm/container-id"]` straight off each watch event — no per-event DB
lookup.

**Format — RESOLVED (use a label, not an annotation).** `containers.id` is
`Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)` — a 36-char UUID string
(`[0-9a-f-]`, alphanumeric ends). That is a valid Kubernetes **label value** (≤63 chars, charset OK),
so a label is safe and preferable to an annotation (labels are selector-indexed).

Two correctness requirements that the per-pod sidecar never had:

- **Startup reconcile.** On (re)start the monitor must `list` all current user pods and write their
  current phase *before* streaming, or any transition during its downtime is lost. The sidecar was born
  with its pod, so it never missed the initial state.
- **Watch resilience.** Long-lived `watch` streams expire and return `410 Gone`; the monitor must
  re-list to get a fresh `resourceVersion` and resume. It should also **dedup** (skip a write when the
  phase is unchanged) to avoid hammering the DB.

### 1.3 Implementation of the solution

**container-maker (`pod_manager.py`):**
- Add `container_id` to the user pod's labels (today `labels={"app": container_name}`), e.g.
  `labels={"app": container_name, "browseterm/managed": "user-pod", "browseterm/container-id": cid}`.
  The `browseterm/managed` label is the monitor's watch selector.
- **Remove** the `status-sidecar` `V1Container` from the pod spec.
- **Remove** `_ensure_status_sidecar_rbac` and the pod's `service_account_name=STATUS_SIDECAR_...`.
  The user pod reverts to the default SA with **`automount_service_account_token=False`** (closes the
  secondary SA-token hole — the untrusted shell should hold no API token).
- The `sidecar_environment_variables` / `main_environment_variables` split becomes moot once creds no
  longer flow through env at all (Part 2) — the main container simply gets its non-credential env.

**status_monitor (new service — copy the reaper scaffold):**
- `pod_watcher`: `list_pod_for_all_namespaces(label_selector="browseterm/managed=user-pod")` for the
  startup reconcile, then `watch.Watch().stream(...)` from the returned `resourceVersion`; on `410`
  re-list. For each event, read `container_id` from the pod label and call the existing
  `update_container_status` write path.
- `config`/`db_ops`: reuse the sidecar's `UpdateContainerStatus` + `ContainerOps` write; DB creds come
  from a Secret (Part 2), not env.
- **RBAC widens to cluster scope**: a `ClusterRole` (`pods: get/list/watch`) + `ClusterRoleBinding` to
  the monitor's SA (the sidecar had a namespaced `Role`).
- **Deployment**: single replica to start. >1 replica needs leader election or sharding
  (see §4, out of scope) — two replicas would double-write, which is harmless but wasteful.

---

## Part 2 — Secret migration (env credentials → Kubernetes Secrets)

### 2.1 Problem faced

`browseterm-server/src/api_handlers.py` builds the pod env dict in **two** places (create ~L146,
resume ~L385) and injects `DB_HOST`/`DB_PORT`/`DB_USERNAME`/`DB_PASSWORD`/`DB_DATABASE` into every pod.
So the credentials:
- transit through the gRPC create request,
- land in pod env (readable by anything in the pod — the env-split only narrowed *which* container),
- and are duplicated across every tenant.

### 2.2 Solution thought of

Credentials live as **Kubernetes Secrets created at cluster setup** (one per datastore:
`postgres`, `redis`, `minio`), in the `browseterm` namespace. **Trusted** pods consume them; the
**user pod gets nothing**.

- Trusted consumers (`browseterm-server`, `status_monitor`, `reaper`, `snapshot_job`) read creds via
  `envFrom: { secretRef: ... }` in their **own** deployment specs, or via the reaper's
  `K8sSecretsReader` (direct API read). Either is fine; `envFrom` is simplest for the always-on pods.
- **User pods**: no DB env, no DB Secret mounted, no SA token. With no credentials *and* the
  `allow-egress-postgres` rule removed, the user pod has neither the means nor the route to Postgres.

**Payoff:** once no user pod needs Postgres, **delete `allow-egress-postgres` from
`user_namespace_netpol.yaml`** and update `test_network_policies.py`. "Only trusted pods reach PG"
becomes true by construction — the network rule isn't even needed to enforce it.

### 2.3 Implementation of the solution

- **Cluster setup** (`scripts/setup.sh` + a secrets manifest, alongside the Postgres/Redis/MinIO
  bring-up in `postgres_ha` / `redis_ha`): create `postgres` / `redis` / `minio` Secrets. Ideally the
  datastore and its Secret are created together so creds have a single source of truth.
- **browseterm-server**: stop threading DB creds into `environment_variables` at both `api_handlers.py`
  sites. The server still needs DB creds *for itself* — supply them via `envFrom: secretRef` in the
  server's own deployment.
- **status_monitor**: DB creds via `envFrom: secretRef` in its deployment.
- **snapshot_job — RESOLVED (move it; the move is clean via object storage).** The Job is created by
  `job_manager` **in the user's namespace** today. But the Job **does not touch the user pod at all** —
  verified: its flow is `storage.localize(tar) → unpack → build image → push to registry → record in
  Postgres`. The privileged "tar the pod rootfs" step is done *earlier by container-maker*
  (`ExecUtility` exec into the pod), which already has cluster-wide exec and already runs centrally.
  The Job is a pure downstream worker. Its *only* tie to the user namespace is the **storage layer**:
  - `local` (current default): the tar sits on a per-user-namespace RWO **PVC** (`SNAPSHOT_PVC_NAME`),
    which is namespace-bound → the Job is pinned there.
  - `minio` (object storage): the tar is an object → the Job has **zero** coupling to the user
    namespace; it needs only the object key + creds.

  **Decision: standardize saves on object storage (MinIO), then run snapshot_job in the trusted
  `browseterm-workload` namespace** with MinIO/PG/repo creds from Secrets. No cross-namespace exec, no
  cross-namespace volume, no RBAC into user namespaces, and **no new broad privilege** (the only
  privileged actor, container-maker's pod-exec, already exists centrally). This also lets the per-user
  snapshot PVC + its RBAC be deleted.
- **Remove `allow-egress-postgres`** + its assertions in `test_network_policies.py`.

### 2.4 Namespace model (the invariant this buys)

| Namespace | Contains | Tenant access |
|---|---|---|
| `{user_id}-namespace` | **only the user's own pod** — nothing else | n/a (it's theirs) |
| `browseterm-workload` (new) | status_monitor, reaper, cert-manager, snapshot_job — all credentialed | **none** |
| `browseterm` | request-serving control plane: server, socket-ssh, container-maker, PG, redis | **none** |

The goal state is that a **tenant namespace holds exactly one thing: the user pod** — no Secret, no
PVC, no extra ServiceAccount/token, no credentialed worker. That makes the per-tenant RBAC /
NetworkPolicy maximally strict and the blast radius of a tenant compromise trivially auditable. A
**dedicated `browseterm-workload` namespace** (separate from the `browseterm` control plane) is
defense-in-depth: a compromised batch worker is not the same SA/namespace as the API.

**Tradeoff, named honestly:** centralization concentrates trust in a few SAs (container-maker's exec
power; the snapshot runner). But they live where tenants cannot reach and are our own code — strictly
better than credentials sitting inside tenant namespaces.

---

## Part 3 — the `browseterm_workload` repo

### 3.1 Problem faced

The four platform components are scattered: `cert-manager/` is top-level, `reaper` and `snapshot_job`
live under `browseterm-dockerfiles/` next to user-image Dockerfiles, and `status_monitor` doesn't
exist yet. They share nothing structurally despite being the same *kind* of thing: background/platform
workloads that are **not** request-serving.

### 3.2 Solution thought of

One repo, **`browseterm_workload`**, housing all four. Grouped by role (platform/background), not by
Kubernetes `kind` — note the mix:

| Component      | Workload kind | Trigger            |
|----------------|---------------|--------------------|
| cert-manager   | CronJob       | scheduled          |
| reaper         | CronJob       | scheduled (hourly) |
| snapshot_job   | Job           | per-save (in code) |
| status_monitor | Deployment    | always-running     |

(3 of 4 are batch — which is why a literal name like `jobs` was rejected in favor of `workload`.)

### 3.3 Implementation of the solution

- New repo / monorepo submodule `browseterm_workload`; move `cert-manager`, `reaper`, `snapshot_job`
  in, add `status_monitor`.
- Fix per-component Makefiles, image names, and deployment manifests for the new paths.
- Update the monorepo **submodule + hostPath deploy wiring** — deployed code is submodule copies via
  hostPath, so this is more than a `git mv` (see the deploy-topology gotcha).
- **Note:** `snapshot_job`'s Job *spec* is constructed in `container-maker`'s `job_manager`, not from a
  static manifest — only the job's image/source moves; the spec stays in container-maker.
- **Do this LAST** — moving build/deploy plumbing while the components are still changing means editing
  it twice.

---

## Part 4 — sequencing, risks, out of scope

**Sequencing:** Part 1 (status_monitor) → Part 2 (secrets) → Part 3 (repo move).
Prove the monitor works before changing how creds flow; move the repo only once the pieces are stable.

**Biggest risks:**
- The identity mapping + cross-namespace watch + startup-reconcile logic is the one genuinely new
  design; everything else is copy-and-adapt from reaper/sidecar.
- **Storage-layer dependency:** the clean snapshot_job move (§2.3) requires saves on **object storage
  (MinIO)**; the current default is `local` (a per-user PVC). Standardizing on MinIO is a prerequisite
  for taking snapshot_job out of the tenant namespace — confirm MinIO is the production storage layer.
- The monorepo hostPath/submodule plumbing makes the repo move fiddly.

**Explicitly out of scope (future):**
- Scaling status_monitor past one replica (leader election, or shard by node via DaemonSet / by
  namespace range). One watch/informer handles thousands of pods; revisit when that's the bottleneck.
- Redis HA (currently a single Pod, unlike Postgres/etcd which are StatefulSets).
- Heavier tenant sandboxing (gVisor/Kata) and abuse/rate-limiting on the allowed internet egress.

**Rough estimate:** ~2–2.5 weeks solo. Part 1 is the bulk (3–5d), Part 2 (2–3d), Part 3 (1–2d),
wiring + e2e + cleanup (~2d). Enforcement of the NetworkPolicy change must be validated on the real
CNI cluster (docker-desktop accepts but does not enforce NetworkPolicy).
