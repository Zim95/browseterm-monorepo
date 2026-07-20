#!/usr/bin/env bash
# Fan the aggregated root env.mk out into each submodule's own env.mk/.env, using the
# var names each repo expects and path-derived values (HOST_DIR, in-cluster service hosts).
# Idempotent: safe to re-run. Generated files are gitignored inside each submodule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f env.mk ]; then
  echo "ERROR: $ROOT/env.mk not found. Copy env.mk.example to env.mk and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source env.mk; set +a

# In-cluster service DNS (same-namespace short names) + constants.
PG_HOST_INCLUSTER="browseterm-pg-service"
REDIS_HOST_INCLUSTER="browseterm-redis-service"
CM_DEV_HOST="container-maker-development-service"
CM_DEV_PORT="50052"
CM_HOST="container-maker-service"
CM_PORT="50052"

echo "Generating submodule env files from $ROOT/env.mk ..."

# ── postgres_ha ──
cat > postgres_ha/env.mk <<EOF
NAMESPACE=${NAMESPACE}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=${PG_DB}
POSTGRES_TEST_DB=${PG_TEST_DB}
EOF

# ── redis_ha ──
cat > redis_ha/env.mk <<EOF
NAMESPACE=${NAMESPACE}
REDIS_USER=${REDIS_USER}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DATA_DIR=${REDIS_DATA_DIR}
EOF

# ── cert-manager ──
cat > cert-manager/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
HOST_DIR=${ROOT}/cert-manager
EOF

# ── browseterm-dockerfiles (image builds + local snapshot_job runs) ──
cat > browseterm-dockerfiles/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
CONTAINER_ID=
DB_HOST=${PG_HOST_INCLUSTER}
DB_PORT=5432
DB_USERNAME=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
DB_DATABASE=${PG_DB}
REPO_PASSWORD=${REPO_PASSWORD}
SNAPSHOT_PATH=/mnt/snapshot
POD_NAME=
EOF

# ── snapshot_job ──
cat > browseterm-dockerfiles/snapshot_job/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
HOST_DIR=${ROOT}/browseterm-dockerfiles/snapshot_job
EOF

# ── container-maker ──
cat > container-maker/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
HOST_DIR=${ROOT}/container-maker
REPO_PASSWORD=${REPO_PASSWORD}
INGRESS_HOST=${INGRESS_HOST}
STORAGE_LAYER=${STORAGE_LAYER}
MINIO_ENDPOINT=${MINIO_ENDPOINT}
MINIO_BUCKET=${MINIO_BUCKET}
MINIO_SECURE=${MINIO_SECURE}
DB_HOST=${PG_HOST_INCLUSTER}
DB_PORT=5432
DB_USERNAME=${PG_USER}
DB_DATABASE=${PG_DB}
EOF

# ── socket-ssh ──
cat > socket-ssh/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
HOST_DIR=${ROOT}/socket-ssh
SOCKET_SSH_HOST=${SOCKET_SSH_HOST}
REDIS_HOST=${REDIS_HOST_INCLUSTER}
REDIS_PORT=6379
REDIS_USERNAME=${REDIS_USER}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}
ALLOWED_ORIGINS_DEV=http://${INGRESS_HOST}:9999,http://${INGRESS_HOST},http://localhost:9999
ALLOWED_ORIGINS_PROD=https://${INGRESS_HOST}
EOF

# ── browseterm-server ──
cat > browseterm-server/env.mk <<EOF
USER_NAME=${USER_NAME}
REPO_NAME=${REPO_NAME}
NAMESPACE=${NAMESPACE}
HOST_DIR=${ROOT}/browseterm-server
CONTAINER_MAKER_DEVELOPMENT_HOST=${CM_DEV_HOST}
CONTAINER_MAKER_DEVELOPMENT_PORT=${CM_DEV_PORT}
CONTAINER_MAKER_HOST=${CM_HOST}
CONTAINER_MAKER_PORT=${CM_PORT}
CONTAINER_MAKER_CERTS_SECRET_NAME=${CONTAINER_MAKER_CERTS_SECRET_NAME}
CERT_MANAGER_CRON_JOB_NAME=${CERT_MANAGER_CRON_JOB_NAME}
AUTH_REDIRECT_BASE_URI=${AUTH_REDIRECT_BASE_URI}
GOOGLE_CLIENT_ID=${SERVER_GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${SERVER_GOOGLE_CLIENT_SECRET}
GITHUB_CLIENT_ID=${SERVER_GITHUB_CLIENT_ID}
GITHUB_CLIENT_SECRET=${SERVER_GITHUB_CLIENT_SECRET}
REDIS_HOST=${REDIS_HOST_INCLUSTER}
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_USERNAME=${REDIS_USER}
REDIS_DB=${REDIS_DB}
POSTGRES_HOST=${PG_HOST_INCLUSTER}
POSTGRES_PORT=5432
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASSWORD}
POSTGRES_DB=${PG_DB}
SOCKET_SSH_HOST=${SOCKET_SSH_HOST}
SOCKET_SSH_WSS_URL=${SOCKET_SSH_WSS_URL}
INGRESS_HOST=${INGRESS_HOST}
EOF

# ── browseterm-db (.env; migrations run from the host over a port-forward, so localhost) ──
cat > browseterm-db/.env <<EOF
DB_USERNAME=${PG_USER}
DB_PASSWORD=${PG_PASSWORD}
DB_HOST=localhost
DB_PORT=5432
DB_DATABASE=${PG_DB}
TEST_DB_USERNAME=${PG_USER}
TEST_DB_PASSWORD=${PG_PASSWORD}
TEST_DB_HOST=localhost
TEST_DB_PORT=5432
TEST_DB_DATABASE=${PG_TEST_DB}
SQL_ECHO=false
EOF

echo "Done. Generated env files for: postgres_ha, redis_ha, cert-manager, browseterm-dockerfiles,"
echo "snapshot_job, container-maker, socket-ssh, browseterm-server, browseterm-db(.env)."
