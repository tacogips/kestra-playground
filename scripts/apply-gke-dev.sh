#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="${TERRAFORM_DIR:-infra/terraform/gke-dev}"
OVERLAY_DIR="${OVERLAY_DIR:-k8s/overlays/dev}"
HELM_RELEASE="${HELM_RELEASE:-kestra}"
HELM_CHART="${HELM_CHART:-kestra/kestra}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-1.0.54}"
HELM_VALUES_DIR="${HELM_VALUES_DIR:-k8s/helm}"
if [[ -z "${GKE_WORKER_ENABLED+x}" && "${LIVE_GKE_EXTERNAL_GCE_WORKER_ENABLED:-false}" == "true" ]]; then
  GKE_WORKER_ENABLED=false
fi
GKE_WORKER_ENABLED="${GKE_WORKER_ENABLED:-true}"
LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED="${LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED:-false}"
NAMESPACE="${NAMESPACE:-kestra-dev}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command jq
require_command gcloud
require_command helm
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
kestra_image="${KESTRA_IMAGE:-$(tf_output '.kestra_image.value')}"
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
  name: kestra-runtime-config
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

image_repository="${kestra_image%:*}"
image_tag="${kestra_image##*:}"
if [[ -z "$image_repository" || -z "$image_tag" || "$image_repository" == "$image_tag" ]]; then
  echo "KESTRA image must be a tagged image reference for the Helm chart: ${kestra_image}" >&2
  exit 1
fi

helm_runtime_values="${tmpdir}/kestra-runtime-values.yaml"
cat >"$helm_runtime_values" <<EOF
image:
  repository: ${image_repository}
  tag: ${image_tag}
EOF

helm_values=(
  "${HELM_VALUES_DIR}/kestra-values.yaml"
)

if [[ "$GKE_WORKER_ENABLED" != "true" ]]; then
  helm_values+=("${HELM_VALUES_DIR}/kestra-controller-only-values.yaml")
fi

helm_args=()
for values_file in "${helm_values[@]}"; do
  helm_args+=(--values "$values_file")
done
helm_args+=(--values "$helm_runtime_values")

if ! helm status "$HELM_RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" delete configmap kestra-config --ignore-not-found
  kubectl -n "$NAMESPACE" delete service kestra --ignore-not-found
  kubectl -n "$NAMESPACE" delete deployment \
    kestra-webserver \
    kestra-executor \
    kestra-scheduler \
    kestra-indexer \
    kestra-worker \
    --ignore-not-found
  kubectl -n "$NAMESPACE" delete hpa kestra-worker --ignore-not-found
fi

helm repo add kestra https://helm.kestra.io/ >/dev/null 2>&1 || true
helm repo update kestra
helm upgrade --install "$HELM_RELEASE" "$HELM_CHART" \
  --version "$HELM_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  "${helm_args[@]}"

if [[ "$GKE_WORKER_ENABLED" != "true" ]]; then
  kubectl -n "$NAMESPACE" delete deployment kestra-worker --ignore-not-found
  kubectl -n "$NAMESPACE" delete hpa kestra-worker --ignore-not-found
fi

render_routed_k8s_worker() {
  local group_id="$1"
  local cpu_request="$2"
  local memory_request="$3"
  local cpu_limit="$4"
  local memory_limit="$5"
  local threads="$6"
  local selector_key="$7"
  local selector_value="$8"
  local node_name="$9"

  local placement=""
  if [[ -n "$node_name" ]]; then
    placement="      nodeName: ${node_name}
"
  elif [[ -n "$selector_key" && -n "$selector_value" ]]; then
    placement="      nodeSelector:
        ${selector_key}: ${selector_value}
      tolerations:
        - key: ${selector_key}
          operator: Equal
          value: ${selector_value}
          effect: NoSchedule
"
  fi

  cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kestra-worker-routing-${group_id}
  namespace: ${NAMESPACE}
data:
  worker-routing.yaml: |
    kestra:
      worker:
        controllers:
          type: STATIC
          static:
            endpoints:
              - host: kestra-controller-grpc
                port: 50051
        routing:
          workerGroupId: ${group_id}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kestra-gke-worker-${group_id#gke-}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: kestra-gke-routed-worker
    app.kubernetes.io/component: worker
    app.kubernetes.io/instance: kestra
    kestra.worker/group: ${group_id}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kestra-gke-routed-worker
      app.kubernetes.io/component: worker
      app.kubernetes.io/instance: kestra
      kestra.worker/group: ${group_id}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kestra-gke-routed-worker
        app.kubernetes.io/component: worker
        app.kubernetes.io/instance: kestra
        kestra.worker/group: ${group_id}
    spec:
      serviceAccountName: kestra
      terminationGracePeriodSeconds: 360
${placement}      containers:
        - name: kestra-worker
          image: ${kestra_image}
          imagePullPolicy: Always
          command:
            - sh
            - -c
            - exec /app/kestra server worker --thread=${threads}
          envFrom:
            - secretRef:
                name: kestra-secrets
          env:
            - name: MICRONAUT_CONFIG_FILES
              value: /app/confs/_default.yml,/app/confs/application.yaml,/app/confs/worker-routing.yaml
            - name: _JAVA_OPTIONS
              value: ""
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://otel-collector:4317
            - name: OTEL_SERVICE_NAME
              value: kestra-gke-worker-${group_id#gke-}
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: service.namespace=kestra-playground,deployment.environment=dev,k8s.namespace.name=\$(POD_NAMESPACE),k8s.pod.name=\$(POD_NAME),k8s.node.name=\$(K8S_NODE_NAME),kestra.component=worker,kestra.worker.group=${group_id}
          ports:
            - name: management
              containerPort: 8081
              protocol: TCP
          resources:
            requests:
              cpu: ${cpu_request}
              memory: ${memory_request}
            limits:
              cpu: ${cpu_limit}
              memory: ${memory_limit}
          volumeMounts:
            - name: kestra-config
              mountPath: /app/confs/_default.yml
              subPath: _default.yml
            - name: kestra-runtime-config-application-yaml
              mountPath: /app/confs/application.yaml
              subPath: application.yaml
            - name: kestra-worker-routing
              mountPath: /app/confs/worker-routing.yaml
              subPath: worker-routing.yaml
            - name: tmp
              mountPath: /tmp/kestra-wd
        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1
          args:
            - --structured-logs
            - --port=5432
            - \$(CLOUD_SQL_INSTANCE)
          env:
            - name: CLOUD_SQL_INSTANCE
              valueFrom:
                configMapKeyRef:
                  name: kestra-runtime-config
                  key: CLOUD_SQL_INSTANCE
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
      volumes:
        - name: kestra-config
          configMap:
            name: kestra-config
            items:
              - key: _default.yml
                path: _default.yml
        - name: kestra-runtime-config-application-yaml
          configMap:
            name: kestra-runtime-config
            items:
              - key: application.yaml
                path: application.yaml
        - name: kestra-worker-routing
          configMap:
            name: kestra-worker-routing-${group_id}
            items:
              - key: worker-routing.yaml
                path: worker-routing.yaml
        - name: tmp
          emptyDir: {}
EOF
}

if [[ "$LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED" == "true" ]]; then
  routed_k8s_workers="${tmpdir}/routed-k8s-workers.yaml"
  : >"$routed_k8s_workers"
  render_routed_k8s_worker \
    gke-small \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_CPU_REQUEST:-250m}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_MEMORY_REQUEST:-768Mi}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_CPU_LIMIT:-1}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_MEMORY_LIMIT:-1536Mi}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_THREADS:-1}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_KEY:-}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_VALUE:-}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_NAME:-}" \
    >>"$routed_k8s_workers"
  render_routed_k8s_worker \
    gke-large \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_CPU_REQUEST:-2}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_MEMORY_REQUEST:-4Gi}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_CPU_LIMIT:-4}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_MEMORY_LIMIT:-8Gi}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_THREADS:-2}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_KEY:-}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_VALUE:-}" \
    "${LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_NAME:-}" \
    >>"$routed_k8s_workers"
  kubectl apply -f "$routed_k8s_workers"
else
  kubectl -n "$NAMESPACE" delete deployment \
    kestra-gke-worker-small \
    kestra-gke-worker-large \
    --ignore-not-found
  kubectl -n "$NAMESPACE" delete configmap \
    kestra-worker-routing-gke-small \
    kestra-worker-routing-gke-large \
    --ignore-not-found
fi

kubectl -n "$NAMESPACE" rollout status deployment/otel-collector --timeout=10m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-webserver --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-executor --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-scheduler --timeout=15m
kubectl -n "$NAMESPACE" rollout status deployment/kestra-indexer --timeout=15m
if [[ "$GKE_WORKER_ENABLED" == "true" ]]; then
  kubectl -n "$NAMESPACE" rollout status deployment/kestra-worker --timeout=15m
fi
if [[ "$LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED" == "true" ]]; then
  kubectl -n "$NAMESPACE" rollout status deployment/kestra-gke-worker-small --timeout=15m
  kubectl -n "$NAMESPACE" rollout status deployment/kestra-gke-worker-large --timeout=15m
fi
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
