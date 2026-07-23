# BROWSETERM
  
Browseterm is a project that allows users to run linux containers in the browser. The user can create and run different linux terminals and interact with them in the browser. Look at the demo:  
<add a gif>
  
Payment plans:
--------------
1. Free Plan:  Default subscription model. 1 Container, 1 CPU, 1 GB Memory.  
2. Basic Plan: 100 INR. 5 Containers, 1 CPU, 1 GB Memory.  
3. Pro Plan:   500 INR. 30 Containers, 12 CPU, 12 GB Memory.  
  
This repository holds the complete browseterm project. This respository is a collection of all the other repositories that add up to become Browseterm.  
  
# MicroServices:
Here are all the services that browseterm has:  
**1. PostgresHA:**  
    **Type:** MicroService.  
    **Description:** Our database. Prioritizes consistency since we have a lot of payment data. Today we deploy a single Postgres instance with a K8s service; the full HA combination (ETCD, Patroni, HAProxy, Postgres Cluster, PGBackRest) is planned/WIP.  

**2. BrowsetermDB:**  
    **Type:** Python Library for Database and Migrations.  
    **Description:** Contains database models, operations on top of models (CRUD), database event listener, Migrations manager.  
    **NOTE:** Need to run migrations once the database is setup.  

**3. CertManager:**  
    **Type:** MicroService (CronJob).  
    **Description:** Manage certificates and rollout new deployments for microservices. Can create job on the fly. Can also be invoked by other services for custom certificate creation.  
  
**4. Socket-SSH:**  
    **Type:** MicroService.  
    **Description:** The socket interface to our linux containers. Used by front-end to stream SSH data.  
  
**5. Browseterm-Dockerfiles:**  
    **Type:** Docker Image(s).  
    **Description:** There are multiple images to build here:  
        - **Linux Images:** These are our linux images. Right now, we only have ubuntu.  
        - **Status Sidecar:** This is the status sidecar. We need to build this image to update status of our containers. This will act as the status monitor sidecar container.  
        - **Snapshot Job:** A run-to-completion Kubernetes Job that snapshots a container's filesystem into a pushable image. (Replaces the older, deprecated Snapshot Sidecar.)  
  
**6. Redis HA:**  
    **Type:** MicroService.  
    **Description:** This is our Redis server. Used for Cache and Auth State Management.  
  
**7. Container Maker Spec:**  
    **Type:** Python Library (GRPC).  
    **Description:** This is the GRPC library that is used to communicate with our other microservice called `container-maker`.  
  
**8. Container Maker:**  
    **Type:** MicroService (GRPC server).  
    **Description:** Implements the Container Maker Spec. Uses the Kubernetes API to create/delete/save the user's linux container pods (ubuntu SSH container + status sidecar) and launches snapshot Jobs.  
  
**9. Browseterm-Server:**  
    **Type:** MicroService (main backend).  
    **Description:** FastAPI API + web UI. Handles OAuth login, talks to container-maker (gRPC/mTLS), Postgres (via BrowsetermDB), Redis (sessions), and cert-manager; hands the browser the socket-ssh WebSocket URL.  
  
**10. Browseterm-Storage:**  
    **Type:** Python Library.  
    **Description:** Storage abstraction for container filesystem snapshots (local PVC or MinIO). Used by container-maker and the snapshot job.  
  

# Getting Started
To get started, clone this repo:
```bash
$ git clone --recurse-submodules https://github.com/Zim95/browseterm-monorepo
```
  
In case you forget to include submodules:
```bash
$ git submodule update --init --recursive
```

---

# Development Setup Guide (Docker Desktop, step-by-step)

## Quick start (one command)

Everything below is automated. Fill in one config file and run one command:

```bash
cp env.mk.example env.mk        # then edit env.mk: set REPO_PASSWORD + the GOOGLE/GITHUB OAuth secrets
make setup_fresh                # first time: deploys the whole stack AND creates+seeds the DB (destructive)
# on later re-deploys (keep your data):
make setup
```

`make setup` fans the single aggregated `env.mk` out into each submodule's own config
(`scripts/gen-env.sh`), then runs the ordered deploy in `scripts/setup.sh` (cluster infra → data tier →
cert-manager → images → services → starts the manual apps), non-interactively. Tear it all down with
`make teardown` (or `make teardown_all` to also remove MetalLB/ingress). You still do the sudo
`/etc/hosts` + `portfwd.sh` step yourself (§11) — it needs an interactive sudo.

The step-by-step guide below is the **same sequence, by hand** — read it to understand what `make setup`
does and to troubleshoot.

---

This is the **actual, end-to-end local dev setup** on Docker Desktop's built-in Kubernetes, in the order you run it, with the reasoning behind each step. Each service also has its own README with the full `env.mk` reference — this guide ties them together.

> **Cluster note:** These steps target **Docker Desktop**. The project's other docs (`00_docs/multipass_cluster.md`) describe a Multipass/k3s cluster; a few values differ between the two environments and are called out below (MetalLB pool, local access). The canonical shared values used here:
> - **Namespace:** `browseterm`
> - **Docker Hub user (image registry):** `zim95`
> - **Postgres:** `browseterm-pg-service:5432` (user `browseterm`, db `browseterm`)
> - **Redis:** `browseterm-redis-service:6379` (ACL user `browseterm`; default user disabled)

## 0. Prerequisites (tools)
- **Docker Desktop** with **Kubernetes enabled** (Settings → Kubernetes → *Enable Kubernetes*). *Why: it gives us a local single-node cluster and a Docker daemon in one.*
- `kubectl`, `make`, `envsubst` (from `gettext`), `docker`, `poetry` (Python services), `node`/`npm` (socket-ssh), `helm` (optional), `brew`.

## 1. Point kubectl at Docker Desktop
```bash
kubectl config use-context docker-desktop
kubectl get nodes            # expect one Ready node
```
*Why: make absolutely sure you're on the local cluster and not some remote/production context before you start applying manifests.*

## 2. Create the namespace
```bash
kubectl create namespace browseterm
```
*Why: every BrowseTerm object lives in one namespace so services find each other by short name (same-namespace DNS) and teardown is a single `kubectl delete namespace`.*

## 3. Install the NGINX Ingress Controller
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
```
*Why: our services expose `Ingress` objects (host-based routing, e.g. `browseterm.local.com` → server, `socketssh.local` → socket-ssh). An Ingress does nothing without a controller to implement it; nginx is the controller.*

## 4. Install MetalLB (LoadBalancer IP provisioning)
*Why: the ingress controller — and the per-container services BrowseTerm creates at runtime — are `Service type: LoadBalancer`. On a cloud, the cloud hands out an external IP. On a local/bare-metal cluster there is no cloud LB, so those services sit at `EXTERNAL-IP: <pending>` forever. MetalLB fills that role, assigning IPs from a pool.*

```bash
# 4a. Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=150s

# 4b. Find the node's subnet so the pool is on the right network
kubectl get nodes -o wide            # note INTERNAL-IP, e.g. Docker Desktop = 192.168.65.3

# 4c. Apply an IP pool ON THAT SUBNET (Docker Desktop = 192.168.65.x)
cat <<'EOF' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.65.200-192.168.65.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF
```
> ⚠️ **Docker Desktop caveat:** the committed `02_cluster_infra/metallb-config.yaml` uses `192.168.64.x` — that's for the **Multipass** cluster. On Docker Desktop the node is on `192.168.65.x`, so use the pool above. **Also:** MetalLB's L2 IPs live inside the Docker Desktop VM network and are **not reachable from your Mac host** (a `curl`/`ping` to `192.168.65.200` from macOS times out). They *are* reachable in-cluster (which is what the per-container services need, since socket-ssh dials them internally). For reaching the app **from your Mac browser**, we use loopback aliases + port-forward instead — see §11. (On Multipass, the node IPs are host-reachable, so there MetalLB serves the browser directly.)

## 5. Apply the shared snapshot volume
```bash
kubectl apply -f 02_cluster_infra/snapshot-pvc.yaml
```
*Why: the container "save" flow tars a container's filesystem onto a shared RWX volume that the snapshot Job then reads. This PVC is that volume.*
> Fix applied: this manifest had a hardcoded `namespace: browseterm-new`; corrected to `browseterm`.

## 6. Data tier

### 6a. Postgres — `postgres_ha`
```bash
cd postgres_ha    # env.mk already set: NAMESPACE, POSTGRES_USER/PASSWORD/DB/TEST_DB
make dev_pg_single_setup
cd -
```
*Why: the database backing users, subscriptions, orders, images and containers. Exposes `browseterm-pg-service:5432`, which every other service uses as `POSTGRES_HOST`. Uses the public `postgres:15` image (no build/login needed).*

### 6b. Migrations + seed — `browseterm-db`
```bash
# Postgres runs in-cluster; expose it to the host to run migrations:
kubectl port-forward service/browseterm-pg-service -n browseterm 5432:5432 &

cd browseterm-db          # .env already set (DB_* = the Postgres creds above, DB_HOST=localhost)
poetry install
python init.py            # FIRST-TIME ONLY + DESTRUCTIVE: drops all tables, creates the schema, and seeds subscription types + images
cd -
```
*Why: creates the schema and seeds the default subscription plans + the base ubuntu image row. Run once, at first setup.*

> ⚠️ **Known bug + required fix:** `init.py` resets the migration chain and **auto-generates** the schema from the SQLAlchemy models — which **drops the hand-written `container_status_change` NOTIFY trigger**. That trigger is what powers live container-status → SSE updates in browseterm-server. After `init.py`, re-apply it:
> ```bash
> kubectl exec -i browseterm-pg -n browseterm -- psql -U browseterm -d browseterm <<'SQL'
> CREATE OR REPLACE FUNCTION notify_container_status_change() RETURNS TRIGGER AS $$
> BEGIN
>   IF OLD.status IS DISTINCT FROM NEW.status THEN
>     PERFORM pg_notify('container_status_change', json_build_object(
>       'id', NEW.id, 'user_id', NEW.user_id, 'name', NEW.name,
>       'old_status', OLD.status, 'new_status', NEW.status, 'updated_at', NEW.updated_at)::text);
>   END IF; RETURN NEW;
> END; $$ LANGUAGE plpgsql;
> DROP TRIGGER IF EXISTS container_status_change_trigger ON containers;
> CREATE TRIGGER container_status_change_trigger AFTER UPDATE ON containers
>   FOR EACH ROW EXECUTE FUNCTION notify_container_status_change();
> SQL
> ```
> (Proper fix TODO: make the trigger part of the model DDL, or run `python upgrade.py upgrade` which applies the real migration chain incl. the trigger, instead of `init.py`'s reset+autogenerate.)

### 6c. Redis — `redis_ha`
```bash
cd redis_ha       # env.mk already set: NAMESPACE, REDIS_USER, REDIS_PASSWORD, REDIS_DATA_DIR
make dev_redis_single_setup
cd -
```
*Why: Redis holds auth/session state and the one-time WebSocket tokens the server mints for socket-ssh. Exposes `browseterm-redis-service:6379`.*
> **Important:** setup creates an **ACL user** (`browseterm`) and **disables the `default` user**, so every client must authenticate with username **and** password (`--user browseterm -a <pw>`). The server and socket-ssh `env.mk` are configured for this.

## 7. cert-manager — internal gRPC mTLS  (NOT Let's Encrypt)
*Why: browseterm-server (client) talks to container-maker (server) over **gRPC with mutual TLS**. Both ends are ours and internal, so this uses a **private CA**, not a public one. `cert-manager` is a CronJob that generates a CA + server + client cert bundle and stores them as `{service}-certs` Secrets. This is unrelated to browser/HTTPS certs (see the TLS/WSS section).*

```bash
cd cert-manager           # env.mk: USER_NAME, REPO_NAME, NAMESPACE, HOST_DIR
make prod_build           # the build script runs `docker login` itself and will prompt for your Docker Hub password on the first push
make prod_setup           # creates the CronJob (schedule: Sundays 05:00)
# certs are otherwise generated weekly — trigger one now:
kubectl create job --from=cronjob/cert-manager cert-manager-job -n browseterm
cd -
# verify the secrets exist before deploying container-maker:
kubectl get secrets -n browseterm | grep certs
```
*Why the manual job: the CronJob won't fire until Sunday, but container-maker needs its secret now.* The job creates `container-maker-development-service-certs` and `container-maker-service-certs`.
> **cert-manager MUST run (and the job complete) BEFORE container-maker**, or container-maker's pod can't mount its cert and won't become healthy.
> Note: the cert Subject is the **short service name** (`CN=container-maker-development-service`) — same-namespace resolution — with no SAN, and the gRPC client connects by that same short name.

## 8. Build the in-cluster images — `browseterm-dockerfiles`
*Why: these are the images container-maker runs at runtime — the ubuntu SSH container (the user's terminal), the status_sidecar (writes the pod's status to the DB), and the snapshot_job (builds+pushes a container snapshot on save).*
```bash
cd browseterm-dockerfiles     # env.mk: USER_NAME, REPO_NAME (+ REPO_PASSWORD/SNAPSHOT_PATH for snapshot_job)
make build_ubuntu
make build_status_sidecar
# build_snapshot_job / build_all are broken (point at a non-existent ./snapshot_job/build.sh); build it directly:
cd snapshot_job && make prod_build && cd ..
cd -
```
> Fix applied: `Dockerfile.ubuntu` (here and in socket-ssh) had `RUN mkdir /var/run/sshd`, which fails on current `ubuntu:latest` ("File exists") → changed to `mkdir -p`.

## 9. Generate gRPC stubs — `container-maker-spec`
```bash
cd container-maker-spec
poetry install --no-root && python build.py    # only needed if you change the .proto
cd -
```
*Why: the shared gRPC contract. container-maker (server) and browseterm-server (client) consume it as a git dependency (with committed generated stubs), so you only rebuild here after editing the `.proto`.*

## 10. Deploy the services (in dependency order)
For each service: make its dev entrypoint executable, build+push the image, then apply.
*Why the chmod: in **development mode** the manifest bind-mounts your local repo into the pod at `/app` (hostPath) so your editor changes are live inside the container. That mount **shadows the image's copy of the entrypoint**, so the local file must be executable on the host.*

```bash
# 10a. container-maker (needs the cert secret from §7)
cd container-maker
chmod +x ./infra/k8s/development/entrypoint-development.sh
make dev_build && make dev_setup
cd -

# 10b. socket-ssh
cd socket-ssh
chmod +x ./infra/development/entrypoint-development.sh
make dev_build && make dev_setup     # dev_build also builds a test-ssh image
cd -

# 10c. browseterm-server
cd browseterm-server
chmod +x ./infra/development/entrypoint-development.sh
make dev_build && make dev_setup
cd -
```

**Starting the apps (dev model):** `container-maker`'s dev entrypoint auto-starts its app. **`browseterm-server` and `socket-ssh` dev entrypoints only run `tail -f /dev/null`** — the pod idles with your code mounted, and you start the app manually so you can restart it on edits:
```bash
# browseterm-server (uvicorn on :9999) — uses the venv baked at /opt/venv
kubectl exec -n browseterm deploy/browseterm-server-development -- \
  bash -c 'cd /app && exec $(ls /opt/venv/*/bin/python | head -1) app.py'

# socket-ssh (ws on :8000) — install node deps (the /app mount shadows the image's node_modules), then start
kubectl exec -n browseterm deploy/socket-ssh-development -- \
  bash -c 'cd /app && npm install && exec node server.js'
```
*Why npm install here: the hostPath `/app` mount hides the `node_modules` baked into the image, so install into the mounted dir.*

Verify everything is up:
```bash
kubectl get pods -n browseterm      # all should be Running
```

## 11. Local access from your Mac (loopback aliases + /etc/hosts + port-forward)
*Why this and not the ingress: as noted in §4, on Docker Desktop the MetalLB/ingress IPs aren't reachable from macOS. The working local model (`00_docs/local_ip_setup.md`) is to create **loopback alias IPs** on your Mac, map friendly hostnames to them, and `kubectl port-forward` each service onto its alias. Using hostnames (not raw IPs) matters because the browser must connect by name — that's what the ingress routes on in prod and what the TLS cert's SAN matches.*

Run these in your **own Terminal** (sudo needs an interactive prompt):
```bash
# create the loopback alias IPs (NOT persistent — re-run after a reboot)
sudo ifconfig lo0 alias 192.168.0.3
sudo ifconfig lo0 alias 192.168.0.4

# map hostnames -> those IPs (persistent)
sudo sh -c 'printf "192.168.0.3\tbrowseterm.local.com\n192.168.0.4\tsocketssh.local\n" >> /etc/hosts'
```
Then port-forward (from the monorepo root):
```bash
./portfwd.sh        # server -> 192.168.0.3:9999, socket-ssh -> 192.168.0.4:8000
```
Open **http://browseterm.local.com:9999**.

## 12. OAuth login credentials
*Why: browseterm-server authenticates users via Google/GitHub OAuth.* Set real credentials in `browseterm-server/env.mk`:
```
GOOGLE_CLIENT_ID=<your id>
GOOGLE_CLIENT_SECRET=<your secret>
GITHUB_CLIENT_ID=<your id>
GITHUB_CLIENT_SECRET=<your secret>
```
With placeholder values, Google returns **`Error 401: invalid_client` / "The OAuth client was not found."** After setting them, redeploy/restart the server so it picks up the new env.

---

## TLS / WSS / Let's Encrypt — why local is `ws://` and prod is `wss://`
- The browser talks to socket-ssh over a WebSocket. When the page is served over **HTTPS**, browsers require **WSS** (secure WebSocket) with a **browser-trusted** certificate — a self-signed cert is rejected outright and you can't "proceed anyway" for a socket.
- **Locally** (this guide) the page is served over **HTTP** via port-forward, so plain **`ws://`** is allowed and no certificate is needed. This is the intended local dev model.
- **In production**, the page is HTTPS and you need a real cert. That's what `02_cluster_infra/letsencrypt-issuer.yaml` is for — two `ClusterIssuer`s using an HTTP-01 solver over nginx. **It requires the official (jetstack) cert-manager and a real, publicly-resolvable domain** — Let's Encrypt's servers must reach your ingress over the internet to validate. It therefore **cannot** issue for a local-only host like `browseterm.local.com` (that's the `invalid`/challenge-failure you hit trying it locally). TLS is terminated at the ingress; socket-ssh itself stays plain `ws://` behind it.
- If you want **WSS locally** (to mirror prod), use **`mkcert`** (a locally-trusted CA) to issue certs for `browseterm.local.com`/`socketssh.local`, add a `tls:` block to the ingresses, and switch the page + `SOCKET_SSH_WSS_URL` to HTTPS/`wss://`. Let's Encrypt stays for real deployments.

## Teardown
```bash
# services (reverse order)
(cd browseterm-server && make dev_teardown)
(cd socket-ssh && make dev_teardown)
(cd container-maker && make dev_teardown)
(cd cert-manager && make prod_teardown)
(cd redis_ha && make dev_redis_single_teardown)
(cd postgres_ha && make dev_pg_single_teardown)
# then everything else
kubectl delete namespace browseterm
# (optional) remove the loopback aliases
sudo ifconfig lo0 -alias 192.168.0.3; sudo ifconfig lo0 -alias 192.168.0.4
```

## Testing

Each service documents how to run its own tests in its README's **"Running tests"** section. Project
norm: **integration tests over unit tests**; Python tests use the **`unittest`** module (not pytest);
DB-backed tests run against a **live Postgres on a separate test database**.

| Service | Framework | Notes |
|---|---|---|
| browseterm-db | `unittest` | live Postgres, separate `TEST_DB_*` database |
| container-maker | `unittest` | unit + gRPC need no cluster; `tests/k8s/integration` needs a live cluster |
| browseterm-server | jest + `unittest` | frontend jest is self-contained; backend is integration (needs Postgres/Redis) |
| browseterm-storage | `unittest` | MinIO mocked — no infra needed |
| socket-ssh | jest | |
| browseterm-dockerfiles / snapshot_job | `unittest` | see `snapshot_job/tests/README.md` |

**Workspace-lifecycle coverage** (save → crash → resume, save → hibernate → resume):
- `container-maker` — unit (mocked k8s client) in `tests/unit/resources/` (`test_update_pod_image`,
  `test_save_image_crash_recovery`, `test_create_pod_image_override`); live-cluster integration in
  `tests/k8s/integration/resources/test_crash_hibernate_flow.py` (create a pod+service pair →
  crash→recover, and save→hibernate→resume, asserting the pod works + the service still routes).
- `browseterm-server` — `tests/integration/containers/test_resume_container.py` (resume recreates
  from `saved_image` and persists the new Service IP — a regression guard — plus the save handler).

CI (GitHub Actions, per-repo, on push) will run these suites — see `TODOPLAN.md` for the plan.

## Roadmap / TODO
- **One-command deploy + teardown** — ✅ implemented: `make setup_fresh` / `make setup` / `make teardown` / `make teardown_all`, backed by the aggregated `env.mk` + `scripts/`. See **Quick start** above.
- Fix the remaining broken make targets (`browseterm-dockerfiles` `build_snapshot_job`/`build_all`; `container-maker` `prod_*`).
- Proper fix for the `init.py` NOTIFY-trigger loss.
- Optional: consolidate the custom cert-manager into official jetstack cert-manager (internal CA issuer + ACME issuer for public LE), with Reloader for rotation.

# Submodules

This monorepo aggregates **every BrowseTerm repository as a git submodule**, so the whole system can be cloned and versioned together (each pinned to a specific commit). Here is every submodule, grouped by what it is and what it's for:

### Services (deployed workloads)
- **`browseterm-server`** — *MicroService — Python / FastAPI.* The main backend + web UI and the orchestrator. Handles OAuth login and sessions (Redis), talks to container-maker over gRPC/mTLS, reads/writes Postgres via `browseterm-db`, drives `cert-manager` jobs, and hands the browser the socket-ssh WebSocket URL. Served on `:9999`.
- **`container-maker`** — *MicroService — Python / gRPC server.* Implements the `container-maker-spec` contract. Uses the Kubernetes API to create / delete / save the user's Linux container pods (ubuntu SSH container + status sidecar) and to launch snapshot Jobs. Listens on `:50052` (mTLS).
- **`socket-ssh`** — *MicroService — Node.js.* The WebSocket ↔ SSH bridge that streams the terminal to the browser. Validates the server's one-time WS token against Redis, then opens an SSH session into the user's container. Listens on `:8000` (TLS terminated at the ingress in prod).
- **`cert-manager`** — *MicroService — Kubernetes CronJob.* Mints the **internal gRPC mTLS** certificates (a private CA + server/client certs) that secure the browseterm-server ↔ container-maker channel, stored as `{service}-certs` secrets. (This is *not* the public/Let's Encrypt cert path — see the TLS/WSS section.)

### Libraries (imported as dependencies — not deployed on their own)
- **`browseterm-db`** — *Python library.* SQLAlchemy models (users, subscription_types, subscriptions, images, containers, orders), the CRUD `*Ops` classes, Alembic migrations, the Postgres `LISTEN/NOTIFY` listener, and the JSON state seeder. Consumed by browseterm-server, the status_sidecar, and the snapshot_job.
- **`browseterm-storage`** — *Python library.* Storage abstraction for container filesystem snapshots, with `LocalPVCStorage` and `MinioStorage` backends selected via a `StorageLayer` enum. Consumed by container-maker (writes the tarball) and the snapshot_job (reads it).
- **`container-maker-spec`** — *Python library — gRPC / protobuf contract.* The `.proto` definitions and generated stubs for the `ContainerMakerAPI` (list/create/get/delete/saveContainer). Shared by container-maker (server) and browseterm-server (client) via git dependency. No deployment — build-only.

### Images (built here, run by container-maker at runtime)
- **`browseterm-dockerfiles`** — *Docker image builds.* Produces the images container-maker launches:
    - **ubuntu** (`ssh_ubuntu`) — the user's actual Linux terminal container (SSH server).
    - **status_sidecar** — injected next to each user container; watches the pod and writes its status to `browseterm-db` (which fires the NOTIFY trigger → live UI updates).
    - **snapshot_job** — a run-to-completion Kubernetes **Job** that reads a container's fs snapshot (via `browseterm-storage`), builds a `FROM scratch` image, pushes it, and records `saved_image` in the DB. (Replaces the deprecated snapshot_sidecar.)

### Infrastructure (Kubernetes deploy manifests)
- **`postgres_ha`** — *Infra — K8s manifests.* Deploys the database. Single `postgres:15` instance today (exposes `browseterm-pg-service:5432`); full HA (etcd/Patroni/HAProxy) is WIP.
- **`redis_ha`** — *Infra — K8s manifests.* Deploys Redis (exposes `browseterm-redis-service:6379`) for auth/session state and the one-time WS tokens. Single instance today; Sentinel/Cluster are WIP.

> All ten are declared in `.gitmodules`. If you cloned without `--recurse-submodules`, populate them with `git submodule update --init --recursive`.

# Working with submodules:  
1. Adding a submodule:  
    ```bash
    $ git submodule add <repository_url> <path>
    $ git add .gitmodules <path>
    $ git commit -m "Add submodule <name>"
    $ git push origin
    ```
  
2. Removing a submodule:  
    ```bash
    $ git submodule deinit -f -- <path>
    $ git rm -f <path>
    $ rm -rf .git/modules/<path>
    $ git commit -m "Remove submodule <name>"
    $ git push origin
    ```
  
3. Updating submodules to their latest commit:  
    ```bash
    $ git submodule update --init --remote --merge --recursive
    $ git add <path> # or `git add .` to add all changed submodule pointers
    $ git commit -m "Update submodules to latest remote commits"
    $ git push origin
    ```
  
## License
This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See the [LICENSE](LICENSE) file for details.

### What this means:
- ✅ You can use, modify, and distribute this software.
- ✅ You must provide source code for any modifications.
- ⚠️ **Network use is distribution** - If you run this software on a server that users interact with over a network, you must provide the source code to those users.
- ✅ Perfect for open-source SaaS projects that want to prevent proprietary forks.
  
For commercial licensing options, please contact [shresthanamah@gmail.com].
