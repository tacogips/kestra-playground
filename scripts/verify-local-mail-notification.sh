#!/usr/bin/env bash
# Verify the mail notification flows of one batch-group category against the
# local Docker stack.
#
#   scripts/verify-local-mail-notification.sh [ec|affiliate]
#
# ec         Kestra 2 fork build on :8080 with kestra/flows-notification. Runs the
#            demo batches, both branches of the inline afterExecution demo, and
#            both paths of the sample workflow.
# affiliate  Official kestra/kestra 1.x on :8082 with the affiliate flows. Runs
#            the sample affiliate batch on the success and failure paths.
#
# Both assert that the Mailpit mock SMTP sink received exactly the expected
# mails, including the error mail that the errors block sends, and that the error
# mail body names the failing task.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATEGORY="${1:-${MAIL_NOTIFICATION_CATEGORY:-ec}}"
MAILPIT_URL="${MAILPIT_URL:-http://localhost:8025}"
USERNAME="${KESTRA_BASIC_AUTH_USERNAME:-admin@example.com}"
PASSWORD="${KESTRA_BASIC_AUTH_PASSWORD:-KestraDev1234!}"
NOTIFICATION_WAIT_SECONDS="${NOTIFICATION_WAIT_SECONDS:-60}"

case "${CATEGORY}" in
  ec)
    KESTRA_URL="${KESTRA_URL:-http://localhost:8080}"
    FLOW_DIR="${ROOT_DIR}/kestra/flows-notification"
    RUNS=(
      "playground.notification demo_batch_success"
      "playground.notification demo_batch_failure"
      "playground.inline demo_inline_notification should_fail=false"
      "playground.inline demo_inline_notification should_fail=true"
      "playground.notification sample_sales_batch business_date=2026-06-25 fail_stage=none"
      "playground.notification sample_sales_batch business_date=2026-06-25 fail_stage=transform"
    )
    # The failing sample batch sends two mails: the error mail from its errors
    # block and the fail mail that the independent notifier sends for the FAILED
    # execution.
    EXPECTED_SUBJECTS=(
      "[SUCCESS] playground.notification.demo_batch_success"
      "[FAILED] playground.notification.demo_batch_failure"
      "[SUCCESS] playground.inline.demo_inline_notification"
      "[FAILED] playground.inline.demo_inline_notification"
      "[SUCCESS] playground.notification.sample_sales_batch"
      "[FAILED] playground.notification.sample_sales_batch"
      "[ERROR] playground.notification.sample_sales_batch task=simulate_transform_failure"
    )
    ERROR_MAIL_FRAGMENTS=(
      "fail_stage=transform"
      '"taskId":"simulate_transform_failure"'
    )
    ;;
  affiliate)
    KESTRA_URL="${KESTRA_URL:-http://localhost:8082}"
    FLOW_DIR="${ROOT_DIR}/batch-groups/affiliate/flows"
    RUNS=(
      "playground.affiliate sample_affiliate_partner_batch business_date=2026-06-25 fail_stage=none"
      "playground.affiliate sample_affiliate_partner_batch business_date=2026-06-25 fail_stage=aggregate"
    )
    EXPECTED_SUBJECTS=(
      "[SUCCESS] playground.affiliate.sample_affiliate_partner_batch"
      "[FAILED] playground.affiliate.sample_affiliate_partner_batch"
      "[ERROR] playground.affiliate.sample_affiliate_partner_batch task=simulate_aggregate_failure"
    )
    ERROR_MAIL_FRAGMENTS=(
      "batch_group=affiliate"
      '"taskId":"simulate_aggregate_failure"'
    )
    ;;
  *)
    echo "Unknown category: ${CATEGORY}" >&2
    echo "Use one of: ec, affiliate" >&2
    exit 1
    ;;
esac

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
  echo "Run local/docker/fetch-plugins.sh and recreate the Kestra container." >&2
  exit 1
fi

echo "Checking that Mailpit answers on ${MAILPIT_URL}"
curl --silent --show-error --fail "${MAILPIT_URL%/}/api/v1/info" >/dev/null

echo "Clearing the Mailpit mailbox"
curl --silent --show-error --fail -X DELETE "${MAILPIT_URL%/}/api/v1/messages" >/dev/null

KESTRA_BASIC_AUTH_USERNAME="${USERNAME}" \
KESTRA_BASIC_AUTH_PASSWORD="${PASSWORD}" \
  "${ROOT_DIR}/scripts/register-flows.sh" "${KESTRA_URL}" "${FLOW_DIR}"

for run in "${RUNS[@]}"; do
  # shellcheck disable=SC2206 # the run entries are space-separated on purpose
  parts=(${run})
  namespace="${parts[0]}"
  flow_id="${parts[1]}"
  form_args=()
  for input in "${parts[@]:2}"; do
    form_args+=(-F "${input}")
  done

  kestra_api -X POST "${form_args[@]+"${form_args[@]}"}" \
    "${KESTRA_URL%/}/api/v1/main/executions/${namespace}/${flow_id}" >/dev/null
  echo "Started ${namespace}.${flow_id} ${parts[*]:2}"
done

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
ERROR_MAIL_FRAGMENTS_JSON="$(printf '%s\n' "${ERROR_MAIL_FRAGMENTS[@]}" |
  python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.strip()]))')"

EXPECTED_SUBJECTS_JSON="${EXPECTED_SUBJECTS_JSON}" \
ERROR_MAIL_FRAGMENTS_JSON="${ERROR_MAIL_FRAGMENTS_JSON}" \
MAILPIT_URL="${MAILPIT_URL}" python3 - <<'PY'
import json
import os
import sys
import urllib.request

expected = json.loads(os.environ["EXPECTED_SUBJECTS_JSON"])
fragments = json.loads(os.environ["ERROR_MAIL_FRAGMENTS_JSON"])
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
if len(subjects) != len(expected):
    print(f"Expected {len(expected)} mails, got {len(subjects)}", file=sys.stderr)
    sys.exit(1)

# The error mail must name the failing task and carry the flow inputs, so check
# its body rather than trusting the subject alone.
error_id = next(
    message["ID"] for message in messages if message["Subject"].startswith("[ERROR]")
)
with urllib.request.urlopen(f"{base}/api/v1/message/{error_id}") as response:
    body = json.load(response).get("Text", "")

for fragment in fragments:
    if fragment not in body:
        print(f"Error mail body is missing {fragment!r}: {body!r}", file=sys.stderr)
        sys.exit(1)
print("  error mail body names the failing task")
PY

echo "Mail notification verification passed for ${CATEGORY}. Inspect the mails at ${MAILPIT_URL}"
