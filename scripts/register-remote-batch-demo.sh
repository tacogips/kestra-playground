#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KESTRA_URL="${1:-${KESTRA_URL:-http://localhost:8080}}"
NAMESPACE="playground.remote_batch"
ADAPTER="${REMOTE_BATCH_ADAPTER:-ssh}"
FIXTURE_ROOT="$(mktemp -d)"
REMOTE_BATCH_BUNDLE_DIR="${REMOTE_BATCH_BUNDLE_DIR:-${FIXTURE_ROOT}/bundles}"
FLOW_ROOT="${ROOT_DIR}/kestra/flows-remote-batch"
FLOW_REGISTER_DIR="${FIXTURE_ROOT}/flows"

cleanup() {
  rm -rf -- "${FIXTURE_ROOT}"
}
trap cleanup EXIT

if [[ -n "${KESTRA_ENV_FILE:-}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${KESTRA_ENV_FILE}"
  set +a
fi

CURL_AUTH=()
if [[ -n "${KESTRA_BASIC_AUTH_USERNAME:-}" && -n "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  CURL_AUTH=(-u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}")
fi

upload_namespace_file() {
  local source_file="$1"
  local destination_name="$2"
  local response_file
  local status

  response_file="$(mktemp)"
  status="$(
    curl "${CURL_AUTH[@]}" --silent --show-error \
      -o "${response_file}" \
      -w "%{http_code}" \
      -X POST \
      -F "fileContent=@${source_file}" \
      "${KESTRA_URL%/}/api/v1/main/namespaces/${NAMESPACE}/files?path=${destination_name}"
  )" || status="000"

  if [[ ! "${status}" =~ ^2 ]]; then
    echo "Namespace file upload failed for ${destination_name} with HTTP ${status}." >&2
    cat "${response_file}" >&2
    rm -f "${response_file}"
    return 1
  fi

  rm -f "${response_file}"
  echo "Uploaded ${source_file} as ${NAMESPACE}/${destination_name}"
}

mkdir -p "${FLOW_REGISTER_DIR}"
case "${ADAPTER}" in
  all)
    flow_names=(
      00_remote_batch_runner.yaml
      01_routed_batch_runner.yaml
      export_database_to_csv.yaml
      export_database_to_csv_routed.yaml
      parse_application_logs.yaml
      parse_application_logs_routed.yaml
    )
    ;;
  ssh)
    flow_names=(
      00_remote_batch_runner.yaml
      export_database_to_csv.yaml
      parse_application_logs.yaml
    )
    ;;
  routed)
    flow_names=(
      01_routed_batch_runner.yaml
      export_database_to_csv_routed.yaml
      parse_application_logs_routed.yaml
    )
    ;;
  *)
    echo "REMOTE_BATCH_ADAPTER must be all, ssh, or routed; got ${ADAPTER}." >&2
    exit 1
    ;;
esac

for flow_name in "${flow_names[@]}"; do
  ln -s "${FLOW_ROOT}/${flow_name}" "${FLOW_REGISTER_DIR}/${flow_name}"
done

"${ROOT_DIR}/scripts/register-flows.sh" \
  "${KESTRA_URL}" \
  "${FLOW_REGISTER_DIR}"
"${ROOT_DIR}/scripts/build-remote-batch-bundles.sh" "${REMOTE_BATCH_BUNDLE_DIR}"
upload_namespace_file \
  "${ROOT_DIR}/batches/db_export/export_database.py" \
  batches/db_export/export_database.py
upload_namespace_file \
  "${REMOTE_BATCH_BUNDLE_DIR}/db_export.tar.gz" \
  bundles/db_export.tar.gz
upload_namespace_file \
  "${ROOT_DIR}/batches/log_parse/parse_logs.py" \
  batches/log_parse/parse_logs.py
upload_namespace_file \
  "${REMOTE_BATCH_BUNDLE_DIR}/log_parse.tar.gz" \
  bundles/log_parse.tar.gz

echo "Remote batch framework and ${ADAPTER} examples registered."
