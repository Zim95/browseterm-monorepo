#!/usr/bin/env bash
# Deploy BrowseTerm onto the single-node k3s cluster (PROD flow: built images pulled from the
# registry, NOT the docker-desktop dev live-mount). Assumes the cluster exists (scripts/setup.k3s.sh)
# and kubectl is on the `browseterm-k3s` context.
#
# Usage: ./scripts/deploy.k3s.sh [--fresh]     (--fresh runs the DESTRUCTIVE browseterm-db init.py)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
FRESH=0; [ "${1:-}" = "--fresh" ] && FRESH=1
# shellcheck disable=SC1091
set -a; source env.mk; set +a
NS="${NAMESPACE}"
step() { echo; echo "▶ $*"; }

# ── Preflight ──
CTX="$(kubectl config current-context 2>/dev/null || true)"
[ "$CTX" = "browseterm-k3s" ] || { echo "ERROR: context is '$CTX', expected 'browseterm-k3s'. Run scripts/setup.k3s.sh first."; exit 1; }

step "Generate per-submodule env files"; ./scripts/gen-env.sh

step "Namespace"; kubectl create namespace "$NS" 2>/dev/null || echo "  exists"

step "ingress-nginx"; kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s

step "MetalLB + pool (${METALLB_POOL} — must be on the k3s VM's subnet, e.g. 192.168.64.x)"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kubectl wait -n metallb-system --for=condition=ready pod --selector=app=metallb --timeout=180s
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

step "MinIO (object storage — no snapshot PVC; local storage retired)"
kubectl apply -f 02_cluster_infra/minio.yaml

step "Postgres"; make -C postgres_ha dev_pg_single_setup
kubectl wait --for=condition=ready pod/browseterm-pg -n "$NS" --timeout=150s

step "DB credentials Secret (single source of truth; workload + server consume it)"
kubectl create secret generic browseterm-db-credentials -n "$NS" \
  --from-literal=DB_HOST="browseterm-pg-service.${NS}.svc.cluster.local" \
  --from-literal=DB_PORT="5432" --from-literal=DB_USERNAME="${PG_USER}" \
  --from-literal=DB_PASSWORD="${PG_PASSWORD}" --from-literal=DB_DATABASE="${PG_DB}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ "$FRESH" = "1" ]; then
  step "browseterm-db init (DESTRUCTIVE) + NOTIFY triggers"
  kubectl port-forward service/browseterm-pg-service -n "$NS" 5432:5432 >/dev/null 2>&1 & PF=$!; sleep 5
  ( cd browseterm-db && poetry install --no-root >/dev/null && poetry run python init.py )
  kill "$PF" 2>/dev/null || true
  kubectl exec -i browseterm-pg -n "$NS" -- psql -U "${PG_USER}" -d "${PG_DB}" < scripts/notify-triggers.sql
fi

step "Redis (REDIS_DATA_DIR must be an ABSOLUTE path, e.g. /data)"; make -C redis_ha dev_redis_single_setup

step "cert-manager + trigger a cert job (mints container-maker[-development]-service-certs)"
make -C browseterm_workload/cert-manager prod_build
make -C browseterm_workload/cert-manager prod_setup
kubectl create job --from=cronjob/"${CERT_MANAGER_CRON_JOB_NAME}" "${CERT_MANAGER_CRON_JOB_NAME}-manual" -n "$NS" 2>/dev/null || true
echo "  waiting for ${CONTAINER_MAKER_CERTS_SECRET_NAME} ..."
for i in $(seq 1 45); do kubectl get secret "${CONTAINER_MAKER_CERTS_SECRET_NAME}" -n "$NS" >/dev/null 2>&1 && { echo "  cert ready"; break; }; sleep 4; done

step "Build + push all images (control plane + runtime)"; ./scripts/build-images.sh

step "Deploy services (PROD flow — registry-pull, real entrypoints, no hostPath)"
make -C container-maker prod_setup
make -C socket-ssh prod_setup
make -C browseterm-server prod_setup
make -C browseterm_workload/status_monitor dev_setup   # single deployment manifest (envFrom the DB Secret)

step "Wait for rollouts"
for d in container-maker browseterm-server socket-ssh status-monitor; do
  kubectl rollout status deploy/"$d" -n "$NS" --timeout=240s || true
done

echo; echo "✅ BrowseTerm deployed to k3s."; kubectl get pods -n "$NS"
