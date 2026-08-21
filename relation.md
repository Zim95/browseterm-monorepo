# BrowseTerm — How the Repositories Relate

> **What is BrowseTerm?** A SaaS that lets users run Linux terminals (containers) in
> the browser. A user logs in (Google/GitHub OAuth), spins up an Ubuntu container on
> Kubernetes, and gets an interactive SSH terminal streamed to the browser over a
> WebSocket. Containers can be saved (snapshotted into a pushable Docker image) and
> restored later. Subscription plans cap how many containers and how much CPU/mem/storage
> a user gets.

This document maps the **11 repositories** cloned under this directory, what each does,
and — most importantly — **how they depend on and talk to each other**.

---

## 1. The repositories at a glance

| Repo | Type | Language | Role |
|------|------|----------|------|
| **browseterm-monorepo** | Umbrella / submodules | Docs + k8s + Makefile | The "table of contents" — aggregates the others as git submodules, holds cluster bootstrap manifests, setup docs, and the save-flow design docs. |
| **browseterm-server** | MicroService (API gateway) | Python / FastAPI | The **main backend**. Serves the web UI + REST/SSE API, handles auth, and orchestrates everything else. |
| **container-maker** | MicroService (gRPC server) | Python / gRPC + k8s client | Turns gRPC calls into Kubernetes pods. Creates/deletes/saves the user's container. |
| **container-maker-spec** | Library (gRPC contract) | Python / protobuf | The `.proto` API contract shared between the server (client) and container-maker (server). |
| **browseterm-db** | Library (ORM + migrations) | Python / SQLAlchemy + Alembic | Shared database models, CRUD ops, Alembic migrations, a Postgres LISTEN/NOTIFY listener, and a state-seeder. |
| **browseterm-storage** | Library (storage abstraction) | Python / MinIO | Abstracts snapshot storage over a local PVC or MinIO (S3). |
| **browseterm-dockerfiles** | Docker images | Dockerfiles + Python | Builds the images that run *inside* the cluster: the Ubuntu SSH container + a status sidecar + a snapshot job. |
| **socket-ssh** | MicroService | Node.js / ws + ssh2 | The **WebSocket ↔ SSH bridge**. Streams terminal bytes between browser and container. |
| **cert-manager** | MicroService (CronJob) | Python / k8s client | Mints the mTLS certificates that secure the gRPC channel; rolls out deployments when certs change. |
| **postgres_ha** | Infra (deploy manifests) | k8s YAML | Deploys PostgreSQL (single instance today; HA cluster scaffolding is WIP). |
| **redis_ha** | Infra (deploy manifests) | k8s YAML | Deploys Redis (used for auth/session state, not app cache). |

> **Note on naming:** despite the `_ha` suffixes, both `postgres_ha` and `redis_ha`
> currently deploy **single instances**. The HA variants (Patroni/etcd/HAProxy for
> Postgres; Sentinel/Cluster for Redis) exist as documented, partially-scaffolded
> designs, not the running deployment.

---

## 2. Two kinds of relationships

The repos are wired together in **two distinct ways**. Don't conflate them:

### (a) Build-time dependencies — shared Python/JS libraries
Pulled in as `git+https://github.com/Zim95/...@main` dependencies:

```
browseterm-server            ──depends-on──▶ container-maker-spec   (gRPC client stubs)
browseterm-server            ──depends-on──▶ browseterm-db          (models, ops, PG listener)
container-maker              ──depends-on──▶ container-maker-spec   (implements the gRPC server)
container-maker              ──depends-on──▶ browseterm-storage     (write snapshot tarball)
dockerfiles/status_sidecar   ──depends-on──▶ browseterm-db          (write container status)
dockerfiles/snapshot_job     ──depends-on──▶ browseterm-db          (write saved_image)
dockerfiles/snapshot_job     ──depends-on──▶ browseterm-storage     (read snapshot tarball)
```

**Leaf libraries** (depend on nothing else in the project, consumed by many):
`container-maker-spec`, `browseterm-db`, `browseterm-storage`.

> Caveat: `container-maker/requirements.txt` still pins `container-maker-spec` at a stale
> local absolute path (`file:///Users/namahshrestha/projects/...`); the authoritative
> dependency is the git dep in its `pyproject.toml`.

### (b) Runtime dependencies — services talking over the network
```
browser        ──HTTPS/SSE──▶ browseterm-server
browser        ──WSS────────▶ socket-ssh ──SSH──▶ user container
browseterm-server ──gRPC/mTLS──▶ container-maker ──k8s API──▶ user pod (+ sidecars/jobs)
browseterm-server ──k8s API──▶ cert-manager (spawns a Job from its CronJob)
browseterm-server ──SQL + LISTEN/NOTIFY──▶ postgres_ha
browseterm-server ──▶ redis_ha (sessions + one-time WS tokens)
socket-ssh     ──▶ redis_ha (validate the one-time WS token)
container-maker / status_sidecar / snapshot_job ──▶ postgres_ha (via browseterm-db)
container-maker / snapshot_job ──▶ browseterm-storage (snapshot tarballs on PVC/MinIO)
cert-manager   ──▶ k8s Secrets (writes {service}-certs, mounted by container-maker & server)
```

---

## 3. Architecture diagram

```mermaid
graph TD
    U[Browser / Frontend]

    subgraph app[Application services]
        SRV[browseterm-server<br/>FastAPI API + UI]
        SSH[socket-ssh<br/>WS to SSH bridge]
        CM[container-maker<br/>gRPC server]
        CERT[cert-manager<br/>CronJob]
    end

    subgraph pod[User container pod - created by container-maker]
        UBU[ubuntu SSH container]
        STAT[status_sidecar]
    end

    subgraph data[Data + infra]
        PG[(postgres_ha<br/>PostgreSQL)]
        RD[(redis_ha<br/>Redis)]
        PVC[(snapshot PVC / MinIO)]
        REG[(Docker registry)]
    end

    JOB[snapshot_job<br/>k8s Job]

    U -->|HTTPS + SSE| SRV
    U -->|WSS + one-time token| SSH
    SSH -->|SSH ssh2| UBU
    SSH -->|validate token/session| RD

    SRV -->|gRPC / mTLS| CM
    SRV -->|sessions + ws_token| RD
    SRV -->|SQL + LISTEN/NOTIFY| PG
    SRV -->|spawn Job from CronJob| CERT

    CM -->|k8s API: create pod| UBU
    CM -->|inject sidecar| STAT
    CM -->|write fs tarball| PVC
    CM -->|create Job| JOB

    STAT -->|update status| PG
    JOB -->|read tarball| PVC
    JOB -->|build + push image| REG
    JOB -->|write saved_image| PG

    CERT -->|write {service}-certs secrets| CM

    %% shared libraries (build-time)
    SPEC[[container-maker-spec<br/>gRPC contract]]
    DBLIB[[browseterm-db<br/>ORM lib]]
    STLIB[[browseterm-storage<br/>storage lib]]
    SPEC -.imported by.-> SRV
    SPEC -.imported by.-> CM
    DBLIB -.imported by.-> SRV
    DBLIB -.imported by.-> STAT
    DBLIB -.imported by.-> JOB
    STLIB -.imported by.-> CM
    STLIB -.imported by.-> JOB
```

Solid arrows = runtime network calls. Dashed arrows = build-time library imports.

---

## 4. Per-repository detail

### browseterm-monorepo — the umbrella
- Aggregates most repos as **git submodules** (`.gitmodules`): socket-ssh, cert-manager,
  container-maker-spec, postgres_ha, browseterm-db, browseterm-dockerfiles, redis_ha,
  browseterm-storage. (Notably, `browseterm-server` and `container-maker` are **not**
  submodules here.)
- `README.md` is the master setup guide and orders the bring-up:
  MetalLB → namespace → postgres_ha → browseterm-db (migrations + seed) → cert-manager →
  socket-ssh → browseterm-dockerfiles → redis_ha → container-maker-spec.
- `00_docs/` — cluster setup notes (metallb, minio, multipass, local IP, official cert-manager).
- `02_cluster_infra/` — `letsencrypt-issuer.yaml`, `metallb-config.yaml`, and
  `snapshot-pvc.yaml` (the shared 20Gi RWX volume used by the save flow).
- `01_language_detection/` — a non-product utility that emits dummy files to skew GitHub's
  language stats. Ignore for architecture purposes.
- `SAVE_CONTAINER_FLOW.md` / `save_flows.md` — design docs for the save/snapshot + restore flows (see §5.3).

### browseterm-server — the orchestrator
- **FastAPI** app on port **9999**; hybrid Jinja2 server-rendered UI + JSON REST + **SSE**
  (`/container-status-stream`). Does **not** host the terminal WebSocket itself.
- **gRPC client** of container-maker via `container-maker-spec` stubs (mTLS, default host
  `container-maker-development-service:50052`). Calls `createContainer`, `deleteContainer`, `saveContainer`.
- **Postgres** via the `browseterm-db` library — CRUD ops + a `PGListener` on the
  `container_status_change` channel that feeds the SSE stream.
- **Redis** for auth: OAuth login creates a Redis-backed `session:` (24h TTL, sliding 30-min
  extension via `@authenticate_session`) and mints one-time `ws_token:` (60s TTL) for socket-ssh.
- **cert-manager** driven via the **Kubernetes API** (spawns a Job from cert-manager's
  CronJob to mint certs on demand), not via HTTP.
- **OAuth** (Google + GitHub) over HTTPS via httpx.
- `infra/` deploys the Deployment/Service/HPA/PDB/Ingress plus the `job-manager` RBAC that
  lets the pod create Jobs and read cert Secrets.
- **No Kafka and no object-storage client** exist here (the README's mention of a Kafka
  service is aspirational/not wired).

### container-maker — the Kubernetes container factory
- The **gRPC server** implementing `container-maker-spec` (`ContainerMakerAPIServicerImpl`).
- Uses the **Kubernetes client** to create a pod per user container = the **Ubuntu SSH
  container** (image supplied in the request) + an injected **status_sidecar**; also creates
  services/ingresses/namespaces.
- On save: `tar`s the container filesystem to the shared PVC (path via `browseterm-storage`)
  and launches the **snapshot_job** (image `{repo}/snapshot_job:latest`).
- gRPC secured by mTLS certs mounted from the `container-maker-*-service-certs` Secret
  produced by cert-manager.
- Does **not** write to the DB directly — that's delegated to the sidecar/job images.

### container-maker-spec — the contract
- Protobuf package defining service `ContainerMakerAPI` with 5 RPCs: `listContainer`,
  `createContainer`, `getContainer`, `deleteContainer`, `saveContainer`.
- `build.py` generates the gRPC Python code. **Imported by both** container-maker (server)
  and browseterm-server (client) — this is the single source of truth for their interface.

### browseterm-db — the shared data layer
- SQLAlchemy models / tables: `users`, `subscription_types`, `subscriptions`, `images`,
  `containers` (with `status` enum, `kubernetes_id`, `saved_image`, soft-delete), `orders`.
- One `*Ops` CRUD class per model over a common `DBOperations` base returning `OperationResult`.
- **Alembic** migrations in `migrations/versions/`, including the trigger
  `container_status_change_trigger` → `notify_container_status_change()` that powers Postgres
  NOTIFY on container status changes.
- `db_state_manager/` — a reconciler that seeds `images` and `subscription_types` from JSON.
- `common/pg_listener.py` — the `PGListener` LISTEN/NOTIFY client consumed by browseterm-server.
- **Consumed by:** browseterm-server, dockerfiles/status_sidecar, dockerfiles/snapshot_job.

### browseterm-storage — snapshot storage abstraction
- Abstract `BrowsetermStorage` with `snapshot_path / read / write`; two backends selected by a
  `StorageLayer` enum: `LocalPVCStorage` (shared PVC) and `MinioStorage` (S3/MinIO).
- Stores container **filesystem snapshot tarballs** (`fs_snapshot_*.tar.gz`).
- **Consumed by:** container-maker (writes the tar) and dockerfiles/snapshot_job (reads it).

### browseterm-dockerfiles — the in-cluster images
- **ubuntu_setup** — the actual user SSH terminal (`ubuntu` + openssh, port 22). No DB access.
- **status_sidecar** — watches its own pod via `kubernetes_asyncio` and writes the pod phase to
  `containers.status` in browseterm-db (which fires the NOTIFY trigger).
- **snapshot_job** — a run-to-completion Job that reads the fs tarball (via browseterm-storage),
  builds a `FROM scratch` image, pushes it to the registry, and writes `saved_image` to the DB.
- **snapshot_sidecar** — the legacy in-pod snapshotter, **deprecated** in favor of snapshot_job.

### socket-ssh — the terminal bridge
- Node.js WS server on port **8000** (TLS terminated at ingress). Browser connects
  `wss://.../?token=<one-time>`; socket-ssh validates the token against Redis
  (`ws_token:` / `session:`), then opens an `ssh2` connection to the user container
  (host/credentials supplied by the client; the container's IP comes from the `containers` row).
- Multiplexes live SSH sessions keyed by `ssh_hash`; tears them down on disconnect.

### cert-manager — the mTLS issuer
- A **Kubernetes CronJob** (`schedule: "0 5 * * 0"`, Sundays 05:00) that, per service in
  `services.list.json` (`container-maker-service`, `container-maker-development-service`),
  generates a CA + server + client cert bundle via openssl, stores them as `{service}-certs`
  Secrets, and triggers rolling restarts of the matching deployments.
- These secrets are what container-maker mounts (server side) and browseterm-server uses
  (client side) to secure the gRPC channel. Can be invoked on demand
  (`kubectl create job --from=cronjob/cert-manager ...`), which is what browseterm-server does.

### postgres_ha — the database
- Deploys a **single PostgreSQL instance** with a k8s Service (the HA cluster —
  etcd/Patroni/HAProxy/PGBackRest — is documented/WIP, not deployed).
- Connected to by browseterm-server, status_sidecar, and snapshot_job (all via browseterm-db).

### redis_ha — the cache/auth store
- Deploys **single-instance Redis** (Sentinel/Cluster documented, not fully present).
- Used purely for **auth/session state**: browseterm-server writes sessions and one-time WS
  tokens; socket-ssh reads/validates them. This is the shared handshake that lets a token
  minted by the server authorize a WebSocket to socket-ssh.

---

## 5. Key end-to-end flows

### 5.1 Login
Browser → browseterm-server OAuth (Google/GitHub) → upsert user + subscription in Postgres →
create Redis session → httpOnly `session` cookie.

### 5.2 Create a container & open a terminal
1. Browser → `POST /create-container-in-k8s` on browseterm-server.
2. browseterm-server → gRPC `createContainer` → container-maker.
3. container-maker → Kubernetes API → creates the pod (ubuntu SSH container + status_sidecar),
   returns IP/port; browseterm-server persists the `containers` row.
4. status_sidecar reports pod phase → `containers.status` → Postgres NOTIFY →
   browseterm-server `PGListener` → **SSE** to the browser (live status).
5. To open the terminal, browseterm-server mints a one-time `ws_token` in Redis and renders a
   `wss://` URL into the terminal page.
6. Browser → socket-ssh with the token → socket-ssh validates it against Redis → opens SSH to
   the container → streams the terminal.

### 5.3 Save (snapshot) a container
1. Browser → `POST /save-container` → browseterm-server → gRPC `saveContainer` (passing DB creds).
2. container-maker `tar`s the container filesystem onto the shared snapshot PVC (path via
   browseterm-storage) and creates the **snapshot_job** Job.
3. snapshot_job reads the tarball (browseterm-storage: PVC or MinIO), builds a `FROM scratch`
   image, pushes it to the registry, writes `saved_image` to the DB, and exits.
4. The DB update propagates back to the browser via the same NOTIFY → PGListener → SSE path,
   so the UI can stop its spinner. (Save is async — returns a job id immediately.)

---

## 6. Dependency layers (bottom-up mental model)

```
Infra          postgres_ha        redis_ha         (+ MetalLB, snapshot PVC, cert issuer)
                    │                  │
Libraries    browseterm-db   browseterm-storage   container-maker-spec
                    │                  │                    │
Images        status_sidecar   snapshot_job / ubuntu   (built by browseterm-dockerfiles)
                    │                  │                    │
Services      cert-manager ──▶ container-maker ◀── browseterm-server ──▶ socket-ssh
                                                        │
Umbrella                          browseterm-monorepo (submodules + docs + cluster infra)
```

**One-line summary:** `browseterm-server` is the brain; `container-maker` is its hands on
Kubernetes (spoken to over gRPC defined by `container-maker-spec`); `socket-ssh` streams the
terminal; `browseterm-db` + `postgres_ha` are shared state; `redis_ha` is the auth glue between
server and socket-ssh; `browseterm-storage` + `browseterm-dockerfiles` (snapshot_job) implement
save/restore; `cert-manager` secures the gRPC link; and `browseterm-monorepo` ties it all together.
