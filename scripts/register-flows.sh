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
REGISTER_FLOW_ATTEMPTS="${REGISTER_FLOW_ATTEMPTS:-6}"
REGISTER_FLOW_RETRY_DELAY="${REGISTER_FLOW_RETRY_DELAY:-10}"

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

retryable_status() {
  local status="$1"

  [[ "${status}" == "000" || "${status}" == "408" || "${status}" == "409" || "${status}" == "429" || "${status}" =~ ^5 ]]
}

html_response() {
  local response_file="$1"

  grep -Eiq '<!doctype html|<html' "${response_file}"
}

post_flow() {
  local flow="$1"
  local response_file="$2"
  local status

  status="$(
    curl "${CURL_AUTH[@]}" --silent --show-error \
      -o "${response_file}" \
      -w "%{http_code}" \
      -X POST \
      -H "Content-Type: application/x-yaml" \
      --data-binary @"${flow}" \
      "${KESTRA_URL%/}/api/v1/main/flows"
  )" || status="000"

  if [[ "${status}" =~ ^2 ]] && html_response "${response_file}"; then
    status="599"
  fi

  printf '%s' "${status}"
}

put_flow() {
  local flow="$1"
  local namespace="$2"
  local flow_id="$3"
  local response_file="$4"
  local status

  status="$(
    curl "${CURL_AUTH[@]}" --silent --show-error \
      -o "${response_file}" \
      -w "%{http_code}" \
      -X PUT \
      -H "Content-Type: application/x-yaml" \
      --data-binary @"${flow}" \
      "${KESTRA_URL%/}/api/v1/main/flows/${namespace}/${flow_id}"
  )" || status="000"

  if [[ "${status}" =~ ^2 ]] && html_response "${response_file}"; then
    status="599"
  fi

  printf '%s' "${status}"
}

shopt -s nullglob
flows=("${FLOW_DIR}"/*.yaml)
if [[ "${#flows[@]}" -eq 0 ]]; then
  echo "No flow YAML files found in ${FLOW_DIR}" >&2
  exit 1
fi

for flow in "${flows[@]}"; do
  echo "Deploying ${flow} to ${KESTRA_URL}"
  response_file="$(mktemp)"
  status=""

  for attempt in $(seq 1 "${REGISTER_FLOW_ATTEMPTS}"); do
    : >"${response_file}"
    status="$(post_flow "${flow}" "${response_file}")"

    if [[ "${status}" =~ ^2 ]]; then
      rm -f "${response_file}"
      continue 2
    fi

    if [[ "${status}" == "422" ]] && grep -q "Flow id already exists" "${response_file}"; then
      namespace="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("namespace")' "${flow}")"
      flow_id="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("id")' "${flow}")"
      : >"${response_file}"
      status="$(put_flow "${flow}" "${namespace}" "${flow_id}" "${response_file}")"

      if [[ "${status}" =~ ^2 ]]; then
        rm -f "${response_file}"
        continue 2
      fi
    fi

    if [[ "${attempt}" -lt "${REGISTER_FLOW_ATTEMPTS}" ]] && retryable_status "${status}"; then
      echo "Flow registration for ${flow} returned HTTP ${status}; retrying in ${REGISTER_FLOW_RETRY_DELAY}s." >&2
      sleep "${REGISTER_FLOW_RETRY_DELAY}"
      continue
    fi

    break
  done

  echo "Flow registration for ${flow} failed with HTTP ${status}." >&2
  cat "${response_file}" >&2
  rm -f "${response_file}"
  exit 1
done

echo "Flows registered."
