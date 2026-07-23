#!/usr/bin/env bash
# Single-command END-TO-END test of the one-command deploy/teardown.
#
# It runs the real thing: setup.sh --fresh (full from-scratch deploy) -> verifies the stack is
# actually serving -> teardown.sh (removes it). Proves `make setup_fresh` and `make teardown`
# both work and produce a working cluster.
#
# ⚠️ DESTRUCTIVE: setup.sh --fresh drops+recreates+seeds the DB, and teardown deletes the
#    namespace. Do NOT run this against an environment whose data you care about — it is a
#    from-scratch CI/smoke verification, not a health check for a live workspace.
#
# Usage: ./scripts/test.sh          # teardown leaves MetalLB/ingress
#        ./scripts/test.sh --all    # teardown also removes MetalLB/ingress
set -uo pipefail   # not -e: collect all check results, then always tear down

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
# shellcheck disable=SC1091
set -a; source env.mk 2>/dev/null || true; set +a
NS="${NAMESPACE:-browseterm}"
TD_ARG=""; [ "${1:-}" = "--all" ] && TD_ARG="--all"

PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
step() { echo; echo "▶ $*"; }

# First Running pod whose name contains $1 (labels vary; name match is robust).
pod_by_name() { kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep "$1" | grep Running | awk '{print $1}' | head -1; }

cleanup() { step "Teardown (setup/teardown are the unit under test)"; ./scripts/teardown.sh $TD_ARG || true; }
trap cleanup EXIT

# ── Deploy ──
step "Deploy: setup.sh --fresh"
if ./scripts/setup.sh --fresh; then ok "setup.sh --fresh completed"; else bad "setup.sh --fresh returned non-zero"; fi

# ── Workloads up ──
step "Deployments available"
for d in container-maker-development socket-ssh-development browseterm-server-development; do
  if kubectl -n "$NS" rollout status deploy/"$d" --timeout=30s >/dev/null 2>&1; then ok "$d rolled out"; else bad "$d not available"; fi
done
for p in browseterm-pg browseterm-redis; do
  ph="$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$ph" = "Running" ] && ok "$p Running" || bad "$p not Running (phase=${ph:-none})"
done

# ── Apps actually serve (setup starts uvicorn/node async, so retry) ──
step "browseterm-server serves on :9999"
SPOD="$(pod_by_name browseterm-server-development)"; code=000
for _ in $(seq 1 20); do
  code="$(kubectl -n "$NS" exec "$SPOD" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost:9999/ 2>/dev/null' 2>/dev/null || echo 000)"
  [ "$code" != "000" ] && break; sleep 3
done
[ "$code" != "000" ] && ok "browseterm-server responded (HTTP $code)" || bad "browseterm-server not responding on :9999"

step "socket-ssh WS server on :8000"
KPOD="$(pod_by_name socket-ssh-development)"; up=""
for _ in $(seq 1 20); do
  if kubectl -n "$NS" exec "$KPOD" -- sh -c 'grep -qi "listening on port 8000" /tmp/socket.log 2>/dev/null'; then up=1; break; fi
  sleep 3
done
[ -n "$up" ] && ok "socket-ssh listening on :8000" || bad "socket-ssh not listening on :8000"

# ── Result (teardown runs on EXIT via the trap) ──
step "Result: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  DEPLOY TEST FAILED"; exit 1; }
echo "  DEPLOY TEST PASSED"
