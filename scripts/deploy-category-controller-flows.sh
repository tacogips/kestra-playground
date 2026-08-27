#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: $0 CONTROLLER_VERSION [FLOW_DIRECTORY]" >&2
  exit 2
fi

controller_version="$1"
flow_directory="${2:-kestra/flows-onprem/controller}"
project_id="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
region="${REGION:-asia-northeast1}"
namespace="${NAMESPACE:-kestra-dev}"
cluster_name="${GKE_CLUSTER_NAME:-kestra-dev}"
kestra_url="${KESTRA_URL:-}"
auth_secret_prefix="${KESTRA_AUTH_SECRET_PREFIX:-kestra-dev-gke}"
controller_statefulsets=(
  kestra-webserver
  kestra-executor
  kestra-scheduler
  kestra-indexer
)

for command in curl gcloud jq kubectl ruby; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done
if [[ -z "$project_id" || -z "$kestra_url" ]]; then
  echo "Set PROJECT_ID (or GCP_PROJECT_ID) and KESTRA_URL." >&2
  exit 1
fi
if [[ ! "$controller_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Controller version must match X.Y.Z: ${controller_version}" >&2
  exit 1
fi
if [[ ! -d "$flow_directory" ]]; then
  echo "Controller flow directory does not exist: ${flow_directory}" >&2
  exit 1
fi

# shellcheck source=scripts/lib/gke-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gke-auth.sh"
ensure_gke_kubectl_auth
gcloud container clusters get-credentials "$cluster_name" \
  --region "$region" \
  --project "$project_id"

secret_value() {
  gcloud secrets versions access latest --project="$project_id" --secret="$1"
}

export KESTRA_BASIC_AUTH_USERNAME
export KESTRA_BASIC_AUTH_PASSWORD
KESTRA_BASIC_AUTH_USERNAME="$(secret_value "${auth_secret_prefix}-kestra-basic-auth-username")"
KESTRA_BASIC_AUTH_PASSWORD="$(secret_value "${auth_secret_prefix}-kestra-basic-auth-password")"

wait_for_controller() {
  local statefulset=""
  local status=""

  for _ in {1..120}; do
    status="$(
      curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 \
        --user "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
        "${kestra_url%/}/api/v1/configs"
    )" || status="000"
    if [[ "$status" == "200" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "$status" != "200" ]]; then
    echo "Kestra controller did not become ready: ${kestra_url}" >&2
    exit 1
  fi

  for statefulset in "${controller_statefulsets[@]}"; do
    kubectl -n "$namespace" rollout status "statefulset/${statefulset}" --timeout=10m
  done
}

controller_snapshot() {
  local statefulset=""

  for statefulset in "${controller_statefulsets[@]}"; do
    kubectl -n "$namespace" get pod "${statefulset}-0" -o json |
      jq -cr '[
        .metadata.name,
        .metadata.uid,
        ([.status.containerStatuses[]?.restartCount] | add // 0)
      ] | @tsv'
  done
}

external_worker_snapshot() {
  gcloud compute instances list \
    --project "$project_id" \
    --filter='name=(kestra-dev-gce-a kestra-dev-gce-b)' \
    --format=json |
    jq -cr 'sort_by(.name)[] | [
      .name,
      (.id | tostring),
      .status,
      (.lastStartTimestamp // "")
    ] | @tsv'
}

require_expected_external_workers() {
  local snapshot_path="$1"
  local worker_count=""

  worker_count="$(wc -l <"$snapshot_path" | tr -d ' ')"
  if [[ "$worker_count" != "2" ]]; then
    echo "Expected two external worker VMs, found ${worker_count}." >&2
    cat "$snapshot_path" >&2
    exit 1
  fi
}

verify_registered_flows() {
  local flow=""
  local flow_id=""
  local flow_namespace=""

  shopt -s nullglob
  local flows=("$flow_directory"/*.yaml)
  if [[ "${#flows[@]}" -eq 0 ]]; then
    echo "No controller flow YAML files found in ${flow_directory}." >&2
    exit 1
  fi

  for flow in "${flows[@]}"; do
    flow_id="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("id")' "$flow")"
    flow_namespace="$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("namespace")' "$flow")"
    curl --fail --silent --show-error \
      --user "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
      "${kestra_url%/}/api/v1/main/flows/${flow_namespace}/${flow_id}" >/dev/null
    printf 'Verified controller flow: %s.%s\n' "$flow_namespace" "$flow_id"
  done
}

runtime_directory="$(mktemp -d "${TMPDIR:-/tmp}/kestra-controller-deploy.XXXXXX")"
cleanup() {
  rm -rf "$runtime_directory"
}
trap cleanup EXIT INT TERM

wait_for_controller
controller_snapshot >"${runtime_directory}/controller-before.tsv"
external_worker_snapshot >"${runtime_directory}/workers-before.tsv"
require_expected_external_workers "${runtime_directory}/workers-before.tsv"

printf 'Deploying orders controller release %s from %s.\n' \
  "$controller_version" "$flow_directory"
scripts/register-flows.sh "$kestra_url" "$flow_directory"
verify_registered_flows

controller_snapshot >"${runtime_directory}/controller-after.tsv"
external_worker_snapshot >"${runtime_directory}/workers-after.tsv"
require_expected_external_workers "${runtime_directory}/workers-after.tsv"

if ! cmp -s "${runtime_directory}/controller-before.tsv" "${runtime_directory}/controller-after.tsv"; then
  echo "A Kestra controller pod changed identity or restart count during flow deployment." >&2
  diff -u "${runtime_directory}/controller-before.tsv" \
    "${runtime_directory}/controller-after.tsv" >&2 || true
  exit 1
fi
if ! cmp -s "${runtime_directory}/workers-before.tsv" "${runtime_directory}/workers-after.tsv"; then
  echo "An external worker VM changed identity, status, or start time during flow deployment." >&2
  diff -u "${runtime_directory}/workers-before.tsv" \
    "${runtime_directory}/workers-after.tsv" >&2 || true
  exit 1
fi

printf 'Controller flow deployment passed: version=%s controller_restarted=false workers_restarted=false\n' \
  "$controller_version"
