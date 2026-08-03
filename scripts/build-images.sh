#!/usr/bin/env bash
# Build + push all BrowseTerm PROD images to the registry, from the monorepo's submodule copies.
#
# Run from the monorepo root (submodules must be synced to the commits you want to ship).
# Handles Docker Desktop's flaky proxy: pre-pull base images + BuildKit (NOT the legacy builder,
# which can't resolve DNS through the proxy → apt fails) + retries.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
set -a; source env.mk; set +a

# docker login once, then a shim so the per-repo build scripts' interactive `docker login` is a no-op.
if [ -n "${REPO_PASSWORD:-}" ]; then echo "${REPO_PASSWORD}" | docker login -u "${REPO_NAME}" --password-stdin; fi
REAL_DOCKER="$(command -v docker)"; SHIM="$(mktemp -d)"
printf '#!/usr/bin/env bash\n[ "$1" = "login" ] && exit 0\nexec %s "$@"\n' "$REAL_DOCKER" > "$SHIM/docker"
chmod +x "$SHIM/docker"; export PATH="$SHIM:$PATH"

echo "Pre-pulling base images (so builds skip the flaky proxy for base metadata)..."
for base in python:3.11-slim node:22.13.1-alpine ubuntu:latest; do docker pull "$base" >/dev/null 2>&1 || true; done

build() {  # <submodule-dir> <make-target> <name>
  local dir="$1" target="$2" name="$3" attempt
  for attempt in 1 2 3 4 5; do
    echo "== build $name (attempt $attempt) =="
    if ( cd "$ROOT/$dir" && make "$target" ) >/tmp/build_"$name".log 2>&1; then
      echo "== ✅ $name =="; return 0
    fi
    echo "   failed: $(grep -iE 'error|timeout|failed to' /tmp/build_"$name".log | tail -1)"; sleep 5
  done
  echo "== ❌ $name FAILED after 5 attempts =="; tail -12 /tmp/build_"$name".log; return 1
}

build browseterm_workload/cert-manager   prod_build   cert-manager
build container-maker                     prod_build   container-maker
build browseterm-server                   prod_build   browseterm-server
build socket-ssh                          prod_build   socket-ssh
build browseterm_workload/status_monitor  prod_build   status-monitor
build browseterm_workload/snapshot_job    prod_build   snapshot-job
build browseterm-dockerfiles              build_ubuntu ubuntu
echo "== all images built + pushed =="
