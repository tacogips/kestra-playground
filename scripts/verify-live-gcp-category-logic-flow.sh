#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: $0 IMAGE VERSION REVISION" >&2
  exit 2
fi

for command in curl gcloud jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

image="$1"
version="$2"
revision="$3"
project_id="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
live_domain_name="${LIVE_DOMAIN_NAME:?Set LIVE_DOMAIN_NAME}"
kestra_url="${KESTRA_URL:-https://${LIVE_GKE_SUBDOMAIN:-k8s}.${live_domain_name}}"
flow_namespace="playground.orders.staging"
flow_id="verify_gcp_category_logic_deployment"
username="$(gcloud secrets versions access latest \
  --project "$project_id" --secret kestra-dev-gke-kestra-basic-auth-username)"
password="$(gcloud secrets versions access latest \
  --project "$project_id" --secret kestra-dev-gke-kestra-basic-auth-password)"

for _ in {1..120}; do
  if curl --fail --silent --show-error --max-time 20 \
    --user "${username}:${password}" "${kestra_url%/}/" >/dev/null; then
    break
  fi
  sleep 10
done
if ! curl --fail --silent --show-error --max-time 20 \
  --user "${username}:${password}" "${kestra_url%/}/" >/dev/null; then
  echo "Kestra did not become ready: ${kestra_url}" >&2
  exit 1
fi

curl --fail --silent --show-error \
  --user "${username}:${password}" \
  "${kestra_url%/}/api/v1/main/flows/${flow_namespace}/${flow_id}" >/dev/null

execution_json="$(curl --fail --silent --show-error \
  --user "${username}:${password}" \
  --request POST \
  --form "logic_image=${image}" \
  --form "expected_version=${version}" \
  --form "expected_revision=${revision}" \
  "${kestra_url%/}/api/v1/main/executions/${flow_namespace}/${flow_id}")"
execution_id="$(jq -er '.id' <<<"$execution_json")"

for _ in {1..120}; do
  execution_json="$(curl --fail --silent --show-error \
    --user "${username}:${password}" \
    "${kestra_url%/}/api/v1/main/executions/${execution_id}")"
  state="$(jq -r '.state.current // empty' <<<"$execution_json")"
  case "$state" in
    SUCCESS) break ;;
    FAILED | KILLED | CANCELLED | WARNING)
      echo "Kestra execution ${execution_id} finished with ${state}." >&2
      curl --fail --silent --show-error --user "${username}:${password}" \
        "${kestra_url%/}/api/v1/main/logs/${execution_id}" | jq -r '.[] | .message // ""' >&2
      exit 1
      ;;
  esac
  sleep 5
done
if [[ "$state" != "SUCCESS" ]]; then
  echo "Kestra execution ${execution_id} did not finish: ${state:-unknown}." >&2
  exit 1
fi

for task_id in run_normal_batch_on_gce_a run_special_batch_on_gce_b; do
  task_state="$(jq -r --arg task_id "$task_id" \
    '[.taskRunList[] | select(.taskId == $task_id) | .state.current][-1] // ""' \
    <<<"$execution_json")"
  if [[ "$task_state" != "SUCCESS" ]]; then
    echo "Task ${task_id} did not succeed: ${task_state:-missing}." >&2
    exit 1
  fi
done

worker_a="$(jq -r \
  '[.taskRunList[] | select(.taskId == "run_normal_batch_on_gce_a") | (.workerId // .attempts[-1].workerId // "")][-1] // ""' \
  <<<"$execution_json")"
worker_b="$(jq -r \
  '[.taskRunList[] | select(.taskId == "run_special_batch_on_gce_b") | (.workerId // .attempts[-1].workerId // "")][-1] // ""' \
  <<<"$execution_json")"
if [[ -z "$worker_a" || -z "$worker_b" || "$worker_a" == "$worker_b" ]]; then
  echo "Expected distinct routed GCE worker IDs, got A=${worker_a:-missing}, B=${worker_b:-missing}." >&2
  exit 1
fi

logs_json="$(curl --fail --silent --show-error \
  --user "${username}:${password}" \
  "${kestra_url%/}/api/v1/main/logs/${execution_id}")"
log_messages="$(jq -r '.[] | .message // ""' <<<"$logs_json")"
for marker in \
  'category=orders batch=normal target=default-worker' \
  'category=orders batch=special target=dedicated-worker' \
  "kestra_category_batch_passed worker_group=gce-a version=${version} revision=${revision}" \
  "kestra_category_batch_passed worker_group=gce-b version=${version} revision=${revision}"; do
  if ! grep -Fq "$marker" <<<"$log_messages"; then
    echo "Missing expected Kestra log marker: ${marker}" >&2
    exit 1
  fi
done

printf 'Kestra execution passed: id=%s version=%s worker_a=%s worker_b=%s\n' \
  "$execution_id" "$version" "$worker_a" "$worker_b"
