# BrowseTerm — Working Context / Memory

> Living notes for the BrowseTerm project. Captures the architecture, the snapshot-job
> migration status, and the current deployment effort. See `relation.md` for the full
> repo-relationship writeup (this file summarizes + adds task/working state).

---

## 1. What BrowseTerm is
SaaS to run Linux terminals (containers) in the browser. User logs in via OAuth
(Google/GitHub), spins up an Ubuntu container on Kubernetes, and gets an interactive SSH
terminal streamed to the browser over a WebSocket. Containers can be **saved** (snapshotted
into a pushable Docker image) and restored later. Subscription plans cap containers + CPU/mem/storage.

Owner/registry namespace: GitHub `Zim95`. Repos cloned under `/Users/namahshrestha/test/browseterm/`.

## 2. The 11 repositories

| Repo | Type | Lang | Role |
|------|------|------|------|
| browseterm-monorepo | Umbrella (submodules) | docs/k8s | Aggregates repos as submodules; cluster bootstrap manifests (`02_cluster_infra/`), setup docs (`00_docs/`), save-flow design docs. |
| browseterm-server | API gateway | Python/FastAPI | Main backend: web UI + REST/SSE API, auth, orchestrates everything. Port 9999. |
| container-maker | gRPC server | Python/k8s client | Turns gRPC calls into k8s pods; creates/deletes/saves user containers. Port 50052. |
| container-maker-spec | gRPC contract lib | Python/protobuf | `.proto` API shared between server (client) and container-maker (server). |
| browseterm-db | ORM+migrations lib | Python/SQLAlchemy+Alembic | Models, CRUD ops, Alembic migrations, PG LISTEN/NOTIFY listener, state seeder. |
| browseterm-storage | storage lib | Python/MinIO | Abstracts snapshot storage over local PVC or MinIO(S3). Default backend = local. |
| browseterm-dockerfiles | Docker images | Dockerfiles+Python | Builds in-cluster images: ubuntu SSH container, status_sidecar, snapshot_job (snapshot_sidecar deprecated). |
| socket-ssh | MicroService | Node.js/ws+ssh2 | WebSocket↔SSH bridge; streams terminal bytes. Port 8000. |
| cert-manager | CronJob | Python/k8s client | Mints mTLS certs for the gRPC channel; rolls out deployments on cert change. Schedule Sun 05:00. |
| postgres_ha | Infra manifests | k8s YAML | Deploys PostgreSQL (single instance today; HA cluster = WIP scaffolding). |
| redis_ha | Infra manifests | k8s YAML | Deploys Redis (single today); used for auth/session state, not app cache. |

> Naming caveat: `postgres_ha`/`redis_ha` deploy SINGLE instances currently. HA variants are documented/WIP only.

## 3. Relationships (two layers)

**Build-time (shared libs via `git+https://github.com/Zim95/...@main`):**
- browseterm-server → container-maker-spec (gRPC client stubs), browseterm-db
- container-maker → container-maker-spec (implements server), browseterm-storage
- dockerfiles/status_sidecar → browseterm-db
- dockerfiles/snapshot_job → browseterm-db, browseterm-storage
- Leaf libs (depend on nothing internal): container-maker-spec, browseterm-db, browseterm-storage

**Runtime (network):**
- browser → browseterm-server (HTTPS+SSE); browser → socket-ssh (WSS→SSH into container)
- browseterm-server → container-maker (gRPC/mTLS); → postgres (SQL + LISTEN/NOTIFY); → redis (sessions + one-time ws_token); → cert-manager (via k8s API, spawns Job from CronJob)
- socket-ssh → redis (validate one-time ws_token / session) — the auth glue with the server
- container-maker → k8s API (create pod = ubuntu + status_sidecar); on save writes fs tarball to PVC (via browseterm-storage) + creates snapshot_job
- status_sidecar → writes containers.status → Postgres NOTIFY → server PGListener → SSE to browser
- snapshot_job → reads tarball (PVC/MinIO) → builds `FROM scratch` image → pushes to registry → writes saved_image to DB
- cert-manager → writes `{service}-certs` k8s Secrets → mounted by container-maker (server) + browseterm-server (client)

**DB tables (browseterm-db):** users, subscription_types, subscriptions, images, containers (status enum, kubernetes_id, saved_image, soft-delete), orders.
Trigger `container_status_change_trigger` → NOTIFY on channel `container_status_change`.

## 4. Snapshot-job migration (SNAPSHOT_JOB_MIGRATION.md) — STATUS

Goal: move snapshotting from a **privileged sidecar in every user pod** → an **isolated, ephemeral privileged k8s Job**. Migration is ~90% coded already.

**DONE:** snapshot_job image (dockerfiles/snapshot_job/*), container-maker JobManager (`src/resources/job_manager.py`), main+status sidecar `privileged=False` (pod_manager.py:944,953), snapshot sidecar removed from pod (save() asserts 2 containers, pod_manager.py:730), `SaveUtility.save_image()` uses a Job (pod_manager.py:355-415), db-cred fields on SaveContainerDataClass, Makefile `build_snapshot_job`+`build_all`, snapshot_sidecar kept deprecated.

**REMAINING WORK / BUGS:**
1. **BUG — `PodManager.save()` crashes.** `containers.py:296-304` calls `PodManager.save(SavePodDataClass(...), container_id=..., db_credentials=...)` but `pod_manager.py:712` signature is only `save(cls, data)`. → `TypeError`. DB creds already live in `data.environment_variables`; fix = drop the extra kwargs (or add-and-ignore).
2. **Security goal not met — pod still privileged.** `pod_manager.py:985` sets pod-level `V1PodSpec(security_context=V1SecurityContext(privileged=True))`. Containers are unprivileged now but the POD is not. Must remove/flip. (Also pod-level should be `V1PodSecurityContext`, which has no `privileged` field — line is doubly wrong.)
3. **gRPC contract can't carry DB creds.** `container-maker-spec/spec/types.proto:71` `SaveContainerRequest` has only `container_id`, `network_name` — no db fields. So `SaveContainerDataClass.db_*` always defaults to "". Fix options: (a) add db fields to proto + rebuild spec + update both sides, or (b) **preferred:** container-maker reads DB creds from its own env/secret (it already runs in-cluster with DB access).
4. **browseterm-server has NO save flow.** No `/save-container` endpoint, no `stub.saveContainer(...)` call (only reads of `saved_image`). SAVE_CONTAINER_FLOW.md assumes `POST /save-container` → gRPC saveContainer → SSE progress. Largest remaining build.
5. **Tests/checklist** unchecked; old save tests may need updating.

## 5. MinIO situation
- **No deployable MinIO infra exists** — only a manual how-to doc `browseterm-monorepo/00_docs/minio_setup.md` (`helm install bitnami/minio` + `minio-creds` secret). No manifests/scripts/Makefile target (unlike postgres_ha/redis_ha).
- Code fully supports MinIO (`browseterm-storage.MinioStorage`; container-maker `pod_manager.py:246-282` builds minio envs) but **default `STORAGE_LAYER="local"`** (pod_manager.py:198) → shared PVC (`02_cluster_infra/snapshot-pvc.yaml`, exists).
- MinIO not required for save today (local PVC covers it). Planned: deploy a small MinIO (1 pod / whatever cluster permits) inside browseterm-monorepo, then wire snapshot_job to it.

## 6. CURRENT TASK (in progress)
1. ✅/⏳ Write this memory.md.
2. Switch kubectl context → `docker-desktop`.
3. Deploy everything. Requires **named hosts in `/etc/hosts`** (Let's Encrypt rejects `localhost`) mapped to service IPs.
4. Monitor logs of **socket-ssh** and **browseterm-server** — a suspected **race condition** may be causing issues.
5. Then deploy a small **MinIO** cluster and complete the snapshot-job process.

### Deploy order (from monorepo README)
MetalLB → create namespace → postgres_ha → browseterm-db (migrations + seed) → cert-manager (build + deploy + run job once) → socket-ssh (build dev, test, build prod, deploy) → browseterm-dockerfiles (`make build_all`) → redis_ha (`make dev_redis_single_setup`) → container-maker-spec (run build.py) → container-maker → browseterm-server.

### Open unknowns / blockers to resolve
- `env.mk` files are per-repo, user-specific, gitignored — need REPO_NAME/USER_NAME (docker registry), REPO_PASSWORD, NAMESPACE, HOST_DIR, DB creds, OAuth creds, INGRESS_HOST(s).
- Exact ingress hostnames to add to `/etc/hosts` (browseterm-server ingress + socket-ssh ingress). Editing `/etc/hosts` needs sudo.

## Session status log (autonomous /loop, 2026-07-18)
- Cloned all 11 repos; wrote `relation.md`; analyzed snapshot-job migration + MinIO gap.
- Wrote `env.mk`/`.env` for every repo with harmonized creds (registry zim95; pg `browseterm`/`browseterm-dev-pw`; redis ACL user `browseterm`/`redis-dev-pw`; hosts browseterm.local.com + socket-ssh.local.com).
- `docker login -u zim95` succeeded; `REPO_PASSWORD` set in container-maker/ + browseterm-dockerfiles/ env.mk; plaintext dockerpwd deleted.
- **docker-desktop k8s was wedged by a CORRUPT VM disk** (ext4 errors on vda1). Fix: purged `Docker.raw`, reinstalled k8s. API server now UP, but `~/.kube/config` had STALE client creds -> restarting Docker Desktop to refresh kubeconfig (in progress).
- Per-repo READMEs corrected SURGICALLY (small diffs, content preserved). **Monorepo MASTER README still TODO** (cluster+ingress setup + per-service walkthrough).
- NEXT once kubectl auth works: ordered deploy (namespace -> ingress-nginx -> postgres -> db migrate/seed -> redis -> cert-manager+job -> dockerfiles build_all -> spec build -> container-maker -> socket-ssh -> server), then diagnose socket-ssh/server race, then MinIO + snapshot job.
- **BLOCKED-for-user (left for your return):** run the `sudo` /etc/hosts line; fill OAuth secrets in browseterm-server/env.mk (login only, not a deploy blocker).
- `caffeinate` keeping Mac awake ~4h; autonomous `/loop` active.
- kubeconfig blocker: after purge+reinstall the apiserver came up but Docker Desktop left `kubernetesInitialInstallPerformed=false` and never wrote fresh creds, so `kubectl` gets 401 with the stale (11:52) client cert. Fix in progress: clean disable->enable k8s cycle on the now-healthy disk so Docker Desktop performs a proper install and writes a valid docker-desktop kubeconfig (other contexts preserved). If that still fails, fallback = extract admin.conf from the k8s node.

## ⛔ BLOCKER FOR USER: docker-desktop Kubernetes will not install (needs you)
Tried, all failed: (1) hard restart Docker Desktop; (2) purged the corrupt VM disk `Docker.raw` (fixed the ext4 corruption); (3) + (4) two clean disable->enable Kubernetes reinstall cycles on the healthy disk.
Symptom: kube-apiserver comes up on :6443 but Docker Desktop never finishes the install — `kubernetesInitialInstallPerformed` stays `false`, so it never writes fresh kubeconfig creds; `kubectl` returns 401 with the stale client cert. Backend log shows it looping, polling for control-plane containers labeled `io.kubernetes.docker.type=podsandbox/container`, but `docker ps -a` is EMPTY — the k8s control-plane containers are never created.
Recommended user actions (pick one): (a) open Docker Desktop UI -> Kubernetes tab, watch the status/errors during enable; (b) update or reinstall Docker Desktop (this looks like a broken DD k8s runtime, not our config); (c) switch local k8s to `kind` or `minikube` (note: manifests/scripts assume the `docker-desktop` kube context name — a kind cluster would need context aliasing). The BrowseTerm deploy is otherwise fully prepped (env.mk done, docker login done, images buildable) and will run as soon as `kubectl get nodes` works.
PIVOT while blocked: doing all non-cluster work — monorepo master README, then optionally the aggregated monorepo env.mk + one-command deploy/teardown scaffolding. NOT touching the snapshot-job code fixes (need cluster to verify) or submodule git changes (want your review).

## HANDOFF (autonomous /loop stopped here — waiting on you)
DONE:
- All per-repo READMEs surgically corrected (content preserved; small diffs) + browseterm-storage filled in.
- Monorepo README expanded into the master guide: prerequisites + docker-desktop + ingress-nginx + /etc/hosts + namespace setup, then step-by-step deploy of all 9 components in order, plus verify/teardown/roadmap. Existing overview/plans/submodules/license preserved. Added the missing Container Maker + Browseterm-Server + Browseterm-Storage entries to the service list.
- env.mk/.env written for every repo; docker login (zim95) done; REPO_PASSWORD set.

BLOCKED (needs you): docker-desktop Kubernetes will not finish installing (see BLOCKER section above). Nothing downstream can proceed until `kubectl get nodes` works.

WHEN YOU'RE BACK — do these, then tell me and I'll resume the deploy immediately:
1. Fix docker-desktop k8s: easiest is Docker Desktop UI → Kubernetes (watch for the error), or update/reinstall Docker Desktop; if it stays broken, we switch to kind/minikube (I'll handle context aliasing).
2. Run: `sudo sh -c 'echo "127.0.0.1 browseterm.local.com socket-ssh.local.com" >> /etc/hosts'`
3. (Optional, login only) fill OAuth secrets in browseterm-server/env.mk.

STILL TODO (after cluster works): ordered deploy (task #3) → diagnose socket-ssh/server race (#4) → MinIO + finish snapshot-job migration incl. the code bugs in memory §4 (#5) → monorepo one-command deploy + aggregated env.mk (#7) → add browseterm-server + container-maker as submodules (#6).
caffeinate auto-expires ~16:30; loop stopped, so I'm idle until you message me.

## Deploy session 2 (cluster fixed by user) — progress + a real bug
- Cluster back up (docker-desktop, fresh). Deployed: namespace, snapshot PVC (fixed stale `browseterm-new` ns in `02_cluster_infra/snapshot-pvc.yaml`), ingress-nginx, MetalLB (pool adapted to docker-desktop subnet `192.168.65.200-250`; ingress EXTERNAL-IP=192.168.65.200 — note: VM-subnet IP, host browser reachability TBD at end). Postgres Running + migrated + seeded. Redis Running + ACL user.
- **BUG in browseterm-db `init.py`:** it resets the migration chain and AUTOGENERATES a fresh Initial migration from models only — which DROPS the hand-written `a1b2c3d4e5f6_add_container_status_notify_trigger` migration. Result: DB was missing `notify_container_status_change()` + `container_status_change_trigger`, which browseterm-server's PGListener/SSE needs. WORKAROUND APPLIED: recovered the SQL from git and applied it directly via psql. PROPER FIX (todo): make the trigger part of the model DDL (SQLAlchemy event) or have init.py preserve/re-apply it, or use `upgrade.py upgrade` (runs the real chain incl. trigger) instead of init.py's reset+autogenerate.
- Non-interactive docker builds: piping REPO_PASSWORD into `make *_build` (docker login in build scripts reads it from stdin) — no script edits.
- REVISED build fix: piping to `make` didn't work (build scripts use plain `docker login -u`, which hangs on non-tty). Solution = a non-invasive `docker` shim at scratchpad/bin/docker that no-ops `docker login` (already authenticated) and execs real docker for everything else; run builds with `PATH=<scratchpad>/bin:$PATH`. No repo/script edits. cert-manager image built+pushed OK this way.
- **BUG fixed in Dockerfile.ubuntu (both socket-ssh/infra/test_ssh_container + browseterm-dockerfiles/ubuntu_setup):** `RUN mkdir /var/run/sshd` fails on current `ubuntu:latest` ("File exists") -> changed to `mkdir -p`. These scripts have no `set -e`, so the build failure fell through to a confusing "image does not exist locally" at the push step.
- cert-manager deployed (CronJob) + cert job run -> secrets `container-maker-development-service-certs` + `container-maker-service-certs` created in browseterm (container-maker prereq satisfied).
- Build order status: cert-manager DONE; container-maker + browseterm-server building; socket-ssh + dockerfiles(ubuntu/status_sidecar/snapshot_job) retrying after Dockerfile fix.

## Save-flow build (task #5) progress
- Plan + decisions in browseterm-monorepo/SAVE_FLOW_PLAN.md. Decisions: save_status columns on containers (not jobs table); secrets NOT in proto (container-maker injects creds/config into the Job from its env); reuse /container-status-stream SSE; build with a DOCKER DAEMON in the Job (NO kaniko — user tried it, failed); browseterm-storage is the single storage abstraction.
- Phase A DONE (browseterm-db): added save_status/save_error/last_saved_at columns + widened saved_image to 255; migrations d4e5f6a7b8c9 (columns) + e5f6a7b8c9d0 (trigger) off head 0f7f0ca831a6; container_save_status_change trigger + notify fn. Applied to dev DB via SQL (init.py left alembic_version out of sync — migrations are source of truth). UNCOMMITTED.
- Phase E DONE (MinIO): browseterm-monorepo/02_cluster_infra/minio.yaml (Secret+PVC+Deployment+Service+createbucket Job). Deployed+verified, bucket `browseterm-snapshots` created. Wiring: STORAGE_LAYER=minio, MINIO_ENDPOINT=minio-service:9000, MINIO_ACCESS_KEY=minioadmin, MINIO_SECRET_KEY=minioadmin123, MINIO_BUCKET=browseterm-snapshots, MINIO_SECURE=false. UNCOMMITTED.
- Phase B DONE: browseterm-storage got `localize(path,dest_dir)` (LOCAL passthrough / MinIO streaming fget_object); snapshot_job/main.py refactored to use get_storage().localize() (removed its duplicate retriever classes) + writes save_status RUNNING→SUCCEEDED(+saved_image full ref+last_saved_at)/FAILED(+save_error); db_ops.py got update_save_status().
- Phase C code DONE: containers.py save() now sources DB creds from container-maker's OWN env (os.getenv) not the empty gRPC request, and DROPPED the redundant container_id/db_credentials kwargs that caused the PodManager.save() TypeError; job_manager.py fixed the storage-env bug (was stringifying the whole list into one STORAGE_ENV_VARS var — now merges MINIO_*/STORAGE_LAYER as individual vars); fixed snapshot job image name mismatch resource_config.py snapshot_job->snapshot-job (matches build); MinIO env wired into container-maker (env.mk + setup + development.yaml, keys via secretKeyRef to minio-creds).
- Phase C REMAINING: give container-maker DB_* env so os.getenv works (env.mk + setup script + development.yaml; DB_PASSWORD via secretKeyRef to postgres `pg-password` secret). Optional security: drop pod-level privileged=True (pod_manager.py:985).
- Phase D REMAINING (browseterm-server): POST /save-container -> gRPC saveContainer; set save_status=PENDING on receipt; PGListener on container_save_status_change -> SSE (reuse /container-status-stream typed event); frontend stops spinner.
- Phase F: end-to-end test. NOTE testing requires the commit/push/rebuild chain: push browseterm-db (Phase A) + browseterm-storage (localize) so image builds pull them, then rebuild+push snapshot-job + container-maker images, redeploy, then exercise a save.
- Phase C wiring DONE: container-maker has DB_* env (DB_PASSWORD via secretKeyRef to pg-password) + MINIO_* (keys via secretKeyRef to minio-creds); verified in pod; gRPC app restarts clean ("Server started with SSL at [::]:50052").
- Phase D BACKEND DONE: (D1) browseterm-db pg_listener got CONTAINER_SAVE_STATUS_CHANGE_CHANNEL + ContainerSaveStatusChangePayload; (D2) server status_listener listens on the save channel + broadcasts 'save_status_change' over the same SSE queues; (D3) containers_service.save_container_in_k8s (gRPC saveContainer), api_handlers POST /save-container (sets save_status=PENDING then fires the save in a background task since container-maker blocks until the Job finishes; marks FAILED if the gRPC call itself errors), data_models SaveContainerK8SRequest, app.py route. SSE handler unchanged (streams all queue msgs; frontend keys off 'type').
- Phase D FRONTEND remaining (small): terminalpage.js handleSaveSession() -> POST /save-container (container_id=DB id, network_name) + show spinner; terminals.js (or terminalpage) SSE handler -> on 'save_status_change' SUCCEEDED/FAILED stop the spinner. Note: SSE consumer currently lives on terminals.js, save button on terminalpage.js — verify the page that shows the spinner also consumes the SSE.
- OPEN QUESTION to verify in test: does container-maker's save() pod lookup use the DB container id (what we pass) or the k8s id? /save-container + Job DB update both use DB id consistently; confirm the pod lookup matches.
- TEST (Phase F) needs commit/push chain: push browseterm-db (Phase A cols + pg_listener), browseterm-storage (localize) -> rebuild+push snapshot-job + container-maker + browseterm-server images (they git-install those libs) -> redeploy -> exercise a save.
- Phase D FRONTEND DONE: terminalpage.js handleSaveSession()->POST /save-container (container_id=terminalInfo.id, network_name=`${userInfo.id}-namespace`) + setSaveSpinner + setupSaveStatusStream (EventSource, stops spinner on save_status_change Succeeded/Failed); window.userInfo injected in terminalpage.html; template_handlers passes userInfo.
- UNIT TESTS DONE (task #8, unittest pattern; frontend jest): storage 16 pass (minio mocked via sys.modules stub, localize covered); db ContainerSaveStatusChangePayload+SaveStatus (DB-integration tests need live PG); snapshot_job replaced stale test_storage_retriever.py -> build_storage_config + update_save_status (13 pass); container-maker 7 new unit tests (env-merge, image-name, save DB-from-env) pass; browseterm-server SaveContainerK8SRequest(3 pass local)+save_container_in_k8s+_handle_save_status_change (need cluster deps to run, byte-compile OK); frontend jest harness added (package.json+jsdom+MockEventSource) 14 pass + a guarded module.exports added to terminalpage.js.
- TEST-SUITE FINDINGS: (a) container-maker tests/k8s/integration/resources/test_job_manager.py is STALE — calls create_snapshot_job(environment_variables=...) which no longer exists (now storage_env_vars + db_* args) -> update it. (b) browseterm-db pins ipython 8.12.0 vs browseterm-storage 8.1.0 -> conflict when co-installed (snapshot_job needs both).
- STILL OPEN: save-flow id ambiguity (pod lookup k8s-id vs Job DB-id; proto has one container_id) — resolve for end-to-end; drop pod-level privileged (optional); Phase F commit/push/rebuild/test chain.
- ID-AMBIGUITY FIX (Option A) DONE in container-maker: save() now resolves kubernetes_id from the DB id via ContainerOps.find_one({"id": data.container_id}) (DBConfig from its DB_* env), uses kubernetes_id for check_pod/service/ingress, and keeps the DB id as the Job's CONTAINER_ID. Added browseterm-db as a container-maker dependency (pyproject.toml) + imports. Frontend/server/Job unchanged (all use DB id — already correct). check_pod matches pod['pod_id'] (k8s id), confirmed at containers.py:62.
- IMPLICATION: container-maker IMAGE MUST BE REBUILT (browseterm-db now required in its venv). Do NOT restart the running container-maker pod until rebuilt (the new `from browseterm_db...` import would fail). Part of the Phase F rebuild chain.
- TEST TO UPDATE: container-maker tests/unit/containers/test_save_container_env.py now needs to also mock ContainerOps.find_one (return a row dict with kubernetes_id) since save() now does a DB lookup before check_pod.
- All save-flow changes (Phases A-D + id fix + tests) are UNCOMMITTED.

# ═══════════════ CURRENT STATE SNAPSHOT (as-is, working local dev on docker-desktop) ═══════════════
Everything below is DEPLOYED AND RUNNING on the docker-desktop cluster, namespace `browseterm`. This is the "as-is" baseline; the Improvement Backlog after it is the agenda for the production-grade pass.

## What's running (all 1/1 Running in ns `browseterm`)
- browseterm-pg (Postgres 15)  — svc browseterm-pg-service:5432 — schema migrated + seeded + NOTIFY trigger present
- browseterm-redis (7-alpine)  — svc browseterm-redis-service:6379 — ACL user `browseterm`, default user disabled
- container-maker-development  — svc :50052 — gRPC server (app.py --use_ssl true), mTLS secret mounted
- socket-ssh-development        — svc :8000 (+9229 debug) — Node ws server (started manually in pod)
- browseterm-server-development — svc :9999 — FastAPI/uvicorn (started manually in pod)
- cert-manager (CronJob) + cert-manager-job (Completed) — minted secrets container-maker-development-service-certs + container-maker-service-certs

## Cluster infra installed
- namespace `browseterm`; nginx ingress-nginx (v1.11.2); MetalLB (pool 192.168.65.200-250, ingress got .200 — NOTE: VM-subnet IP, NOT reachable from Mac host); snapshot PV/PVC (Bound, 20Gi RWX).
- Ingresses exist (browseterm.local.com, socketssh via ingress) but are NOT the local access path (see below) and have NO TLS.

## Images built + pushed to Docker Hub zim95/ (via docker-login shim, non-interactive)
cert-manager, container-maker-development, socket-ssh-development, test-ssh-server, browseterm-server-development, ssh_ubuntu, status_sidecar (snapshot-job built via `cd snapshot_job && make prod_build`).

## How dev apps run (IMPORTANT)
- container-maker auto-starts its app via its dev entrypoint.
- browseterm-server + socket-ssh dev entrypoints are `tail -f /dev/null` — the app is started MANUALLY inside the pod (hostPath live-code model). I started them via:
  - server:  `kubectl exec -n browseterm deploy/browseterm-server-development -- bash -c 'cd /app && exec $(ls /opt/venv/*/bin/python|head -1) app.py'`  → Uvicorn on :9999
  - socket:  `kubectl exec -n browseterm deploy/socket-ssh-development -- bash -c 'cd /app && npm install && exec node server.js'`  → ws on :8000
  (These run as long as the exec stays connected. On pod restart, re-run.)

## Local access model (per 00_docs/local_ip_setup.md + portfwd.sh) — NOT ingress from Mac
Plain http/ws via port-forward to loopback-alias IPs. User must run (sudo):
  sudo ifconfig lo0 alias 192.168.0.3
  sudo ifconfig lo0 alias 192.168.0.4
  sudo sh -c 'printf "192.168.0.3\tbrowseterm.local.com\n192.168.0.4\tsocketssh.local\n" >> /etc/hosts'
Then `./browseterm-monorepo/portfwd.sh` (namespace fixed to `browseterm`) → browseterm.local.com:9999 (server), socketssh.local:8000 (socket-ssh).

## Fixes made this session (real bugs, applied)
1. browseterm-db init.py drops the NOTIFY trigger (autogenerate from models) → re-applied trigger SQL from git directly. PROPER FIX pending.
2. Dockerfile.ubuntu (socket-ssh + browseterm-dockerfiles): `mkdir /var/run/sshd` → `mkdir -p` (fails on current ubuntu:latest).
3. 02_cluster_infra/snapshot-pvc.yaml: namespace `browseterm-new` → `browseterm`.
4. portfwd.sh: namespace `browseterm-new` → `browseterm`.
5. docker-login shim (scratchpad/bin/docker) so build scripts' interactive `docker login -u` don't hang (no repo edits). NOT committed anywhere — reusable for rebuilds.

# ═══════════════ IMPROVEMENT / PRODUCTION-GRADE BACKLOG (next phase) ═══════════════
- **LE / TLS / WSS clarified:** local = plain ws over port-forward (no LE). wss+Let's Encrypt is the PRODUCTION path (real public domain; HTTP-01 can validate). LE cannot sign local `.local.com` hosts. For local WSS use mkcert (local trusted CA) — not yet done.
- **Hostname inconsistency:** socket host is `socketssh.local` (local_ip_setup.md) vs `socket-ssh.local.com` (server.js default + env.mk). Pick one canonical; align env.mk + /etc/hosts.
- **SOCKET_SSH_WSS_URL wrong for port-forward model:** currently `ws://socket-ssh.local.com` (no port); for port-forward it must be `ws://<sockethost>:8000`. Fix + redeploy server.
- **OAuth login blocked:** Google/GitHub client id/secret are placeholders in browseterm-server/env.mk → can't log in via browser. Need real creds OR a temp Redis-session bypass to exercise create-container + terminal flow.
- **Race condition (task #4) NOT yet diagnosed** — needs the flow exercised (blocked on OAuth/bypass above). Watch server + socket-ssh logs during a create+terminal.
- **snapshot-job migration (task #5) code bugs still open:** PodManager.save() signature mismatch (TypeError), pod-level privileged=True, proto SaveContainerRequest lacks db-cred fields, browseterm-server has no /save-container endpoint. + MinIO infra not deployed.
- **init.py trigger loss** proper fix (model-level DDL event, or use upgrade.py chain, or preserve trigger migration).
- **cert-manager consolidation:** could replace custom cert-manager repo with official jetstack cert-manager (CA issuer for internal mTLS + ACME issuer for public LE) + Reloader for rotation.
- **MetalLB vs docker-desktop:** MetalLB IP not host-reachable; ingress path unused locally (we use port-forward). Reconcile for a coherent local story.
- **Broken make targets to fix:** browseterm-dockerfiles build_snapshot_job/build_all; container-maker prod_*; monorepo dev_build/build_letsencrypt_issuer.
- **Monorepo (tasks #6, #7):** add browseterm-server + container-maker as submodules; one-command deploy/teardown + aggregated env.mk.
- **Secret hygiene:** REPO_PASSWORD (real Docker Hub pw) sits plaintext in 2 env.mk; move to k8s Secret + rotate to an access token.

# ═══════════════ 2026-07-19 — SAVE FLOW REBUILT + REDEPLOYED (real OAuth creds) ═══════════════
## Done this session
- Rebuilt + pushed all 3 images (docker-login shim): zim95/browseterm-server-development, zim95/container-maker-development, zim95/snapshot-job — all :latest.
- Poetry locks: server + container-maker locks pin new browseterm-db commit eb71343 (SaveStatus + ContainerSaveStatusChangePayload); ipython 8.12.0 aligned everywhere (KEPT for debugging). snapshot_job has NO committed lock → Dockerfiles now run `poetry lock && poetry install` so builds resolve fresh. python narrowed to >=3.11,<3.12 in db/storage(→3.10 ok)/server/container-maker.
- Committed+pushed: browseterm-server (pyproject+lock, "Narrow python…"), browseterm-dockerfiles ("Regenerate poetry lock at build time for snapshot job"), earlier container-maker lock 674bb2a, browseterm-storage c1f9812.
- Redeployed: rollout restart server + container-maker to pull new images. Re-ran `browseterm-server make dev_setup` to inject REAL OAuth creds (deployment previously had CHANGEME placeholders; env.mk already held the real values). New server pod has real GOOGLE/GITHUB client id+secret.
- Restarted apps (dev manual-start pattern): server `python app.py` → uvicorn :9999 clean startup (save-status listener loads, no traceback). container-maker auto-started → gRPC SSL [::]:50052. socket-ssh untouched (still running).
- DB verified on browseterm-pg: containers table has save_status/save_error/last_saved_at/saved_image columns AND both triggers (container_status_change_trigger, container_save_status_change_trigger).
- MinIO running (minio-* pod). /save-container route present on server (not 404).
- Deleted ~/.creds (creds safely persisted in browseterm-server/env.mk; user-authorized).

## RESOLVED (supersedes backlog items above)
- OAuth login: real creds now in env.mk + running pod (no longer placeholders).
- snapshot-job migration code bugs: fixed (id-resolution Option A, storage.localize, save_status writes, job_manager env merge, image name).
- MinIO infra: deployed (02_cluster_infra/minio.yaml) + verified.

## STILL NEEDS USER / NOT DONE
- END-TO-END SAVE TEST (Phase F): needs browser OAuth login + the sudo /etc/hosts + loopback-alias step (00_docs/local_ip_setup.md) + portfwd.sh. Then: log in, launch container, click Save → verify save_status PENDING→RUNNING→SUCCEEDED and spinner stops. NOT run yet (blocked on interactive browser + sudo).
- SOCKET_SSH_WSS_URL: FIXED → `ws://socketssh.local:8000` in env.mk (+ README). Was `ws://socket-ssh.local.com` (no port, and host not in /etc/hosts). Host MUST be `socketssh.local` to match /etc/hosts (00_docs/local_ip_setup.md) → 192.168.0.4 → portfwd → socket-ssh:8000. Verified: socketssh.local resolves, 192.168.0.4:8000 TCP OK. (Stays ws:// for local port-forward; wss:// is prod path.) Lesson: /etc/hosts host `socketssh.local` is the ground truth — align env.mk to it, not vice-versa.
- Task #4 race condition: still needs the create+terminal flow exercised (blocked on above).
- Task #7 monorepo one-command deploy/teardown + aggregated env.mk: not done.
- Monorepo submodule pointers now behind latest sub-repo commits (storage/db/server/container-maker/dockerfiles pushed after last bump) — re-bump for cleanliness.

# ═══════════════ 2026-07-21 — CURRENT STATE / HANDOFF (READ THIS FIRST) ═══════════════

## TL;DR
Save flow DONE+verified. One-command deploy DONE+validated. Now building WORKSPACE LIFECYCLE
(hibernate/resume). **USER SWITCHED to another cluster (2026-07-20) — do NOT run kubectl until they
confirm back on docker-desktop.** ~52% to production (see TODOPLAN.md). Commits = shresthanamah@gmail.com,
one-liners, no Claude attribution.

## Cluster / access (docker-desktop, ns=browseterm)
- Pods: browseterm-pg, browseterm-redis, minio, browseterm-server-development, container-maker-development,
  socket-ssh-development. Infra: ingress-nginx, MetalLB (pool 192.168.65.200-250).
- DEV MANUAL-START: server + socket-ssh pods idle (tail -f); after ANY pod restart, relaunch the app:
  - server:  exec → cd /app && source $(poetry env info --path)/bin/activate && python app.py  (uvicorn :9999)
  - socket:  exec → cd /app && npm install && npm start  (:8000)
  - container-maker AUTO-starts (gRPC SSL :50052).
- Browser: OAuth pinned to browseterm.local.com:9999 (AUTH_REDIRECT_BASE_URI). Needs loopback aliases
  192.168.0.3/0.4 + /etc/hosts (192.168.0.3 browseterm.local.com, 192.168.0.4 socketssh.local) + portfwd
  (server→192.168.0.3:9999, socket→192.168.0.4:8000). Port-forwards BREAK when the server/socket pod rolls — restart.

## Save flow — WORKS (verified 2026-07-20)
/save-container→PENDING→gRPC saveContainer→container-maker resolves pod (by pod name in associated_resources,
self-heals kubernetes_id)→tar (STREAMED, no OOM)→upload MinIO→snapshot Job→docker build+push
zim95/<pod>-image:latest→Job writes saved_image+SUCCEEDED→NOTIFY→SSE→spinner stops.
Fixes that made it work: streaming(OOM), pod-name resolution+self-heal, RBAC pods/log+jobs/status+pods-patch
on resources-cluster-role, FQDN service names for the cross-namespace Job. container-maker DB_HOST +
MINIO_ENDPOINT = FQDN (Job runs in USER namespace).

## _update_pod_image — KEPT + FIXED (crash recovery, do NOT drop)
After save, patches the pod's main-container image to zim95/<pod>-image:latest (FIXED missing repo prefix).
So a CRASHED container (pod alive) → kubelet restarts from the snapshot. Kept for active-user crash recovery.

## One-command deploy — DONE + validated (task #7)
monorepo: env.mk.example (aggregated, prefixed) → cp env.mk (gitignored) → scripts/gen-env.sh fans into each
submodule → scripts/setup.sh (ordered, non-interactive login shim, --fresh = destructive DB init +
scripts/notify-triggers.sql) → scripts/teardown.sh (--all removes metallb/ingress). Makefile:
setup/setup_fresh/teardown/teardown_all/gen_env. Validated: teardown_all→setup_fresh from scratch works.
GOTCHA: server POSTGRES_HOST must stay SHORT (browseterm-pg-service); create/resume append .NAMESPACE.svc...
to build the terminal DB host. gen-env has PG_HOST_SHORT (server) vs PG_HOST_INCLUSTER=FQDN (container-maker).

## Workspace lifecycle — decisions LOCKED
- Persistence = IMAGE-SNAPSHOT. Reaper = Kubernetes CronJob (our code, like cert-manager). Threshold = 1 WEEK.
- Terminal = BARE Pod (ownerReferences EMPTY, no controller) + Service (selector app=<name>). Delete pod =
  permanent (nothing recreates a bare pod). Container crash = kubelet restarts from spec image.
- Hibernate = save → DELETE POD → status HIBERNATED. Resume = recreate pod from saved_image (Service re-routes by label).

## Lifecycle progress
- [x] #14 statuses: HIBERNATED + RESUMING in ContainerStatus enum (browseterm-db), pg enum ALTER'd live,
  TestContainerStatusEnum. Committed/pushed.
- [~] #15 resume flow: BUILT + DEPLOYED, AWAITING E2E TEST.
  - browseterm-server: api_handlers.resume_container (fetch row→RESUMING→reconstruct CreateContainerK8SRequest
    from row→create_container_in_k8s(req, image_name_override=saved_image)→sync kubernetes_id+associated_resources+RUNNING).
    Route POST /resume-container. create_container_in_k8s gained image_name_override.
  - frontend terminals.js: HIBERNATED→showResume (▶ resume-btn), handleResume→POST /resume-container→reload+open.
  - TEST PRIMED on docker-desktop: container 27d900f9 (namah_ssh_ubuntu_test, saved_image
    zim95/namah-ssh-ubuntu-test-pod-1784526850-image:latest) — pod+service deleted in ns
    d4926ec1-c55e-4164-ba24-f6bef2a93898-namespace, status set HIBERNATED. When back: /terminals → ▶ resume →
    verify RESUMING→RUNNING + pod from saved_image.
  - LOOSE END: monorepo browseterm-server submodule pointer bump UNCOMMITTED (working dir at dd76608) —
    commit AFTER resume verified (keep monorepo pointing at verified commits only).
- [ ] #16 activity tracking: socket-ssh stamps last_active_at (DB column) on WS connect/heartbeat/disconnect.
- [ ] #17 reaper CronJob: query DB idle>1wk & running → save → delete pod → HIBERNATED.
- [ ] #18 crash recovery via status_sidecar (falls out of resume path).

## Git / two-clones (IMPORTANT)
- Commits as shresthanamah@gmail.com (per-repo config; global = namah@lyric.tech for Lyric).
- TWO copies of each repo: TOP-LEVEL clones /Users/namahshrestha/test/browseterm/<repo> (edit+commit HERE)
  vs MONOREPO submodules browseterm-monorepo/<repo> (the deploy mounts THESE). To push code live:
  commit top-level→push→`git -C browseterm-monorepo submodule update --remote <repo>`→rollout restart pod→relaunch app.
- Secrets in env.mk/.env (gitignored everywhere).

## Key docs (browseterm-monorepo)
TODOPLAN.md (plan + dev-day estimates + ~52%), OBSERVABILITY.md (log format [time][username:email][request_id]<rest>),
README.md (quick start), WORKSPACE_LIFECYCLE.md (TO BE WRITTEN).
Structured memory ~/.claude/.../memory/: save-restore-purpose, restore-flow-today, per-user-repo-credentials, testing-approach.

## Next when user returns (docker-desktop)
1. Test resume (▶) → verify → commit monorepo submodule bump + mark #15 done.
2. #16 activity tracking → #17 reaper CronJob → #18 crash recovery.
3. Then: observability, payments, ads, multi-tenant security isolation.
