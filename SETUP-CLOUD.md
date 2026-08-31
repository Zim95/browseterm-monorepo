# Setting up the Cloud cluster (`browseterm-k3s`)

This is the verified, working procedure for standing up Cloud's `browseterm-k3s` cluster from
nothing — `postgres_ha` + `redis_ha` + `browseterm-server` (Cloud control plane: the Device API
and, as of P07, the sole Google/GitHub OAuth authority). It's `k3d` (Docker-based), not Docker
Desktop's built-in Kubernetes or a Multipass VM — see `progress_made.md`'s 2026-08-31 entries for
why that distinction matters and what came before it.

No committed script runs this end to end yet (see `TODOPLAN.md`'s "Monorepo single-command
deploy" item) — every step below is a real command, run once this way and verified working.

## Prerequisites

- Docker Desktop (or another Docker engine) running.
- `k3d` (`brew install k3d`), `kubectl` (`brew install kubectl`).
- `/etc/hosts` has `127.0.0.1  browseterm.cloud.com` (see step 5).
- The real Google/GitHub OAuth app's client id/secret (P07 — Cloud is the sole holder of these).

## 1. Create the cluster

```bash
k3d cluster create browseterm-k3s -p "9999:80@loadbalancer" --wait --timeout 90s
```

Port `9999` matches `browseterm-server`'s own `BROWSETERM_CLOUD_API_URL` convention
(`http://browseterm.cloud.com:9999`) and `browseterm-desktop`/`browseterm-server-local`'s default
for reaching Cloud.

## 2. Remove k3s's bundled Traefik, install ingress-nginx

k3d clusters ship k3s's bundled Traefik by default. Its `svclb` DaemonSet squats on host ports
80/443 — if you install ingress-nginx without removing Traefik first, ingress-nginx's own `svclb`
sits `Pending` forever and nothing is externally reachable (`kubectl -n kube-system get pods` will
show a `Pending` `svclb-ingress-nginx-controller-*` pod when this happens — that's the tell).

```bash
kubectl --context k3d-browseterm-k3s -n kube-system delete helmchart traefik
kubectl --context k3d-browseterm-k3s apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
kubectl --context k3d-browseterm-k3s -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
```

Verify: `kubectl --context k3d-browseterm-k3s -n ingress-nginx get svc` should show
`ingress-nginx-controller` with a real `EXTERNAL-IP` (a Docker-internal address like `172.18.0.3`
— not `<pending>`).

## 3. Namespace + Postgres + Redis

```bash
kubectl --context k3d-browseterm-k3s create namespace browseterm --dry-run=client -o yaml | kubectl --context k3d-browseterm-k3s apply -f -
kubectl config use-context k3d-browseterm-k3s

cd postgres_ha
./scripts/development/pg_single/pg_single.setup.sh browseterm <PG_USER> <PG_PASSWORD> browseterm browseterm_test
cd ../redis_ha
REDIS_DATA_DIR=/tmp/browseterm-redis-data-cloud ./scripts/development/redis_single/redis_single.setup.sh browseterm <REDIS_USER> <REDIS_PASSWORD>
cd ..

kubectl --context k3d-browseterm-k3s wait --for=condition=ready pod/browseterm-pg -n browseterm --timeout=90s
```

`<PG_USER>`/`<PG_PASSWORD>`/`<REDIS_USER>`/`<REDIS_PASSWORD>` — reuse the values already in the
aggregated `env.mk` (`PG_USER`, `PG_PASSWORD`, `REDIS_USER`, `REDIS_PASSWORD`) rather than
inventing new ones, so they stay consistent with whatever else references them.

## 4. Kubernetes Secrets Cloud's manifest needs

Three, all in the `browseterm` namespace:

```bash
kubectl --context k3d-browseterm-k3s create secret generic browseterm-db-credentials -n browseterm \
  --from-literal=DB_HOST="browseterm-pg-service.browseterm.svc.cluster.local" \
  --from-literal=DB_PORT="5432" \
  --from-literal=DB_USERNAME="<PG_USER>" \
  --from-literal=DB_PASSWORD="<PG_PASSWORD>" \
  --from-literal=DB_DATABASE="browseterm"

kubectl --context k3d-browseterm-k3s create secret generic browseterm-internal-api-token -n browseterm \
  --from-literal=CLOUD_INTERNAL_API_TOKEN="$(openssl rand -hex 32)"
# Save this value - browseterm-server-local's CLOUD_INTERNAL_API_TOKEN env var must match it exactly.

kubectl --context k3d-browseterm-k3s create secret generic browseterm-oauth-credentials -n browseterm \
  --from-literal=GOOGLE_CLIENT_ID="<real Google OAuth client id>" \
  --from-literal=GOOGLE_CLIENT_SECRET="<real Google OAuth client secret>" \
  --from-literal=GITHUB_CLIENT_ID="<real GitHub OAuth client id>" \
  --from-literal=GITHUB_CLIENT_SECRET="<real GitHub OAuth client secret>"
```

**Your OAuth app's authorized redirect URIs must include**
`http://browseterm.cloud.com:9999/auth/google/callback` and
`http://browseterm.cloud.com:9999/auth/github/callback` (Google Cloud Console / GitHub OAuth App
settings) — Google/GitHub reject the callback with `redirect_uri_mismatch` otherwise. This is
external, one-time, account-owner-only setup, not something any script here can do for you.

## 5. `/etc/hosts`

```bash
sudo sh -c 'printf "127.0.0.1\tbrowseterm.cloud.com\n" >> /etc/hosts'
```

(If you're also setting up Local on this same machine, see `SETUP-LOCAL.md` for its own
`/etc/hosts` line — both can coexist, they map to different host ports.)

## 6. Initialize the DB schema

```bash
kubectl --context k3d-browseterm-k3s port-forward service/browseterm-pg-service -n browseterm 55433:5432 &
cd browseterm-db
export DB_USERNAME=<PG_USER> DB_PASSWORD=<PG_PASSWORD> DB_HOST=localhost DB_PORT=55433 DB_DATABASE=browseterm
poetry install --no-root
poetry run python init.py
cd ..
kill %1   # stop the port-forward
```

`init.py` is destructive (`reset_database()`) — fine against a fresh Postgres, never run it
against one with real data. It also always squashes to a single fresh "Initial migration" (a new,
different revision id every time) — don't be surprised if it doesn't match a previously-documented
Alembic head; the schema is what matters, not the migration id.

## 7. Build and deploy `browseterm-server`

```bash
cd browseterm-server
docker image build -t browseterm-server-cloud:latest -f infra/cloud/Dockerfile.cloud .
docker tag browseterm-server-cloud:latest zim95/browseterm-server-cloud:latest
k3d image import zim95/browseterm-server-cloud:latest -c browseterm-k3s
```

`k3d image import` loads the image straight into the cluster's containerd — no registry push, no
Docker Hub credentials needed, much faster for local dev than `make build`'s default
`docker push` path.

Create/edit `env.mk` in this repo (see its own README's "Dev setup" section for the full variable
list — `NAMESPACE`, `REPO_NAME`, `REDIS_*`, `POSTGRES_HOST`/`PORT`, `AUTH_REDIRECT_BASE_URI`,
`BROWSETERM_LOCAL_CALLBACK_URL`, `BROWSETERM_ALLOWED_HOSTS`, `CLOUD_INGRESS_HOST`), then:

```bash
make setup
kubectl --context k3d-browseterm-k3s -n browseterm rollout status deploy/browseterm-server-cloud --timeout=90s
```

## 8. Verify

```bash
curl http://browseterm.cloud.com:9999/healthz
# {"status":"ok","postgres":"ok","redis":"ok"}

curl -o /dev/null -w "HTTP %{http_code}\nLocation: %{redirect_url}\n" "http://browseterm.cloud.com:9999/auth/google/start?target=local"
# HTTP 302, Location: https://accounts.google.com/o/oauth2/auth?...redirect_uri=http%3A%2F%2Fbrowseterm.cloud.com%3A9999%2Fauth%2Fgoogle%2Fcallback...
```

If the second command doesn't redirect to a real Google URL with your `client_id`, the
`browseterm-oauth-credentials` Secret is wrong or wasn't picked up — check
`kubectl -n browseterm describe deploy browseterm-server-cloud` for the env values (not the
secret values themselves, just that the keys resolved) and `kubectl -n browseterm logs
deploy/browseterm-server-cloud` for import errors.

## Rebuilding after a code change

```bash
docker image build -t browseterm-server-cloud:latest -f infra/cloud/Dockerfile.cloud .
docker tag browseterm-server-cloud:latest zim95/browseterm-server-cloud:latest
k3d image import zim95/browseterm-server-cloud:latest -c browseterm-k3s
kubectl --context k3d-browseterm-k3s -n browseterm rollout restart deploy/browseterm-server-cloud
kubectl --context k3d-browseterm-k3s -n browseterm rollout status deploy/browseterm-server-cloud --timeout=90s
```

## Teardown

```bash
k3d cluster delete browseterm-k3s
```

Deletes everything in this cluster (Postgres/Redis data included — it's local dev, not backed up).
