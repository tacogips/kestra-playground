#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
LIVE_GKE_SUBDOMAIN="${LIVE_GKE_SUBDOMAIN:-k8s}"
LIVE_DOMAIN_NAME="${LIVE_DOMAIN_NAME:-}"
POLL_SECONDS="${POLL_SECONDS:-5}"
MARKER="${MARKER:-scale-zero-$(date -u +%Y%m%dT%H%M%SZ)}"
MANAGED_DEPLOYMENTS=(
  kestra-webserver
  kestra-executor
  kestra-scheduler
  kestra-indexer
  kestra-gke-worker-small
  kestra-gke-worker-large
)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

for command in curl gcloud jq kubectl; do
  require_command "$command"
done

if [[ -z "$PROJECT_ID" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

if [[ -z "$LIVE_DOMAIN_NAME" ]]; then
  echo "Missing required environment variable: LIVE_DOMAIN_NAME" >&2
  exit 1
fi

if ! [[ "$MARKER" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "MARKER may contain only letters, digits, dot, underscore, colon, and hyphen." >&2
  exit 1
fi

gcloud container clusters get-credentials kestra-dev \
  --region "$REGION" \
  --project "$PROJECT_ID"

secret_value() {
  gcloud secrets versions access latest --project="$PROJECT_ID" --secret="$1"
}

username="$(secret_value kestra-dev-gke-kestra-basic-auth-username)"
password="$(secret_value kestra-dev-gke-kestra-basic-auth-password)"
url="https://${LIVE_GKE_SUBDOMAIN}.${LIVE_DOMAIN_NAME}"
idle_seconds="$(
  kubectl -n "$NAMESPACE" get deployment kestra-worker-activator -o json \
    | jq -er '.spec.template.spec.containers[] | select(.name == "scaler") | .env[] | select(.name == "IDLE_SECONDS") | .value | tonumber'
)"

wait_for_zero() {
  local timeout_seconds=$((idle_seconds + 900))
  local deadline=$((SECONDS + timeout_seconds))
  local deployment=""
  local all_zero=""
  local postgres_replicas=""

  while ((SECONDS < deadline)); do
    all_zero=true
    postgres_replicas="$(
      kubectl -n "$NAMESPACE" get statefulset kestra-postgres -o jsonpath='{.spec.replicas}'
    )"
    if [[ "$postgres_replicas" != "0" ]]; then
      all_zero=false
    fi
    for deployment in "${MANAGED_DEPLOYMENTS[@]}"; do
      if [[ "$(kubectl -n "$NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}')" != "0" ]]; then
        all_zero=false
        break
      fi
    done
    if [[ "$all_zero" == true ]]; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done

  echo "The managed GKE stack did not reach zero replicas within ${timeout_seconds}s." >&2
  kubectl -n "$NAMESPACE" get statefulset kestra-postgres >&2
  kubectl -n "$NAMESPACE" get deployment "${MANAGED_DEPLOYMENTS[@]}" >&2
  return 1
}

wait_for_warm() {
  local deadline=$((SECONDS + 1200))
  local deployment=""
  local ready_replicas=""

  kubectl -n "$NAMESPACE" rollout status statefulset/kestra-postgres --timeout=10m
  for deployment in "${MANAGED_DEPLOYMENTS[@]}"; do
    while ((SECONDS < deadline)); do
      ready_replicas="$(
        kubectl -n "$NAMESPACE" get deployment "$deployment" \
          -o jsonpath='{.status.readyReplicas}'
      )"
      if [[ "$ready_replicas" == "1" ]]; then
        break
      fi
      sleep "$POLL_SECONDS"
    done
    if [[ "$ready_replicas" != "1" ]]; then
      echo "Deployment ${deployment} did not report one ready replica." >&2
      diagnose_http_failure
      return 1
    fi
  done
}

diagnose_http_failure() {
  echo "Collecting GKE HTTP wake diagnostics." >&2
  kubectl -n "$NAMESPACE" get deployment,statefulset,pod,service,endpoints -o wide >&2 || true
  kubectl -n "$NAMESPACE" get endpointslice -o wide >&2 || true
  kubectl -n "$NAMESPACE" describe pod -l app.kubernetes.io/component=webserver >&2 || true
  kubectl -n "$NAMESPACE" logs deployment/kestra-webserver --all-containers --tail=300 >&2 || true
  kubectl -n "$NAMESPACE" logs deployment/kestra-worker-activator --all-containers --tail=300 >&2 || true
  kubectl -n "$NAMESPACE" exec deployment/kestra-worker-activator -c nginx -- \
    wget --server-response --output-document=/dev/null http://kestra-webserver/ >&2 || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 100 >&2 || true
}

trigger_public_wake() {
  local status=""
  status="$(
    curl --silent --show-error \
      --user "${username}:${password}" \
      --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 30 \
      "$url/" || true
  )"
  case "$status" in
    2?? | 3?? | 401 | 502 | 503 | 504)
      echo "Public wake request returned HTTP ${status}."
      ;;
    *)
      echo "Unexpected public wake response: HTTP ${status:-none}" >&2
      return 1
      ;;
  esac
}

wait_for_http() {
  local deadline=$((SECONDS + 1200))
  while ((SECONDS < deadline)); do
    if curl --fail --silent --show-error \
      --user "${username}:${password}" \
      --max-time 30 \
      "$url/" >/dev/null; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  echo "Kestra did not become available through the public activator." >&2
  diagnose_http_failure
  return 1
}

write_marker() {
  kubectl -n "$NAMESPACE" exec statefulset/kestra-postgres -- \
    psql --set ON_ERROR_STOP=1 --username=kestra --dbname=ecommerce_ops \
      --command 'CREATE TABLE IF NOT EXISTS scale_to_zero_verification (marker text PRIMARY KEY, created_at timestamptz NOT NULL DEFAULT now())' \
      --command "INSERT INTO scale_to_zero_verification (marker) VALUES ('${MARKER}') ON CONFLICT (marker) DO NOTHING" \
      >/dev/null
}

assert_marker() {
  local count=""
  count="$(
    kubectl -n "$NAMESPACE" exec statefulset/kestra-postgres -- \
      psql --tuples-only --no-align --username=kestra --dbname=ecommerce_ops \
        --command "SELECT count(*) FROM scale_to_zero_verification WHERE marker = '${MARKER}'"
  )"
  if [[ "$count" != "1" ]]; then
    echo "Persistent marker was not found after the second wake." >&2
    return 1
  fi
}

echo "Waiting for the initial idle baseline."
wait_for_zero
pvc_uid_before="$(kubectl -n "$NAMESPACE" get pvc data-kestra-postgres-0 -o jsonpath='{.metadata.uid}')"

# Load-balancer health probes must not wake the parked stack.
curl --fail --silent --show-error --max-time 30 "$url/health" >/dev/null
sleep $((POLL_SECONDS * 2))
if [[ "$(kubectl -n "$NAMESPACE" get statefulset kestra-postgres -o jsonpath='{.spec.replicas}')" != "0" ]]; then
  echo "The public health endpoint incorrectly woke PostgreSQL." >&2
  exit 1
fi

trigger_public_wake
wait_for_warm
wait_for_http
write_marker

echo "Waiting for ordered idle scale-down."
wait_for_zero
pvc_uid_after="$(kubectl -n "$NAMESPACE" get pvc data-kestra-postgres-0 -o jsonpath='{.metadata.uid}')"
if [[ "$pvc_uid_before" != "$pvc_uid_after" ]]; then
  echo "PostgreSQL PVC identity changed across scale-to-zero." >&2
  exit 1
fi

trigger_public_wake
wait_for_warm
wait_for_http
assert_marker

echo "Verified public wake, ordered full-stack scale-to-zero, retained PVC identity, and persistent data."
echo "marker=${MARKER}"
echo "pvc_uid=${pvc_uid_after}"
