#!/usr/bin/env bash
# One-command BrowseTerm deploy (Docker Desktop). Encodes the README's ordered sequence.
# Usage: ./scripts/setup.sh [--fresh]
#   --fresh   also run the DESTRUCTIVE browseterm-db init.py (drops+recreates schema, seeds).
#             Omit on re-runs to keep your data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FRESH=0; [ "${1:-}" = "--fresh" ] && FRESH=1

# shellcheck disable=SC1091
set -a; source env.mk; set +a
NS="${NAMESPACE}"

step() { echo; echo "▶ $*"; }

# ── Preflight ──
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "docker-desktop" ] || { echo "WARNING: kubectl context is '$CTX', expected 'docker-desktop'."; }

# Non-interactive registry auth, then a PATH shim so the per-repo build scripts' own
# interactive `docker login -u ...` calls become no-ops (we're already authenticated).
REAL_DOCKER="$(command -v docker)"
if [ -n "${REPO_PASSWORD:-}" ] && [ "${REPO_PASSWORD}" != "CHANGEME_DOCKERHUB_TOKEN" ]; then
  step "docker login as ${REPO_NAME} (non-interactive)"
  echo "${REPO_PASSWORD}" | "${REAL_DOCKER}" login -u "${REPO_NAME}" --password-stdin
fi
SHIM="$(mktemp -d)"; cat > "${SHIM}/docker" <<EOF
#!/usr/bin/env bash
[ "\$1" = "login" ] && exit 0
exec "${REAL_DOCKER}" "\$@"
EOF
chmod +x "${SHIM}/docker"; export PATH="${SHIM}:${PATH}"

step "Generate submodule env files from aggregated env.mk"
./scripts/gen-env.sh

step "Namespace"
kubectl create namespace "${NS}" 2>/dev/null || echo "  namespace ${NS} exists"

step "NGINX ingress controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s

step "MetalLB + IP pool (${METALLB_POOL})"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=180s
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: first-pool, namespace: metallb-system }
spec: { addresses: ["${METALLB_POOL}"] }
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: l2advertisement, namespace: metallb-system }
spec: { ipAddressPools: [first-pool] }
EOF

step "Cluster infra: snapshot PVC + MinIO"
kubectl apply -f 02_cluster_infra/snapshot-pvc.yaml
kubectl apply -f 02_cluster_infra/minio.yaml

step "Postgres (postgres_ha)"
make -C postgres_ha dev_pg_single_setup
kubectl rollout status deploy/browseterm-pg -n "${NS}" --timeout=120s 2>/dev/null || \
  kubectl wait --for=condition=ready pod/browseterm-pg -n "${NS}" --timeout=120s

if [ "${FRESH}" = "1" ]; then
  step "browseterm-db migrate + seed (DESTRUCTIVE: init.py) + re-apply NOTIFY triggers"
  kubectl port-forward service/browseterm-pg-service -n "${NS}" 5432:5432 >/dev/null 2>&1 &
  PF=$!; sleep 4
  ( cd browseterm-db && poetry install --no-root >/dev/null && poetry run python init.py )
  kill "${PF}" 2>/dev/null || true
  # init.py autogenerate drops the NOTIFY triggers — re-apply both (status + save).
  kubectl exec -i browseterm-pg -n "${NS}" -- psql -U "${PG_USER}" -d "${PG_DB}" < scripts/notify-triggers.sql
else
  echo "  (skipping DB init; pass --fresh for first-time schema create)"
fi

step "Redis (redis_ha)"
make -C redis_ha dev_redis_single_setup

step "cert-manager (internal mTLS) + trigger a cert job now"
make -C cert-manager prod_build
make -C cert-manager prod_setup
kubectl create job --from=cronjob/"${CERT_MANAGER_CRON_JOB_NAME}" "${CERT_MANAGER_CRON_JOB_NAME}-job" -n "${NS}" 2>/dev/null || true
echo "  waiting for cert secret ${CONTAINER_MAKER_CERTS_SECRET_NAME} ..."
for i in $(seq 1 30); do
  kubectl get secret "${CONTAINER_MAKER_CERTS_SECRET_NAME}" -n "${NS}" >/dev/null 2>&1 && { echo "  cert secret ready"; break; }
  sleep 4
done

step "Build in-cluster images (browseterm-dockerfiles)"
make -C browseterm-dockerfiles build_ubuntu
make -C browseterm-dockerfiles build_status_sidecar
make -C browseterm-dockerfiles/snapshot_job prod_build

step "Deploy services in order: container-maker → socket-ssh → browseterm-server"
for svc in container-maker socket-ssh browseterm-server; do
  case "$svc" in
    container-maker) ENTRY=./infra/k8s/development/entrypoint-development.sh ;;
    *)               ENTRY=./infra/development/entrypoint-development.sh ;;
  esac
  chmod +x "$svc/$ENTRY"
  make -C "$svc" dev_build
  make -C "$svc" dev_setup
done

step "Wait for rollouts + start the manually-started apps"
kubectl rollout status deploy/container-maker-development -n "${NS}" --timeout=180s
kubectl rollout status deploy/socket-ssh-development -n "${NS}" --timeout=180s
kubectl rollout status deploy/browseterm-server-development -n "${NS}" --timeout=180s
# container-maker auto-starts; server + socket-ssh idle (tail -f) so launch them detached.
SPOD=$(kubectl get pods -n "${NS}" -l app=browseterm-server-development --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "${NS}" "$SPOD" -- bash -c 'cd /app && VENV=$(poetry env info --path 2>/dev/null); setsid bash -c "source $VENV/bin/activate && exec python app.py" >/tmp/app.log 2>&1 </dev/null &' || true
KPOD=$(kubectl get pods -n "${NS}" -l app=socket-ssh-development --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "${NS}" "$KPOD" -- bash -c 'cd /app && setsid bash -c "npm install >/tmp/npm.log 2>&1 && exec npm start" >/tmp/socket.log 2>&1 </dev/null &' || true

rm -rf "${SHIM}"
echo
echo "✅ Deploy complete. Pods:"
kubectl get pods -n "${NS}"
cat <<EOF

Next (manual, needs sudo — see 00_docs/local_ip_setup.md):
  sudo ifconfig lo0 alias 192.168.0.3
  sudo ifconfig lo0 alias 192.168.0.4
  sudo sh -c 'printf "192.168.0.3\t${INGRESS_HOST}\n192.168.0.4\t${SOCKET_SSH_HOST}\n" >> /etc/hosts'
  ./portfwd.sh
Then open http://${INGRESS_HOST}:9999
EOF
