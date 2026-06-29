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
require_command yq

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
kestra_https_url="$(tf_output '.kestra_https_url.value // empty')"
ingress_static_ip_name="$(tf_output '.ingress_static_ip_name.value // empty')"
controller_grpc_ip_address="$(tf_output '.controller_grpc_ip_address.value')"
cloud_armor_security_policy_name="$(tf_output '.cloud_armor_security_policy_name.value // empty')"
kestra_hostname="${kestra_https_url#https://}"

secret_id() {
  jq -er ".kubernetes_secret_ids.value.$1" "$outputs_json"
}

gcp_secret_value() {
  local secret_name="$1"
  gcloud secrets versions access latest --project="$project_id" --secret="$secret_name"
}

optional_gcp_secret_value() {
  local secret_name="$1"
  gcloud secrets versions access latest --project="$project_id" --secret="$secret_name" 2>/dev/null || true
}

runtime_secret_value() {
  gcp_secret_value "$(secret_id "$1")"
}

federated_gce_a_url="${FEDERATED_GCE_A_URL:-}"
if [[ -z "$federated_gce_a_url" && -n "${LIVE_DOMAIN_NAME:-}" ]]; then
  federated_gce_a_url="https://${LIVE_GCE_A_SUBDOMAIN:-${LIVE_GCE_SINGLE_SUBDOMAIN:-gce-compose}}.${LIVE_DOMAIN_NAME}"
fi
federated_gce_a_username="${FEDERATED_GCE_A_USERNAME:-$(optional_gcp_secret_value kestra-dev-kestra-basic-auth-username)}"
federated_gce_a_password="${FEDERATED_GCE_A_PASSWORD:-$(optional_gcp_secret_value kestra-dev-kestra-basic-auth-password)}"

federated_gce_b_url="${FEDERATED_GCE_B_URL:-}"
if [[ -z "$federated_gce_b_url" && -n "${LIVE_DOMAIN_NAME:-}" ]]; then
  federated_gce_b_url="https://${LIVE_GCE_B_SUBDOMAIN:-${LIVE_GCE_CLUSTER_SUBDOMAIN:-gce-container}}.${LIVE_DOMAIN_NAME}"
fi
federated_gce_b_username="${FEDERATED_GCE_B_USERNAME:-$(optional_gcp_secret_value kestra-cluster-dev-kestra-basic-auth-username)}"
federated_gce_b_password="${FEDERATED_GCE_B_PASSWORD:-$(optional_gcp_secret_value kestra-cluster-dev-kestra-basic-auth-password)}"

cp -R k8s "${tmpdir}/k8s"
work_overlay="${tmpdir}/${OVERLAY_DIR}"

(
  cd "$work_overlay"
  kustomize edit set image "kestra/kestra:latest=${kestra_image}"
)

if [[ -n "${kestra_hostname}" ]]; then
  KESTRA_HOSTNAME="$kestra_hostname" INGRESS_STATIC_IP_NAME="$ingress_static_ip_name" \
    yq -i '.spec.rules[0].host = strenv(KESTRA_HOSTNAME) | .metadata.annotations."kubernetes.io/ingress.global-static-ip-name" = strenv(INGRESS_STATIC_IP_NAME)' \
    "${work_overlay}/ingress.yaml"
  KESTRA_HOSTNAME="$kestra_hostname" \
    yq -i '.spec.domains = [strenv(KESTRA_HOSTNAME)]' \
    "${work_overlay}/managed-certificate.yaml"
fi

if [[ -n "${cloud_armor_security_policy_name}" ]]; then
  CLOUD_ARMOR_SECURITY_POLICY_NAME="$cloud_armor_security_policy_name" \
    yq -i '.spec.securityPolicy.name = strenv(CLOUD_ARMOR_SECURITY_POLICY_NAME)' \
    "${work_overlay}/backendconfig.yaml"
fi

CONTROLLER_GRPC_IP_ADDRESS="$controller_grpc_ip_address" \
  yq -i '.spec.loadBalancerIP = strenv(CONTROLLER_GRPC_IP_ADDRESS)' \
  "${work_overlay}/controller-grpc-service.yaml"

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
  KESTRA_DB_URL: $(runtime_secret_value KESTRA_DB_URL)
  KESTRA_DB_USERNAME: $(runtime_secret_value KESTRA_DB_USERNAME)
  KESTRA_DB_PASSWORD: $(runtime_secret_value KESTRA_DB_PASSWORD)
  KESTRA_GCS_BUCKET: $(runtime_secret_value KESTRA_GCS_BUCKET)
  KESTRA_BASIC_AUTH_USERNAME: $(runtime_secret_value KESTRA_BASIC_AUTH_USERNAME)
  KESTRA_BASIC_AUTH_PASSWORD: $(runtime_secret_value KESTRA_BASIC_AUTH_PASSWORD)
  KESTRA_SERVER_BASIC__AUTH_USERNAME: $(runtime_secret_value KESTRA_SERVER_BASIC__AUTH_USERNAME)
  KESTRA_SERVER_BASIC__AUTH_PASSWORD: $(runtime_secret_value KESTRA_SERVER_BASIC__AUTH_PASSWORD)
  ENV_BATCH_DB_URL: $(runtime_secret_value ENV_BATCH_DB_URL)
  ENV_BATCH_DB_USERNAME: $(runtime_secret_value ENV_BATCH_DB_USERNAME)
  ENV_BATCH_DB_PASSWORD: $(runtime_secret_value ENV_BATCH_DB_PASSWORD)
  ENV_FEDERATED_GCE_A_URL: "${federated_gce_a_url}"
  ENV_FEDERATED_GCE_A_USERNAME: "${federated_gce_a_username}"
  ENV_FEDERATED_GCE_A_PASSWORD: "${federated_gce_a_password}"
  ENV_FEDERATED_GCE_B_URL: "${federated_gce_b_url}"
  ENV_FEDERATED_GCE_B_USERNAME: "${federated_gce_b_username}"
  ENV_FEDERATED_GCE_B_PASSWORD: "${federated_gce_b_password}"
EOF

rendered="${tmpdir}/rendered.yaml"
: >"$rendered"
chmod 600 "$rendered"
kustomize build "$work_overlay" >"$rendered"

kubectl apply -f "$rendered"
kubectl -n "$NAMESPACE" delete deployment kestra-worker --ignore-not-found
kubectl -n "$NAMESPACE" delete hpa kestra-worker --ignore-not-found
kubectl -n "$NAMESPACE" scale deployment/kestra-webserver --replicas=1
kubectl -n "$NAMESPACE" rollout status deployment/otel-collector --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-webserver --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-executor --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-scheduler --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-indexer --timeout=15m
kubectl -n "$NAMESPACE" get ingress kestra-webserver
kubectl -n "$NAMESPACE" get service kestra-controller-grpc

for _ in {1..60}; do
  assigned_grpc_ip="$(
    kubectl -n "$NAMESPACE" get service kestra-controller-grpc \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
  )"
  if [[ "$assigned_grpc_ip" == "$controller_grpc_ip_address" ]]; then
    exit 0
  fi
  sleep 5
done

echo "kestra-controller-grpc did not receive reserved IP ${controller_grpc_ip_address}" >&2
exit 1
