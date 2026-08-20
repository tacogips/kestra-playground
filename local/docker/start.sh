#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Start one batch group on its own, or both:
#   local/docker/start.sh            both groups (default)
#   local/docker/start.sh ec         PostgreSQL, Mailpit, EC Kestra, SSH workers
#   local/docker/start.sh affiliate  PostgreSQL, Mailpit, affiliate Kestra
BATCH_GROUP="${1:-${BATCH_GROUP:-all}}"
ENV_FILE="${ROOT_DIR}/local/docker/.env"
EC_ENV_FILE="${ROOT_DIR}/batch-groups/ec/config/envs/local.env"
AFFILIATE_ENV_FILE="${ROOT_DIR}/batch-groups/affiliate/config/envs/local.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/local/docker/.env.example" "${ENV_FILE}"
fi
if [[ ! -f "${EC_ENV_FILE}" ]]; then
  cp "${EC_ENV_FILE}.example" "${EC_ENV_FILE}"
fi
if [[ ! -f "${AFFILIATE_ENV_FILE}" ]]; then
  cp "${AFFILIATE_ENV_FILE}.example" "${AFFILIATE_ENV_FILE}"
fi

# The EC Kestra fork image bundles almost no plugins; make sure the plugin JARs
# that docker-compose.yml bind-mounts exist before compose resolves the mounts.
"${ROOT_DIR}/local/docker/fetch-plugins.sh"

compose_env_keys=()
while IFS='=' read -r key _; do
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  compose_env_keys+=("${key}")
done <"${ENV_FILE}"

env_args=()
for key in "${compose_env_keys[@]}"; do
  env_args+=("-u" "${key}")
done

compose() {
  env "${env_args[@]}" docker compose --env-file "${ENV_FILE}" -f "${ROOT_DIR}/local/docker/docker-compose.yml" "$@"
}

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

compose up -d postgres

echo "Waiting for PostgreSQL to accept connections..."
for _ in {1..60}; do
  if compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# The init script only runs on a fresh data volume; make sure the affiliate
# Kestra metadata database also exists on volumes created before the
# two-system split.
compose exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE ${AFFILIATE_KESTRA_DB}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${AFFILIATE_KESTRA_DB}')\gexec
SQL

# The SSH workers are EC remote-batch targets, and Mailpit is shared by both
# groups, so only the Kestra service and its own dependencies differ per group.
case "${BATCH_GROUP}" in
  all)
    services=()
    ;;
  ec)
    services=(mailpit kestra-ec remote-worker remote-worker-b)
    ;;
  affiliate)
    services=(mailpit kestra-affiliate)
    ;;
  *)
    echo "Unknown batch group: ${BATCH_GROUP}" >&2
    echo "Use one of: all, ec, affiliate" >&2
    exit 1
    ;;
esac

compose up -d "${services[@]+"${services[@]}"}"

echo "Mailpit (mock SMTP sink) UI is at http://localhost:8025"
if [[ "${BATCH_GROUP}" == "all" || "${BATCH_GROUP}" == "ec" ]]; then
  echo "EC Kestra is starting at http://localhost:8080"
  echo "Register EC flows with: scripts/register-flows.sh http://localhost:8080 batch-groups/ec/flows"
fi
if [[ "${BATCH_GROUP}" == "all" || "${BATCH_GROUP}" == "affiliate" ]]; then
  echo "Affiliate Kestra is starting at http://localhost:8082"
  echo "Register affiliate flows with: scripts/register-flows.sh http://localhost:8082 batch-groups/affiliate/flows"
fi
