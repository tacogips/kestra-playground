#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${KESTRA_ENV_FILE:-}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${KESTRA_ENV_FILE}"
  set +a
fi

KESTRA_URL="${1:-${KESTRA_URL:-http://localhost:8080}}"
FLOW_DIR="${2:-kestra/flows}"

CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

echo "Waiting for Kestra at ${KESTRA_URL}"
for _ in {1..60}; do
  if curl "${CURL_AUTH[@]}" --silent --fail "${KESTRA_URL%/}/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

for flow in "${FLOW_DIR}"/*.yaml; do
  echo "Deploying ${flow} to ${KESTRA_URL}"
  response_file="$(mktemp)"
  status="$(
    curl "${CURL_AUTH[@]}" --silent --show-error \
      -o "${response_file}" \
      -w "%{http_code}" \
      -X POST \
      -H "Content-Type: application/x-yaml" \
      --data-binary @"${flow}" \
      "${KESTRA_URL%/}/api/v1/main/flows"
  )"

  if [[ "${status}" =~ ^2 ]]; then
    rm -f "${response_file}"
    continue
  fi

  if [[ "${status}" == "422" ]] && grep -q "Flow id already exists" "${response_file}"; then
    namespace="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("namespace")' "${flow}")"
    flow_id="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("id")' "${flow}")"
    curl "${CURL_AUTH[@]}" --fail --silent --show-error \
      -X PUT \
      -H "Content-Type: application/x-yaml" \
      --data-binary @"${flow}" \
      "${KESTRA_URL%/}/api/v1/main/flows/${namespace}/${flow_id}" >/dev/null
    rm -f "${response_file}"
    continue
  fi

  cat "${response_file}" >&2
  rm -f "${response_file}"
  exit 1
done

echo "Flows registered."
