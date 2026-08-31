# Setting up the Local cluster (`browseterm-k3s-local`)

This is the verified, working procedure for standing up Local's `browseterm-k3s-local` cluster —
`browseterm-server-local` (the browser UI + workspace APIs). It's `k3d`, same convention as Cloud
— see `SETUP-CLOUD.md` first if you haven't already (Local depends on Cloud being reachable; the
OAuth login flow and Device API both call out to it).

**What this covers vs. what it doesn't**: `browseterm-server-local` itself only — enough for
login, the home/profile/subscriptions pages, and the OAuth/handoff/device-bootstrap flow to work
end to end. `container-maker`, `socket-ssh`, `payment-gateway`, and the `browseterm_workload`
services (status_monitor, reaper, snapshot_job, cert-manager) are **not** covered here — they
weren't deployed as part of this session's work (see `progress_made.md`'s 2026-08-31 P07 entry),
so actual terminal creation will 404/timeout until those are set up too. This doc will get a
follow-up section once that's done.

## Prerequisites

- Docker Desktop (or another Docker engine) running.
- `k3d` (`brew install k3d`), `kubectl` (`brew install kubectl`).
- `/etc/hosts` has `127.0.0.1  browseterm.local.com`.
- Cloud already up and reachable at `http://browseterm.cloud.com:9999` — see `SETUP-CLOUD.md`.

## 1. Create the cluster

```bash
k3d cluster create browseterm-k3s-local -p "80:80@loadbalancer" --wait --timeout 90s
```

Port `80` (not `9999`) — matches `INGRESS_HOST=browseterm.local.com` with no port suffix, the
existing convention this repo's manifests/docs already use.

## 2. Remove k3s's bundled Traefik, install ingress-nginx

Same gotcha as Cloud — see `SETUP-CLOUD.md` step 2 for why. On a *freshly created* cluster this
sometimes isn't strictly necessary (Traefik's `svclb` may not have grabbed the ports yet when you
install ingress-nginx immediately after cluster creation), but do it anyway for consistency and
to avoid a flaky first-time-only race:

```bash
kubectl --context k3d-browseterm-k3s-local -n kube-system delete helmchart traefik --ignore-not-found
kubectl --context k3d-browseterm-k3s-local apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
kubectl --context k3d-browseterm-k3s-local -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
```

## 3. Namespace + placeholder DB credentials Secret

`browseterm-server-local`'s deployment manifest still references a `browseterm-db-credentials`
Secret (`POSTGRES_USER`/`PASSWORD`/`DB` `secretKeyRef`s) — this is **pre-existing, documented,
inert config** (P06: Local's actual code never uses these values for anything active; see that
repo's README "Trust boundary" section), but Kubernetes still requires the Secret to *exist* with
those keys for the pod to start at all. Placeholder values are fine:

```bash
kubectl --context k3d-browseterm-k3s-local create namespace browseterm --dry-run=client -o yaml | kubectl --context k3d-browseterm-k3s-local apply -f -

kubectl --context k3d-browseterm-k3s-local create secret generic browseterm-db-credentials -n browseterm \
  --from-literal=DB_HOST="unused" \
  --from-literal=DB_PORT="5432" \
  --from-literal=DB_USERNAME="unused" \
  --from-literal=DB_PASSWORD="unused" \
  --from-literal=DB_DATABASE="unused"
```

## 4. `/etc/hosts`

```bash
sudo sh -c 'printf "127.0.0.1\tbrowseterm.local.com\n" >> /etc/hosts'
```

## 5. Build and deploy `browseterm-server-local`

Use the **production-style** Dockerfile/Makefile targets (`prod_build`/`prod_setup`), not the
`dev_*` ones — the dev manifest expects a `HOST_DIR` hostPath volume mount of your live working
directory into the pod, which needs an explicit `k3d cluster create --volume ...` mapping at
cluster-creation time that this doc's step 1 doesn't set up. The prod-style image is
self-contained (`COPY . app/` at build time), no host mount needed:

```bash
cd browseterm-server-local
docker image build -t browseterm-server-development:latest -f infra/deployment/Dockerfile.deployment .
docker tag browseterm-server-development:latest zim95/browseterm-server:latest
k3d image import zim95/browseterm-server:latest -c browseterm-k3s-local
```

Create/edit `env.mk` in this repo (see its own README's "Dev Setup" section — `NAMESPACE`,
`REPO_NAME`, `BROWSETERM_CLOUD_API_URL=http://browseterm.cloud.com:9999`, `POSTGRES_*`
placeholders matching step 3 above, `SOCKET_SSH_*`/`PAYMENT_GATEWAY_*`/`CONTAINER_MAKER_*`
placeholders since those services aren't deployed yet, `INGRESS_HOST=browseterm.local.com`,
`COOKIE_SECURE=false`, `COOKIE_SAMESITE=lax`), then:

```bash
kubectl config use-context k3d-browseterm-k3s-local
make prod_setup
kubectl --context k3d-browseterm-k3s-local -n browseterm rollout status deploy/browseterm-server --timeout=90s
```

## 6. Verify

```bash
curl -o /dev/null -w "HTTP %{http_code}\n" http://browseterm.local.com/
# HTTP 302 (home redirects; expected)

curl http://browseterm.local.com/login | grep -o 'href="/auth/[a-z]*"'
# href="/auth/google"
# href="/auth/github"

curl -o /dev/null -w "HTTP %{http_code}\nLocation: %{redirect_url}\n" http://browseterm.local.com/auth/google
# HTTP 302, Location: http://browseterm.cloud.com:9999/auth/google/start?target=local

curl -X POST http://browseterm.local.com/auth/refresh
# {"error":"Not authenticated"} with no cookie - confirms the route exists and is wired
```

For the *actual* end-to-end login (past this point), your OAuth app needs the redirect URIs
registered on Cloud's side — see `SETUP-CLOUD.md` step 4's note. Once that's done, opening
`http://browseterm.local.com/login` in a real browser and clicking Sign in should complete the
whole chain: Local → Cloud OAuth start → provider → Cloud callback → handoff → Local
`/auth/callback` → home page, authenticated.

## Rebuilding after a code change

```bash
docker image build -t browseterm-server-development:latest -f infra/deployment/Dockerfile.deployment .
docker tag browseterm-server-development:latest zim95/browseterm-server:latest
k3d image import zim95/browseterm-server:latest -c browseterm-k3s-local
kubectl --context k3d-browseterm-k3s-local -n browseterm rollout restart deploy/browseterm-server
kubectl --context k3d-browseterm-k3s-local -n browseterm rollout status deploy/browseterm-server --timeout=90s
```

## Teardown

```bash
k3d cluster delete browseterm-k3s-local
```

## Next: bringing up the rest (not yet done, not covered here)

`container-maker`, `socket-ssh`, `payment-gateway`, and `browseterm_workload` (status_monitor,
reaper, snapshot_job, cert-manager) all need to be built and deployed into this same cluster
before real terminal creation/save/resume works. Each has its own `dev_build`/`dev_setup` (or
`prod_*`) Makefile targets already, following the same `k3d image import`-instead-of-registry-push
pattern shown above — the missing piece is wiring their `env.mk` values and deployment order
correctly (container-maker → payment-gateway → socket-ssh → the workload jobs, per the old
`browseterm-monorepo/scripts/setup.sh`'s ordering, which is otherwise stale — see that script's
own header comment). Not attempted yet; this section will get filled in once it is.
