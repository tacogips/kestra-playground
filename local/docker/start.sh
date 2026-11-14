#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/local/docker/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ROOT_DIR}/local/docker/.env.example" "${ENV_FILE}"
fi

compose_env_keys=()
while IFS='=' read -r key _; do
  [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  compose_env_keys+=("${key}")
done <"${ENV_FILE}"

env_args=()
for key in "${compose_env_keys[@]}"; do
  env_args+=("-u" "${key}")
done

env "${env_args[@]}" docker compose --env-file "${ENV_FILE}" -f "${ROOT_DIR}/local/docker/docker-compose.yml" up -d

echo "Kestra is starting at http://localhost:8080"
echo "Register flows with: scripts/register-flows.sh http://localhost:8080"
