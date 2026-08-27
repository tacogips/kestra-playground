#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
  echo "Usage: $0 CONTROLLER_VERSION [CATEGORY]" >&2
  exit 2
fi

controller_version="$1"
category="${2:-orders}"
release_ref="${category}-controller-v${controller_version}"
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

for command in curl gcloud jq kubectl uv; do
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
if [[ ! -f "category-controllers/${category}/category.yaml" ]]; then
  echo "Category controller manifest does not exist: category-controllers/${category}/category.yaml" >&2
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

runtime_directory="$(mktemp -d "${TMPDIR:-/tmp}/kestra-controller-deploy.XXXXXX")"
cleanup() {
  rm -rf "$runtime_directory"
}
trap cleanup EXIT INT TERM

wait_for_controller
controller_snapshot >"${runtime_directory}/controller-before.tsv"
external_worker_snapshot >"${runtime_directory}/workers-before.tsv"
require_expected_external_workers "${runtime_directory}/workers-before.tsv"

printf 'Reconciling %s controller release %s.\n' "$category" "$controller_version"
reconcile_output="$(
  scripts/reconcile-kestra-category-flows.sh \
    --category "$category" \
    --environment staging \
    --ref "$release_ref" \
    --apply \
    --delete
)"
printf '%s\n' "$reconcile_output"

# A second apply is a release gate: identical Git and server state must not create a revision.
idempotency_output="$(
  scripts/reconcile-kestra-category-flows.sh \
    --category "$category" \
    --environment staging \
    --ref "$release_ref" \
    --apply \
    --delete
)"
printf '%s\n' "$idempotency_output"
if ! jq -e \
  '.create == [] and .update == [] and .delete == [] and (.unchanged | length > 0)' \
  <<<"$idempotency_output" >/dev/null; then
  echo "The second reconciliation was not an idempotent no-op." >&2
  exit 1
fi

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

printf 'Controller flow deployment passed: category=%s version=%s exact_state=true idempotent=true controller_restarted=false workers_restarted=false\n' \
  "$category" "$controller_version"
