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

kubectl -n "$NAMESPACE" get deployment,statefulset,pod,service,endpoints -o wide
kubectl -n "$NAMESPACE" get endpointslice -o wide
kubectl -n "$NAMESPACE" describe pod -l app.kubernetes.io/component=webserver
kubectl -n "$NAMESPACE" logs deployment/kestra-webserver --all-containers --tail=300 || true
kubectl -n "$NAMESPACE" logs deployment/kestra-worker-activator --all-containers --tail=300 || true
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 100
