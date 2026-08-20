#!/usr/bin/env bash
# Verify the mail notification flows against the local Docker stack.
#
# Registers kestra/flows-notification, runs one succeeding and one failing demo
# batch, both branches of the inline afterExecution demo, and both paths of the
# sample batch, then asserts that the Mailpit mock SMTP sink received the expected
# mails: one execution summary per execution plus the error mail that the sample
# batch sends from its errors block.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
FLOW_DIR="${ROOT_DIR}/kestra/flows-notification"
USERNAME="${KESTRA_BASIC_AUTH_USERNAME:-admin@example.com}"
PASSWORD="${KESTRA_BASIC_AUTH_PASSWORD:-KestraDev1234!}"
NOTIFICATION_WAIT_SECONDS="${NOTIFICATION_WAIT_SECONDS:-60}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in curl python3; do
  require_command "${command}"
done

kestra_api() {
  curl --silent --show-error --fail -u "${USERNAME}:${PASSWORD}" "$@"
}

echo "Checking that the Email plugin is loaded on ${KESTRA_URL}"
if ! kestra_api "${KESTRA_URL%/}/api/v1/plugins" | grep -q "io.kestra.plugin.email.MailExecution"; then
  echo "The Email plugin is not loaded." >&2
  echo "Run local/docker/fetch-plugins.sh and recreate the kestra-ec container." >&2
  exit 1
fi

echo "Checking that Mailpit answers on ${MAILPIT_URL}"
curl --silent --show-error --fail "${MAILPIT_URL%/}/api/v1/info" >/dev/null

echo "Clearing the Mailpit mailbox"
curl --silent --show-error --fail -X DELETE "${MAILPIT_URL%/}/api/v1/messages" >/dev/null

KESTRA_BASIC_AUTH_USERNAME="${USERNAME}" \
KESTRA_BASIC_AUTH_PASSWORD="${PASSWORD}" \
  "${ROOT_DIR}/scripts/register-flows.sh" "${KESTRA_URL}" "${FLOW_DIR}"

run_flow() {
  local namespace="$1"
  local flow_id="$2"
  shift 2

  local form_args=()
  local input
  for input in "$@"; do
    form_args+=(-F "${input}")
  done

  kestra_api -X POST "${form_args[@]+"${form_args[@]}"}" \
    "${KESTRA_URL%/}/api/v1/main/executions/${namespace}/${flow_id}" >/dev/null
  echo "Started ${namespace}.${flow_id} $*"
}

run_flow playground.notification demo_batch_success
run_flow playground.notification demo_batch_failure
run_flow playground.inline demo_inline_notification should_fail=false
run_flow playground.inline demo_inline_notification should_fail=true
run_flow playground.notification sample_sales_batch business_date=2026-06-25 fail_stage=none
run_flow playground.notification sample_sales_batch business_date=2026-06-25 fail_stage=transform

# The failing sample batch sends two mails: the error mail from its errors block
# and the fail mail that the independent notifier sends for the FAILED execution.
EXPECTED_SUBJECTS=(
  "[SUCCESS] playground.notification.demo_batch_success"
  "[FAILED] playground.notification.demo_batch_failure"
  "[SUCCESS] playground.inline.demo_inline_notification"
  "[FAILED] playground.inline.demo_inline_notification"
  "[SUCCESS] playground.notification.sample_sales_batch"
  "[FAILED] playground.notification.sample_sales_batch"
  "[ERROR] playground.notification.sample_sales_batch task=simulate_transform_failure"
)

echo "Waiting up to ${NOTIFICATION_WAIT_SECONDS}s for ${#EXPECTED_SUBJECTS[@]} notification mails"
deadline=$((SECONDS + NOTIFICATION_WAIT_SECONDS))
while true; do
  received="$(curl --silent --show-error --fail "${MAILPIT_URL%/}/api/v1/messages" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["messages_count"])')"
  if [[ "${received}" -ge "${#EXPECTED_SUBJECTS[@]}" ]]; then
    break
  fi
  if [[ "${SECONDS}" -ge "${deadline}" ]]; then
    echo "Only ${received}/${#EXPECTED_SUBJECTS[@]} notification mails arrived." >&2
    exit 1
  fi
  sleep 3
done

EXPECTED_SUBJECTS_JSON="$(printf '%s\n' "${EXPECTED_SUBJECTS[@]}" |
  python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.strip()]))')"

EXPECTED_SUBJECTS_JSON="${EXPECTED_SUBJECTS_JSON}" MAILPIT_URL="${MAILPIT_URL}" python3 - <<'PY'
import json
import os
import sys
import urllib.request

expected = json.loads(os.environ["EXPECTED_SUBJECTS_JSON"])
url = os.environ["MAILPIT_URL"].rstrip("/") + "/api/v1/messages?limit=200"
with urllib.request.urlopen(url) as response:
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
if len(subjects) != len(expected):
    print(f"Expected {len(expected)} mails, got {len(subjects)}", file=sys.stderr)
    sys.exit(1)

# The error mail must name the failing task and carry the flow inputs, so check
# its body rather than trusting the subject alone.
error_id = next(
    message["ID"] for message in messages if message["Subject"].startswith("[ERROR]")
)
base = os.environ["MAILPIT_URL"].rstrip("/")
with urllib.request.urlopen(f"{base}/api/v1/message/{error_id}") as response:
    body = json.load(response).get("Text", "")

for fragment in ('fail_stage=transform', '"taskId":"simulate_transform_failure"'):
    if fragment not in body:
        print(f"Error mail body is missing {fragment!r}: {body!r}", file=sys.stderr)
        sys.exit(1)
print("  error mail body names the failing task")
PY

echo "Mail notification verification passed. Inspect the mails at ${MAILPIT_URL}"
