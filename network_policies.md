# Network Policies — per-tenant isolation

Part of §7 (production hardening). BrowseTerm runs **untrusted `root` shells** in per-user
namespaces (`{user_id}-namespace`). This documents how NetworkPolicies isolate those workloads,
in the format: **problem faced → solution thought of → implementation.**

---

## 1. Problem faced

A user's terminal is a root shell we don't control. By default in Kubernetes, **a pod can reach
every other pod and service in the cluster** — namespaces are an *organizational* boundary, not a
network one. So today a user could, from their terminal:

- `psql` straight into `browseterm-pg` (our database),
- hit `browseterm-redis` / `minio`,
- reach **other tenants'** terminals (lateral movement),
- talk to the Kubernetes API and arbitrary in-cluster IPs.

The `NetworkPolicy` that already existed in `NamespaceManager.create` was an effective **no-op** —
`policyTypes: [Ingress]` with an ingress rule that allowed all sources = "allow everything." Zero
isolation.

Two constraints make this harder than "just deny everything":

1. **The status-sidecar shares the user's pod.** NetworkPolicy is *pod-level*, so any rule applies
   to the user's shell **and** the sidecar identically. But the sidecar legitimately needs
   **Postgres** (to write container status) and the **k8s API** (to watch pod phase). We can't
   blanket-deny those without breaking status updates.
2. **A dev terminal needs the internet.** Users run `apt install`, `git clone`, `pip install`. So
   we can't block egress wholesale — but "allow the internet" naively also re-opens everything
   *internal*, because internal services have IPs too.

---

## 2. Solution thought of

**Default-deny, then whitelist only what the workspace legitimately needs** — accepting that,
because the sidecar shares the pod, a couple of internal targets (Postgres, the API) stay reachable
by the shell, but they're password/RBAC-gated (defense-in-depth, not a hole).

The whitelist, per user namespace:

| Allow | Why |
|---|---|
| DNS egress → kube-dns `:53` | resolve service names |
| Ingress from the `browseterm` namespace → `:22` | socket-ssh connects the terminal |
| Egress → `browseterm` namespace `:5432` | the sidecar writes status to Postgres |
| Egress → the **internet, minus the cluster's own ranges** | dev terminal (apt/git/pip) without re-opening internal targets |

### The key idea: "internet minus the cluster"

The internet rule is the subtle one. We want egress to `0.0.0.0/0` (the internet) **but not** to
anything inside the cluster. The trick is that all internal traffic lives on two private IP ranges:

- **Pod CIDR** (e.g. `10.1.0.0/16`) — every pod's IP. "Reach another pod / tenant" = an IP here.
- **Service CIDR** (e.g. `10.96.0.0/12`) — every ClusterIP Service (Redis, MinIO, …). "Reach an
  internal service" = an IP here.

So we allow `0.0.0.0/0` **`except`** those two ranges:

```yaml
ipBlock:
  cidr: 0.0.0.0/0        # everything...
  except:
    - 10.1.0.0/16        # ...but NOT pod IPs    (other tenants / pods)
    - 10.96.0.0/12       # ...but NOT service IPs (Redis, MinIO, ...)
```

External IPs (github/pypi/apt) aren't in those ranges → allowed. Anything in-cluster is → blocked.
That is literally "the internet minus our cluster."

Notes on the design:
- The **other** allow rules use `namespaceSelector` (label-based) because they target *specific
  in-cluster pods*, which NetworkPolicy can select by label. The internet has no labels — for
  external ranges you can only use `ipBlock`, so "external yes, internal no" *must* be expressed by
  listing the internal CIDRs in `except`.
- The pod & service CIDRs are **per-cluster** (docker-desktop ≠ EKS/Calico). If they don't match the
  real ranges, the carve-out is wrong (too narrow → internal leaks; too broad → internet blocked).
  So they're configurable via `POD_CIDR` / `SERVICE_CIDR` env, defaulted to docker-desktop's.
- The **k8s API** (needed by the sidecar) is reached via this internet rule: `kubernetes.default`
  DNATs to the API's real endpoint, a *node/host* IP that sits **outside** the pod/service CIDRs, so
  it's allowed by the internet rule (not the `except`).
- What this deliberately does **not** solve: crypto-mining over the (allowed) internet egress — that
  belongs to rate-limiting/abuse + a stronger sandbox (gVisor), not to NetworkPolicy.

---

## 3. Implementation of the solution

Applied to **every `{user_id}-namespace` at creation time** by container-maker — the namespaces are
created dynamically per user, so these can't be static manifests applied once by `setup.sh`.

We used this as the pilot for a **"resources as reviewable YAML that the code renders and applies"**
pattern:

- **`container-maker/src/resources/manifests/user_namespace_netpol.yaml`** — the five policies as a
  YAML template with `${NAMESPACE}` / `${POD_CIDR}` / `${SERVICE_CIDR}` placeholders:
  `default-deny-all`, `allow-dns-egress`, `allow-ingress-from-socket-ssh`, `allow-egress-postgres`,
  `allow-egress-internet-deny-internal`.
- **`container-maker/src/resources/manifest_loader.py`** — `render_manifests(file, subs)` reads the
  template, substitutes `${…}`, and returns the parsed docs as dicts.
- **`NamespaceManager.create`** (`namespace_manager.py`) — after creating the namespace, calls
  `_apply_network_policies(namespace_name)`, which renders the template and applies each policy via
  `NetworkingV1Api().create_namespaced_network_policy(...)` (idempotent: `409 = already exists` is
  ignored). This replaced the old no-op stub.
- **`resource_config.py`** — `POD_CIDR` / `SERVICE_CIDR` from env, docker-desktop defaults
  (`10.1.0.0/16`, `10.96.0.0/12`).
- **Tests** — `tests/unit/resources/test_network_policies.py`: the template renders the five
  policies scoped to the namespace with no leftover placeholders and the correct CIDR carve-out, and
  `_apply_network_policies` applies each one.

RBAC needs no change — container-maker already created a NetworkPolicy (the old stub), so its
ServiceAccount can already create them.

### ⚠️ Enforcement caveat

NetworkPolicy is only **enforced** by a policy-capable CNI (Calico / Cilium). **docker-desktop's
default CNI accepts these resources but does not enforce them** — locally they apply cleanly and do
nothing. Actual enforcement must be validated on the real (cloud/EU) cluster where Calico/Cilium is
installed. The manifests are written to be correct regardless.

### Not yet done (rest of §7 isolation)

Pod-security hardening (drop capabilities, seccomp, no hostPath/hostNetwork), static policies for the
fixed `browseterm`/`observability` namespaces, and the heavier **gVisor/Kata** sandbox.

---

# ResourceQuota + LimitRange — per-tenant resource caps

Same §7 isolation goal, same template-loader pattern as the NetworkPolicies above.

## 1. Problem faced

Network isolation stops a tenant *reaching* other things; it does nothing about a tenant *consuming*
everything. A user's root shell (or a `fork` bomb / `stress` / a mining job) can request unbounded
CPU/memory or spawn unbounded pods, starving the node and every **other tenant** on it — a
noisy-neighbor + DoS + runaway-cost problem. Kubernetes' default is **no limit** on what a namespace
may consume in aggregate. We set per-container limits in the pod spec today, but nothing enforces a
**namespace-wide total**, and nothing stops a client from omitting or inflating those per-container
values.

A second requirement pulls the other way: we want users to **resize their resources** (upgrade /
downgrade their plan). So the cap can't be a permanent wall baked in at creation — it has to track
the user's current entitlement.

## 2. Solution thought of

Two complementary Kubernetes objects per user namespace:

- **ResourceQuota** — the namespace-wide **total** cap: aggregate `requests/limits.cpu/memory`,
  total `requests.storage`, and object counts (`pods`, `persistentvolumeclaims`). This is the real
  new protection — the per-tenant DoS / cost bound.
- **LimitRange** — per-**container** `default` / `defaultRequest` / `max`. Two jobs: give every
  container a sane ceiling it can't exceed, *and* supply defaults — because once the quota sets
  `requests.*`/`limits.*`, a pod that omits them would be **rejected**; the LimitRange defaults are
  what let such pods through. (LimitRange bounds each pod; ResourceQuota bounds the sum.)

**Resizing is not hampered — this is the mechanism for it.** Both objects are *mutable*. The numbers
come from a **tier** (`resource_config.TIERS`, e.g. `free` / `pro`), applied at namespace creation
and **patched** when the plan changes (`update_resource_limits`). So "resize a user" = "swap the tier
numbers and re-apply". The tier numbers will eventually be driven by the payments/subscription
service. Direction semantics:
- **Increase** — raise the quota *first*, then grow/recreate the pod (a pod exceeding the current
  quota is rejected).
- **Decrease** — lowering the quota does **not** evict running pods that now exceed it; the smaller
  cap applies to the **next pod (re)created**. That fits BrowseTerm's recreate-on-resume model — a
  downgrade lands on the next resume.

## 3. Implementation of the solution

- **`manifests/user_namespace_quota.yaml`** — `ResourceQuota` (`tenant-quota`) + `LimitRange`
  (`tenant-limits`) as one template; placeholders `${NAMESPACE}` + the full tier value set
  (`${MAX_PODS}`, `${TOTAL_CPU_LIMITS}`, `${DEFAULT_CPU}`, `${MAX_MEMORY_PER_CONTAINER}`, …).
- **`resource_config.py`** — `TIERS` (`free`, `pro`) as the full substitution sets, `DEFAULT_TIER`,
  and `tier_substitutions(namespace, tier)` (unknown tier → default).
- **`CreateNamespaceDataClass.tier`** (default `"free"`) — threads the plan through namespace create.
- **`NamespaceManager`** — `create` now also calls `_apply_resource_limits(ns, tier)`;
  `update_resource_limits(ns, tier)` is the resize/plan-change path. Both share
  `_render_and_apply_resource_limits`, which **creates each object, and on `409` patches** it to the
  (possibly new) tier numbers — so create is idempotent and update re-syncs.
- **Tests** — `tests/unit/resources/test_resource_limits.py`: template renders per tier with no
  leftover placeholders, quota carries the tier numbers, LimitRange has default+max, pro > free,
  unknown tier falls back, and create applies both objects / falls back to patch on 409 / update
  patches with the new tier's numbers.

Unlike NetworkPolicy, **ResourceQuota + LimitRange ARE enforced by vanilla Kubernetes** (the
scheduler/quota admission controllers), including on docker-desktop — so this one is verifiable
locally.
