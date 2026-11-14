#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/kestra/config/envs/local.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/kestra/config/envs/local.env.example" "${ENV_FILE}"
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

container system start

container network create kestra-playground >/dev/null 2>&1 || true
container volume create kestra-postgres-data >/dev/null 2>&1 || true
container volume create kestra-data >/dev/null 2>&1 || true

container delete --force kestra-postgres >/dev/null 2>&1 || true
container delete --force kestra >/dev/null 2>&1 || true

container run -d \
  --name kestra-postgres \
  --network kestra-playground \
  -p 5432:5432 \
  -v kestra-postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  postgres:16

echo "Waiting for PostgreSQL to accept connections..."
for _ in {1..60}; do
  if container exec kestra-postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

container exec kestra-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE ${BATCH_DB}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${BATCH_DB}')\gexec
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${BATCH_DB_USER}') THEN
    CREATE ROLE ${BATCH_DB_USER} LOGIN PASSWORD '${BATCH_DB_PASSWORD}';
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE ${BATCH_DB} TO ${BATCH_DB_USER};
SQL

container exec kestra-postgres psql -U "${POSTGRES_USER}" -d "${BATCH_DB}" -v ON_ERROR_STOP=1 <<SQL
GRANT ALL ON SCHEMA public TO ${BATCH_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${BATCH_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${BATCH_DB_USER};
SQL

container run -d \
  --name kestra \
  --network kestra-playground \
  -p 8080:8080 \
  -p 8081:8081 \
  -v kestra-data:/app/storage \
  -v /tmp/kestra-wd:/tmp/kestra-wd \
  -v "${ROOT_DIR}/kestra/config/application.yaml:/etc/kestra/application.yaml" \
  -v "${ROOT_DIR}/batches:/app/kestra-playground/batches" \
  --env-file "${ENV_FILE}" \
  kestra/kestra:latest server standalone --worker-thread=64 --config /etc/kestra/application.yaml

echo "Kestra is starting at http://localhost:8080"
echo "Register flows with: scripts/register-flows.sh http://localhost:8080"
