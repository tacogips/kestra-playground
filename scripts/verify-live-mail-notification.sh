#!/usr/bin/env bash
# Verify the affiliate-category mail notification flows on the GKE environment.
#
# Registers batch-groups/affiliate/flows on the live GKE Kestra, runs the sample
# affiliate batch once on the success path and once on the failure path, and
# asserts through a port-forward to the in-cluster Mailpit sink that the expected
# execution summary mails and the errors-block mail arrived. Nothing is relayed to
# a real MTA: Mailpit only stores what it receives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
BUSINESS_DATE="${1:-${BUSINESS_DATE:-2026-06-25}}"
MAILPIT_LOCAL_PORT="${MAILPIT_LOCAL_PORT:-18025}"
MAILPIT_URL="http://127.0.0.1:${MAILPIT_LOCAL_PORT}"
NOTIFICATION_WAIT_SECONDS="${NOTIFICATION_WAIT_SECONDS:-180}"
FLOW_DIR_1X="${ROOT_DIR}/batch-groups/affiliate/flows"
FLOW_DIR_2X="${ROOT_DIR}/kestra/flows-notification-affiliate"
PORT_FORWARD_PID=""

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in curl kubectl python3; do
  require_command "${command}"
done

# shellcheck source=scripts/lib/gke-auth.sh
source "${SCRIPT_DIR}/lib/gke-auth.sh"
ensure_gke_kubectl_auth

KESTRA_URL="${KESTRA_URL:-}"
if [[ -z "${KESTRA_URL}" ]]; then
  if [[ -z "${LIVE_DOMAIN_NAME}" ]]; then
    echo "Set KESTRA_URL, or LIVE_DOMAIN_NAME so the GKE endpoint can be derived." >&2
    exit 1
  fi
  KESTRA_URL="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
fi

if [[ -z "${KESTRA_BASIC_AUTH_USERNAME:-}" || -z "${KESTRA_BASIC_AUTH_PASSWORD:-}" ]]; then
  require_command gcloud
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "Set KESTRA_BASIC_AUTH_USERNAME and KESTRA_BASIC_AUTH_PASSWORD, or PROJECT_ID to read them from Secret Manager." >&2
    exit 1
  fi
  KESTRA_BASIC_AUTH_USERNAME="$(gcloud secrets versions access latest --project="${PROJECT_ID}" --secret=kestra-dev-gke-kestra-basic-auth-username)"
  KESTRA_BASIC_AUTH_PASSWORD="$(gcloud secrets versions access latest --project="${PROJECT_ID}" --secret=kestra-dev-gke-kestra-basic-auth-password)"
fi
export KESTRA_BASIC_AUTH_USERNAME KESTRA_BASIC_AUTH_PASSWORD

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "${PORT_FORWARD_PID}" ]] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi

  exit "${status}"
}
trap cleanup EXIT INT TERM

kestra_api() {
  curl --silent --show-error --fail -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" "$@"
}

echo "Waiting for the Mailpit sink in namespace ${NAMESPACE}"
kubectl -n "${NAMESPACE}" rollout status deployment/mailpit --timeout=180s

echo "Port-forwarding the Mailpit API to ${MAILPIT_URL}"
kubectl -n "${NAMESPACE}" port-forward service/mailpit "${MAILPIT_LOCAL_PORT}:8025" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

for _ in {1..30}; do
  if curl --silent --fail "${MAILPIT_URL}/api/v1/info" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl --silent --show-error --fail "${MAILPIT_URL}/api/v1/info" >/dev/null

echo "Checking that the Email plugin is available on ${KESTRA_URL}"
if ! kestra_api "${KESTRA_URL%/}/api/v1/plugins" | grep -q "io.kestra.plugin.email.MailExecution"; then
  echo "The Email plugin is not loaded on ${KESTRA_URL}." >&2
  exit 1
fi

echo "Clearing the Mailpit mailbox"
curl --silent --show-error --fail -X DELETE "${MAILPIT_URL}/api/v1/messages" >/dev/null

# The flows exist in two variants because neither the Flow trigger nor the task
# routing is portable across lineages. Kestra 2 removed the condition plugins the
# 1.x variant scopes its trigger with and rejects it with
# `Unrecognized field "conditions"`, while the routed fork build needs a
# workerSelector the official 1.x distribution does not know. Pick the directory
# that matches the endpoint.
kestra_major="$(
  kestra_api "${KESTRA_URL%/}/api/v1/configs" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["version"].split(".")[0])'
)"
case "${kestra_major}" in
  1) FLOW_DIR="${FLOW_DIR_1X}" ;;
  *) FLOW_DIR="${FLOW_DIR_2X}" ;;
esac
echo "Kestra major version ${kestra_major}; registering ${FLOW_DIR#"${ROOT_DIR}/"}"

"${ROOT_DIR}/scripts/register-flows.sh" "${KESTRA_URL}" "${FLOW_DIR}"

run_sample_batch() {
  local fail_stage="$1"

  kestra_api -X POST \
    -F "business_date=${BUSINESS_DATE}" \
    -F "fail_stage=${fail_stage}" \
    "${KESTRA_URL%/}/api/v1/main/executions/playground.affiliate/sample_affiliate_partner_batch" >/dev/null
  echo "Started playground.affiliate.sample_affiliate_partner_batch fail_stage=${fail_stage}"
}

run_sample_batch none
run_sample_batch aggregate

# The failing run produces two mails: the errors-block error mail and the fail
# mail sent by playground.affiliate.system.notify_affiliate_execution_result.
EXPECTED_SUBJECTS=(
  "[SUCCESS] playground.affiliate.sample_affiliate_partner_batch"
  "[FAILED] playground.affiliate.sample_affiliate_partner_batch"
  "[ERROR] playground.affiliate.sample_affiliate_partner_batch task=simulate_aggregate_failure"
)

echo "Waiting up to ${NOTIFICATION_WAIT_SECONDS}s for ${#EXPECTED_SUBJECTS[@]} notification mails"
deadline=$((SECONDS + NOTIFICATION_WAIT_SECONDS))
while true; do
  received="$(curl --silent --show-error --fail "${MAILPIT_URL}/api/v1/messages" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["messages_count"])')"
  if [[ "${received}" -ge "${#EXPECTED_SUBJECTS[@]}" ]]; then
    break
  fi
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    echo "Only ${received}/${#EXPECTED_SUBJECTS[@]} notification mails arrived." >&2
    exit 1
  fi
  sleep 5
done

EXPECTED_SUBJECTS_JSON="$(printf '%s\n' "${EXPECTED_SUBJECTS[@]}" |
  python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.strip()]))')"

EXPECTED_SUBJECTS_JSON="${EXPECTED_SUBJECTS_JSON}" MAILPIT_URL="${MAILPIT_URL}" python3 - <<'PY'
import json
import os
import sys
import urllib.request

expected = json.loads(os.environ["EXPECTED_SUBJECTS_JSON"])
base = os.environ["MAILPIT_URL"].rstrip("/")
with urllib.request.urlopen(f"{base}/api/v1/messages?limit=200") as response:
    messages = json.load(response)["messages"]

subjects = [message["Subject"] for message in messages]
missing = [subject for subject in expected if subject not in subjects]
unexpected = [subject for subject in subjects if subject not in expected]

for subject in subjects:
    print(f"  received: {subject}")

if missing:
    print(f"Missing notification mails: {missing}", file=sys.stderr)
    sys.exit(1)
if unexpected:
    print(f"Unexpected notification mails: {unexpected}", file=sys.stderr)
    sys.exit(1)

error_id = next(
    message["ID"] for message in messages if message["Subject"].startswith("[ERROR]")
)
with urllib.request.urlopen(f"{base}/api/v1/message/{error_id}") as response:
    body = json.load(response).get("Text", "")

for fragment in ("batch_group=affiliate", '"taskId":"simulate_aggregate_failure"'):
    if fragment not in body:
        print(f"Error mail body is missing {fragment!r}: {body!r}", file=sys.stderr)
        sys.exit(1)
print("  error mail body names the failing task")
PY

echo "Live mail notification verification passed against ${KESTRA_URL}"
