#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
FLOW_NAMESPACE="playground.worker_routing"
FLOW_ID="verify_category_batch_image_routing"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in curl gcloud jq kubectl yq; do
  require_command "$command"
done

if [[ -z "$PROJECT_ID" || -z "$LIVE_DOMAIN_NAME" ]]; then
  echo "Missing PROJECT_ID/GCP_PROJECT_ID or LIVE_DOMAIN_NAME." >&2
  exit 1
fi

# shellcheck source=scripts/lib/gke-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gke-auth.sh"
ensure_gke_kubectl_auth

secret_value() {
  gcloud secrets versions access latest --project="$PROJECT_ID" --secret="$1"
}

wait_for_ui() {
  local url="$1"
  local username="$2"
  local password="$3"

  for _ in {1..120}; do
    if curl --fail --silent --show-error --max-time 20 \
      --user "${username}:${password}" \
      "${url%/}/" >/dev/null; then
      return 0
    fi
    sleep 10
  done

  echo "Kestra UI did not become ready: ${url}" >&2
  return 1
}

wait_for_execution() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"
  local execution_json=""
  local state=""

  for _ in {1..180}; do
    execution_json="$(
      curl --fail --silent --show-error \
        --user "${username}:${password}" \
        "${url%/}/api/v1/main/executions/${execution_id}"
    )"
    state="$(jq -r '.state.current // empty' <<<"${execution_json}")"

    case "$state" in
      SUCCESS)
        printf '%s\n' "$execution_json"
        return 0
        ;;
      FAILED | KILLED | CANCELLED | WARNING)
        echo "Execution ${execution_id} finished with state ${state}." >&2
        jq -r '.taskRunList // []' <<<"${execution_json}" >&2
        return 1
        ;;
    esac
    sleep 5
  done

  echo "Execution ${execution_id} did not finish. Last state: ${state:-unknown}." >&2
  return 1
}

wait_for_example_pods() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-category-batch-example,kestra-playground.tacogips.io/execution=${execution_id}"
  local pods_json=""

  for _ in {1..60}; do
    pods_json="$(kubectl -n "$NAMESPACE" get pods --selector "$selector" -o json)"
    if [[ "$(jq '.items | length' <<<"${pods_json}")" == "2" ]]; then
      printf '%s\n' "$pods_json"
      return 0
    fi
    sleep 2
  done

  echo "Expected two category example Pods for execution ${execution_id}." >&2
  kubectl -n "$NAMESPACE" get pods --selector "$selector" -o wide >&2 || true
  return 1
}

assert_task_success() {
  local execution_json="$1"
  local task_id="$2"
  local state=""

  state="$(
    jq -r --arg task_id "$task_id" '
      [.taskRunList // [] | .[] | select(.taskId == $task_id) | .state.current][-1] // ""
    ' <<<"${execution_json}"
  )"
  if [[ "$state" != "SUCCESS" ]]; then
    echo "Expected task ${task_id} to be SUCCESS, got ${state:-missing}." >&2
    return 1
  fi
}

task_worker_id() {
  local execution_json="$1"
  local task_id="$2"

  jq -r --arg task_id "$task_id" '
    [
      .taskRunList // []
      | .[]
      | select(.taskId == $task_id)
      | (.workerId // .worker.id // .attempts[-1].workerId // "")
    ][-1] // ""
  ' <<<"${execution_json}"
}

execution_logs() {
  local url="$1"
  local username="$2"
  local password="$3"
  local execution_id="$4"

  curl --fail --silent --show-error \
    --user "${username}:${password}" \
    "${url%/}/api/v1/main/logs/${execution_id}"
}

cleanup_example_pods() {
  local execution_id="$1"
  local selector="app.kubernetes.io/name=kestra-category-batch-example,kestra-playground.tacogips.io/execution=${execution_id}"

  kubectl -n "$NAMESPACE" delete pods --selector "$selector" --ignore-not-found
}

gke_url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
gke_username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
gke_password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"

gcloud container clusters get-credentials kestra-dev \
  --region "$REGION" \
  --project "$PROJECT_ID"

export KESTRA_BASIC_AUTH_USERNAME="$gke_username"
export KESTRA_BASIC_AUTH_PASSWORD="$gke_password"

wait_for_ui "$gke_url" "$gke_username" "$gke_password"
scripts/register-flows.sh "$gke_url" kestra/flows-worker-routing

response="$(
  curl --fail --silent --show-error \
    --user "${gke_username}:${gke_password}" \
    --request POST \
    --form "kubernetes_namespace=${NAMESPACE}" \
    "${gke_url%/}/api/v1/main/executions/${FLOW_NAMESPACE}/${FLOW_ID}"
)"
execution_id="$(jq -er '.id' <<<"${response}")"
echo "${FLOW_ID}: ${execution_id}"

cleanup_on_exit() {
  cleanup_example_pods "$execution_id" >/dev/null 2>&1 || true
}
trap cleanup_on_exit EXIT

pods_json="$(wait_for_example_pods "$execution_id")"
execution_json="$(wait_for_execution "$gke_url" "$gke_username" "$gke_password" "$execution_id")"

assert_task_success "$execution_json" normal_batch_on_category_worker
assert_task_success "$execution_json" special_batch_on_dedicated_worker

normal_worker="$(task_worker_id "$execution_json" normal_batch_on_category_worker)"
special_worker="$(task_worker_id "$execution_json" special_batch_on_dedicated_worker)"
if [[ -z "$normal_worker" || -z "$special_worker" ]]; then
  echo "Expected both category tasks to report worker IDs." >&2
  exit 1
fi
if [[ "$normal_worker" == "$special_worker" ]]; then
  echo "Expected category tasks on different workers, got ${normal_worker} for both." >&2
  exit 1
fi

runtime_config="$(
  kubectl -n "$NAMESPACE" get configmap kestra-runtime-config -o json \
    | jq -r '.data["application.yaml"]'
)"
controller_queues="$(
  yq -r '.kestra.worker.routing.groupQueueMappings.controller.queues[].workerQueueId' \
    <<<"$runtime_config" \
    | sort
)"
if [[ "$controller_queues" != $'default\nsystem' ]]; then
  echo "Expected the controller worker group to subscribe only to default and system queues." >&2
  exit 1
fi
if ! kubectl -n "$NAMESPACE" logs statefulset/kestra-worker --all-containers=true \
  | grep -F "workerId=${normal_worker}, workerGroup=controller" >/dev/null; then
  echo "Unselected task worker ${normal_worker} was not confirmed in the controller worker group." >&2
  exit 1
fi
if ! kubectl -n "$NAMESPACE" logs statefulset/kestra-gke-worker-large -c kestra-worker \
  | grep -F "workerId=${special_worker}, workerGroup=gke-large" >/dev/null; then
  echo "Selected task worker ${special_worker} was not confirmed in the gke-large worker group." >&2
  exit 1
fi

expected_image="${CATEGORY_BATCH_IMAGE:-}"
if [[ -z "$expected_image" ]]; then
  expected_image="$(
    kubectl -n "$NAMESPACE" get secret kestra-secrets -o json \
      | jq -r '.data.ENV_CATEGORY_BATCH_IMAGE | @base64d'
  )"
fi
actual_images="$(jq -r '[.items[].spec.containers[0].image] | unique | .[]' <<<"${pods_json}")"
if [[ "$actual_images" != "$expected_image" ]]; then
  echo "Expected both category Pods to use ${expected_image}, got ${actual_images:-missing}." >&2
  exit 1
fi

normal_command="$(
  jq -r '.items[] | select(.metadata.labels["kestra-playground.tacogips.io/batch"] == "normal") | .spec.containers[0].command[0]' \
    <<<"${pods_json}"
)"
special_command="$(
  jq -r '.items[] | select(.metadata.labels["kestra-playground.tacogips.io/batch"] == "special") | .spec.containers[0].command[0]' \
    <<<"${pods_json}"
)"
if [[ "$normal_command" != "/app/batches/normal_batch.sh" || "$special_command" != "/app/batches/special_batch.sh" ]]; then
  echo "Category Pods did not select the expected batch commands." >&2
  exit 1
fi

logs_json="$(execution_logs "$gke_url" "$gke_username" "$gke_password" "$execution_id")"
log_messages="$(jq -r '(if type == "array" then . else (.results // []) end)[] | .message // ""' <<<"${logs_json}")"
for marker in \
  "category=orders batch=normal target=default-worker" \
  "category=orders batch=special target=dedicated-worker"; do
  if ! grep -Fq "$marker" <<<"${log_messages}"; then
    echo "Missing expected batch log marker: ${marker}" >&2
    exit 1
  fi
done

echo "Category batch image routing execution ${execution_id} succeeded."
echo "image=${expected_image}"
echo "normal_worker=${normal_worker}"
echo "normal_worker_group=controller queues=default,system"
echo "special_worker=${special_worker}"
echo "special_worker_group=gke-large queue=gke-large"
jq -r '
  "Batch Pods:",
  (["name", "batch", "image", "node", "phase"] | @tsv),
  (.items[] | [
    .metadata.name,
    .metadata.labels["kestra-playground.tacogips.io/batch"],
    .spec.containers[0].image,
    (.spec.nodeName // ""),
    (.status.phase // "")
  ] | @tsv)
' <<<"${pods_json}"

cleanup_example_pods "$execution_id"
trap - EXIT
