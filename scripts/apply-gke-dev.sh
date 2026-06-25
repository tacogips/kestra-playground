#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="${TERRAFORM_DIR:-infra/terraform/gke-dev}"
OVERLAY_DIR="${OVERLAY_DIR:-k8s/overlays/dev}"
NAMESPACE="${NAMESPACE:-kestra-dev}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command jq
require_command gcloud
require_command kubectl
require_command kustomize
require_command tofu

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

outputs_json="${tmpdir}/terraform-outputs.json"
: >"$outputs_json"
chmod 600 "$outputs_json"
tofu -chdir="$TERRAFORM_DIR" output -json >"$outputs_json"

tf_output() {
  jq -er "$1" "$outputs_json"
}

cloud_sql_instance="$(tf_output '.cloud_sql_instance.value')"
gcp_service_account="$(tf_output '.gcp_service_account.value')"
project_id="$(tf_output '.project_id.value')"
kestra_image="$(tf_output '.kestra_image.value')"

secret_value() {
  jq -er ".kubernetes_secret_values.value.$1" "$outputs_json"
}

basic_auth_secret_id() {
  jq -er ".kestra_basic_auth_secret_ids.value.$1" "$outputs_json"
}

gcp_secret_value() {
  local secret_id="$1"
  gcloud secrets versions access latest --project="$project_id" --secret="$secret_id"
}

cp -R k8s "${tmpdir}/k8s"
work_overlay="${tmpdir}/${OVERLAY_DIR}"

(
  cd "$work_overlay"
  kustomize edit set image "kestra/kestra:latest=${kestra_image}"
)

cat >"${work_overlay}/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kestra-config
  namespace: kestra
data:
  CLOUD_SQL_INSTANCE: ${cloud_sql_instance}
EOF

cat >"${work_overlay}/service-account.yaml" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kestra
  namespace: kestra
  annotations:
    iam.gke.io/gcp-service-account: ${gcp_service_account}
EOF

cat >"${work_overlay}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kestra-secrets
  namespace: kestra
stringData:
  KESTRA_DB_URL: $(secret_value KESTRA_DB_URL)
  KESTRA_DB_USERNAME: $(secret_value KESTRA_DB_USERNAME)
  KESTRA_DB_PASSWORD: $(secret_value KESTRA_DB_PASSWORD)
  KESTRA_GCS_BUCKET: $(secret_value KESTRA_GCS_BUCKET)
  KESTRA_BASIC_AUTH_USERNAME: $(gcp_secret_value "$(basic_auth_secret_id username)")
  KESTRA_BASIC_AUTH_PASSWORD: $(gcp_secret_value "$(basic_auth_secret_id password)")
  KESTRA_SERVER_BASIC__AUTH_USERNAME: $(gcp_secret_value "$(basic_auth_secret_id username)")
  KESTRA_SERVER_BASIC__AUTH_PASSWORD: $(gcp_secret_value "$(basic_auth_secret_id password)")
  ENV_BATCH_DB_URL: $(secret_value ENV_BATCH_DB_URL)
  ENV_BATCH_DB_USERNAME: $(secret_value ENV_BATCH_DB_USERNAME)
  ENV_BATCH_DB_PASSWORD: $(secret_value ENV_BATCH_DB_PASSWORD)
EOF

rendered="${tmpdir}/rendered.yaml"
: >"$rendered"
chmod 600 "$rendered"
kustomize build "$work_overlay" >"$rendered"

kubectl apply -f "$rendered"
kubectl -n "$NAMESPACE" rollout status deployment/otel-collector --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-webserver --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-executor --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-scheduler --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-indexer --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-worker --timeout=15m
kubectl -n "$NAMESPACE" get ingress kestra-webserver
