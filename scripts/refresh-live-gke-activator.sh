#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${REGION:-asia-northeast1}"
NAMESPACE="${NAMESPACE:-kestra-dev}"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Missing required environment variable: PROJECT_ID or GCP_PROJECT_ID" >&2
  exit 1
fi

gcloud container clusters get-credentials kestra-dev \
  --region "$REGION" \
  --project "$PROJECT_ID"

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

kubectl -n "$NAMESPACE" get configmap kestra-worker-activator \
  -o jsonpath='{.data.activator\.sh}' >"${temporary_directory}/activator.sh"
kubectl -n "$NAMESPACE" get configmap kestra-worker-activator \
  -o jsonpath='{.data.nginx\.conf}' >"${temporary_directory}/nginx.conf"

sed -i \
  -e 's/"readyReplicas":1/"readyReplicas":[[:space:]]*1/g' \
  -e 's/"(availableReplicas|readyReplicas|replicas)":(\[1-9\]\[0-9\]\*)/"(availableReplicas|readyReplicas|replicas)":[[:space:]]*([1-9][0-9]*)/' \
  "${temporary_directory}/activator.sh"

grep -Fq '"readyReplicas":[[:space:]]*1' \
  "${temporary_directory}/activator.sh"
grep -Fq '"(availableReplicas|readyReplicas|replicas)":[[:space:]]*([1-9][0-9]*)' \
  "${temporary_directory}/activator.sh"

kubectl -n "$NAMESPACE" create configmap kestra-worker-activator \
  --from-file="activator.sh=${temporary_directory}/activator.sh" \
  --from-file="nginx.conf=${temporary_directory}/nginx.conf" \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -
kubectl -n "$NAMESPACE" rollout restart deployment/kestra-worker-activator
kubectl -n "$NAMESPACE" rollout status deployment/kestra-worker-activator --timeout=5m
