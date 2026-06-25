#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/local/docker/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/local/docker/.env.example" "${ENV_FILE}"
fi

docker compose --env-file "${ENV_FILE}" -f "${ROOT_DIR}/local/docker/docker-compose.yml" up -d

echo "Kestra is starting at http://localhost:8080"
echo "Register flows with: scripts/register-flows.sh http://localhost:8080"
