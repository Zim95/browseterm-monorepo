#!/usr/bin/env bash
# Tear BrowseTerm down (reverse of setup.sh).
# Usage: ./scripts/teardown.sh [--all]
#   --all   also remove cluster-scoped infra (MetalLB, ingress-nginx). Default leaves them.
set -uo pipefail   # not -e: teardown is best-effort, keep going on missing resources

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ALL=0; [ "${1:-}" = "--all" ] && ALL=1
# shellcheck disable=SC1091
set -a; source env.mk 2>/dev/null || true; set +a
NS="${NAMESPACE:-browseterm}"

step() { echo; echo "▶ $*"; }

step "Services (reverse order)"
make -C browseterm-server dev_teardown        || true
make -C socket-ssh        dev_teardown        || true
make -C container-maker   dev_teardown        || true
make -C cert-manager      prod_teardown       || true
make -C redis_ha          dev_redis_single_teardown || true
make -C postgres_ha       dev_pg_single_teardown    || true

step "Namespace ${NS} (removes MinIO, snapshot PVC, and everything else in it)"
kubectl delete namespace "${NS}" --wait=false 2>/dev/null || true

if [ "${ALL}" = "1" ]; then
  step "Cluster-scoped infra (MetalLB + ingress-nginx)"
  kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml --ignore-not-found 2>/dev/null || true
  kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml --ignore-not-found 2>/dev/null || true
fi

echo
echo "✅ Teardown issued. Verify: kubectl get ns ${NS}"
cat <<EOF
(optional) remove the loopback aliases in your own terminal:
  sudo ifconfig lo0 -alias 192.168.0.3
  sudo ifconfig lo0 -alias 192.168.0.4
EOF
