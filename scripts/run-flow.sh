#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_ID="${1:?Usage: scripts/run-flow.sh <flow-id> [business-date] [kestra-url]}"

if [[ -n "${KESTRA_ENV_FILE:-}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${KESTRA_ENV_FILE}"
  set +a
fi

# shellcheck source=scripts/lib/business-date.sh
source "${SCRIPT_DIR}/lib/business-date.sh"
BUSINESS_DATE="$(resolve_business_date "${2:-}")"
KESTRA_URL="${3:-${KESTRA_URL:-http://localhost:8080}}"
NAMESPACE="${NAMESPACE:-playground.ecommerce}"

CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

response_file="$(mktemp)"
trap 'rm -f "${response_file}"' EXIT

status="$(
  curl "${CURL_AUTH[@]}" --silent --show-error \
    -o "${response_file}" \
    -w "%{http_code}" \
    -X POST \
    -F "business_date=${BUSINESS_DATE}" \
    "${KESTRA_URL%/}/api/v1/main/executions/${NAMESPACE}/${FLOW_ID}"
)" || status="000"

if [[ ! "${status}" =~ ^2 ]]; then
  echo "Flow execution request failed with HTTP ${status}." >&2
  cat "${response_file}" >&2
  exit 1
fi

if ! jq -e '.id and .namespace and .flowId' "${response_file}" >/dev/null 2>&1; then
  echo "Flow execution response was not a Kestra execution JSON document." >&2
  head -c 500 "${response_file}" >&2
  echo >&2
  exit 1
fi

cat "${response_file}"
