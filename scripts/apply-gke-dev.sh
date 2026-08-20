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
LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED="${LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED:-false}"
LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS="${LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS:-1800}"
LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS="${LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS:-10}"
LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED="${LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED:-false}"
LIVE_GKE_DATABASE_AUTOSCALE_ENABLED="${LIVE_GKE_DATABASE_AUTOSCALE_ENABLED:-${LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED}}"

if [[ "$LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED" == "true" && "$LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED" != "true" ]]; then
  echo "LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true requires LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true" >&2
  exit 1
fi

if [[ "$LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED" == "true" ]]; then
  if [[ "$LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED" != "true" || "$LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED" != "true" ]]; then
    echo "LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true requires LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true and LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true" >&2
    exit 1
  fi
fi
if [[ "$LIVE_GKE_DATABASE_AUTOSCALE_ENABLED" == "true" && "$LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED" != "true" ]]; then
  echo "LIVE_GKE_DATABASE_AUTOSCALE_ENABLED=true requires LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true" >&2
  exit 1
fi
GKE_MIN_COST_ENABLED="${GKE_MIN_COST_ENABLED:-false}"
NAMESPACE="${NAMESPACE:-kestra-dev}"
KESTRA_ALLOW_LINEAGE_SWITCH="${KESTRA_ALLOW_LINEAGE_SWITCH:-false}"

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

# shellcheck source=scripts/lib/gke-auth.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gke-auth.sh"
ensure_gke_kubectl_auth

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

outputs_json="${tmpdir}/terraform-outputs.json"
: >"$outputs_json"
chmod 600 "$outputs_json"
tofu -chdir="$TERRAFORM_DIR" output -json >"$outputs_json"

tf_output() {
  jq -er "$1" "$outputs_json"
}

postgres_internal_ip="$(tf_output '.postgres_internal_ip.value')"
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
# Notification mail settings for the mail notification flows. They point at the
# in-cluster Mailpit mock SMTP sink by default, so no mail leaves the cluster.
notify_smtp_host="${NOTIFY_SMTP_HOST:-mailpit}"
notify_smtp_port="${NOTIFY_SMTP_PORT:-1025}"
notify_mail_from="${NOTIFY_MAIL_FROM:-kestra@playground.local}"
notify_mail_to="${NOTIFY_MAIL_TO:-ops@playground.local}"
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
  CLOUD_ARMOR_SECURITY_POLICY_NAME="$cloud_armor_security_policy_name" \
    yq -i '.spec.securityPolicy.name = strenv(CLOUD_ARMOR_SECURITY_POLICY_NAME)' \
    "${work_overlay}/activator-backendconfig.yaml"
else
  yq -i 'del(.spec.securityPolicy)' "${work_overlay}/activator-backendconfig.yaml"
fi

POSTGRES_INTERNAL_IP="$postgres_internal_ip" \
  yq -i '.spec.loadBalancerIP = strenv(POSTGRES_INTERNAL_IP)' \
  "${work_overlay}/postgres-internal-service.yaml"

if [[ "$LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED" == "true" ]]; then
  yq -i '.spec.rules[0].http.paths[0].backend.service.name = "kestra-worker-activator" | .spec.rules[0].http.paths[0].backend.service.port.number = 80' \
    "${work_overlay}/ingress.yaml"
fi

CONTROLLER_GRPC_IP_ADDRESS="$controller_grpc_ip_address" \
  yq -i '.spec.loadBalancerIP = strenv(CONTROLLER_GRPC_IP_ADDRESS)' \
  "${work_overlay}/controller-grpc-service.yaml"

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
  KESTRA_DB_URL: jdbc:postgresql://kestra-postgres:5432/kestra
  KESTRA_DB_USERNAME: $(runtime_secret_value KESTRA_DB_USERNAME)
  KESTRA_DB_PASSWORD: $(runtime_secret_value KESTRA_DB_PASSWORD)
  KESTRA_GCS_BUCKET: $(runtime_secret_value KESTRA_GCS_BUCKET)
  KESTRA_BASIC_AUTH_USERNAME: $(runtime_secret_value KESTRA_BASIC_AUTH_USERNAME)
  KESTRA_BASIC_AUTH_PASSWORD: $(runtime_secret_value KESTRA_BASIC_AUTH_PASSWORD)
  KESTRA_SERVER_BASIC__AUTH_USERNAME: $(runtime_secret_value KESTRA_SERVER_BASIC__AUTH_USERNAME)
  KESTRA_SERVER_BASIC__AUTH_PASSWORD: $(runtime_secret_value KESTRA_SERVER_BASIC__AUTH_PASSWORD)
  ENV_BATCH_DB_URL: jdbc:postgresql://kestra-postgres:5432/ecommerce_ops
  ENV_BATCH_DB_USERNAME: $(runtime_secret_value ENV_BATCH_DB_USERNAME)
  ENV_BATCH_DB_PASSWORD: $(runtime_secret_value ENV_BATCH_DB_PASSWORD)
  ENV_RUNTIME_IMAGE: "${kestra_image}"
  ENV_FEDERATED_GCE_A_URL: "${federated_gce_a_url}"
  ENV_FEDERATED_GCE_A_USERNAME: "${federated_gce_a_username}"
  ENV_FEDERATED_GCE_A_PASSWORD: "${federated_gce_a_password}"
  ENV_FEDERATED_GCE_B_URL: "${federated_gce_b_url}"
  ENV_FEDERATED_GCE_B_USERNAME: "${federated_gce_b_username}"
  ENV_FEDERATED_GCE_B_PASSWORD: "${federated_gce_b_password}"
  ENV_NOTIFY_SMTP_HOST: "${notify_smtp_host}"
  ENV_NOTIFY_SMTP_PORT: "${notify_smtp_port}"
  ENV_NOTIFY_MAIL_FROM: "${notify_mail_from}"
  ENV_NOTIFY_MAIL_TO: "${notify_mail_to}"
EOF

rendered="${tmpdir}/rendered.yaml"
: >"$rendered"
chmod 600 "$rendered"
kustomize build "$work_overlay" >"$rendered"

kubectl apply -f "$rendered"
if ! kubectl -n "$NAMESPACE" rollout status statefulset/kestra-postgres --timeout=10m; then
  echo "PostgreSQL StatefulSet did not become ready; collecting diagnostics." >&2
  kubectl -n "$NAMESPACE" get statefulset kestra-postgres -o wide >&2 || true
  kubectl -n "$NAMESPACE" get pods,pvc -l app.kubernetes.io/name=kestra-postgres -o wide >&2 || true
  kubectl -n "$NAMESPACE" describe pod -l app.kubernetes.io/name=kestra-postgres >&2 || true
  kubectl -n "$NAMESPACE" logs statefulset/kestra-postgres --all-containers --tail=200 >&2 || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 100 >&2 || true
  exit 1
fi

image_repository="${kestra_image%:*}"
image_tag="${kestra_image##*:}"
if [[ -z "$image_repository" || -z "$image_tag" || "$image_repository" == "$image_tag" ]]; then
  echo "KESTRA image must be a tagged image reference for the Helm chart: ${kestra_image}" >&2
  exit 1
fi

# Kestra 1.x and Kestra 2 keep their schema in one database but migrate it
# differently, so pointing this environment at the other lineage leaves every pod
# crash-looping: the 1.x image reports "Found non-empty schema(s) \"public\" but no
# schema history table" against a database Kestra 2 migrated, and the 2.x image
# reports "type \"queue_type\" does not exist" against a 1.x one. The repo builds
# both - the runtime image from the official 1.x base and the routed image from
# the 2.x fork - so refuse to swap lineages unless the caller says so.
current_image="$(
  kubectl -n "$NAMESPACE" get deployment kestra-webserver \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
)"
if [[ -n "$current_image" && "$KESTRA_ALLOW_LINEAGE_SWITCH" != "true" ]]; then
  lineage_of() {
    case "$1" in
      *kestra-oss-worker-routing*) echo "fork" ;;
      *) echo "official" ;;
    esac
  }
  current_lineage="$(lineage_of "$current_image")"
  target_lineage="$(lineage_of "$kestra_image")"

  if [[ "$current_lineage" != "$target_lineage" ]]; then
    echo "Refusing to deploy a ${target_lineage} image over a ${current_lineage} deployment." >&2
    echo "  running: ${current_image}" >&2
    echo "  wanted:  ${kestra_image}" >&2
    echo "The two Kestra lineages cannot share a migrated database. Set" >&2
    echo "KESTRA_ALLOW_LINEAGE_SWITCH=true once the database has been reset or migrated." >&2
    exit 1
  fi
fi

helm_runtime_values="${tmpdir}/kestra-runtime-values.yaml"
cat >"$helm_runtime_values" <<EOF
image:
  repository: ${image_repository}
  tag: ${image_tag}
EOF

helm_args=()
helm_args+=(--values "${HELM_VALUES_DIR}/kestra-values.yaml")
if [[ "$GKE_MIN_COST_ENABLED" == "true" ]]; then
  helm_args+=(--values "${HELM_VALUES_DIR}/kestra-min-cost-values.yaml")
fi
helm_args+=(--values "$helm_runtime_values")
if [[ "$GKE_WORKER_ENABLED" != "true" ]]; then
  helm_args+=(--values "${HELM_VALUES_DIR}/kestra-controller-only-values.yaml")
fi

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

routed_worker_replicas=1
if [[ "$LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED" == "true" ]]; then
  routed_worker_replicas=0
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
  replicas: ${routed_worker_replicas}
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

activator_scale_deployments="kestra-gke-worker-small kestra-gke-worker-large"
activator_scale_statefulsets=""
activator_statefulset_rbac=""
activator_boot_state="cold"
activator_scale_resource_names="      - kestra-gke-worker-small
      - kestra-gke-worker-large"
if [[ "$LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED" == "true" ]]; then
  activator_scale_deployments="${activator_scale_deployments} kestra-webserver kestra-executor kestra-scheduler kestra-indexer"
  activator_boot_state="warm"
  activator_scale_resource_names="${activator_scale_resource_names}
      - kestra-webserver
      - kestra-executor
      - kestra-scheduler
      - kestra-indexer"
fi
if [[ "$LIVE_GKE_DATABASE_AUTOSCALE_ENABLED" == "true" ]]; then
  activator_scale_statefulsets="kestra-postgres"
  activator_statefulset_rbac="  - apiGroups:
      - apps
    resources:
      - statefulsets
      - statefulsets/scale
    resourceNames:
      - kestra-postgres
    verbs:
      - get
      - patch"
fi

render_routed_worker_activator() {
  cat <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
data:
  nginx.conf: |
EOF
  sed 's/^/    /' <<'NGINX_CONF_EOF'
worker_processes 1;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
  worker_connections 1024;
}

http {
  client_max_body_size 100m;
  access_log /var/log/kestra-activator/access.log combined;

  server {
    listen 8080;

    location = /health {
      access_log off;
      add_header Content-Type text/plain;
      return 200 'ok';
    }

    location / {
      proxy_pass http://kestra-webserver;
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_read_timeout 300s;
      proxy_intercept_errors on;
      error_page 502 503 504 = @warming;
    }

    location @warming {
      add_header Retry-After 5 always;
      return 503 'Kestra is starting; retry in 5 seconds.';
    }
  }
}
NGINX_CONF_EOF
  cat <<EOF
  activator.sh: |
EOF
  sed 's/^/    /' <<'ACTIVATOR_SCRIPT_EOF'
#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"
}

api_request() {
  method="$1"
  path="$2"
  data="${3:-}"
  if [ -n "${data}" ]; then
    curl --fail --silent --show-error \
      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
      -H "Content-Type: application/merge-patch+json" \
      -X "${method}" \
      -d "${data}" \
      "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}${path}"
  else
    curl --fail --silent --show-error \
      --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
      -X "${method}" \
      "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}${path}"
  fi
}

scale_resource() {
  resource="$1"
  name="$2"
  replicas="$3"
  api_request PATCH \
    "/apis/apps/v1/namespaces/${POD_NAMESPACE}/${resource}/${name}/scale" \
    "{\"spec\":{\"replicas\":${replicas}}}" \
    >/dev/null
}

scale_deployments() {
  failed=0
  for deployment in ${SCALE_DEPLOYMENTS}; do
    if scale_resource deployments "${deployment}" "$1"; then
      log "scaled deployment/${deployment} to replicas=$1"
    else
      log "failed to scale deployment/${deployment} to replicas=$1"
      failed=1
    fi
  done
  return "${failed}"
}

scale_statefulsets() {
  failed=0
  for statefulset in ${SCALE_STATEFULSETS}; do
    if scale_resource statefulsets "${statefulset}" "$1"; then
      log "scaled statefulset/${statefulset} to replicas=$1"
    else
      log "failed to scale statefulset/${statefulset} to replicas=$1"
      failed=1
    fi
  done
  return "${failed}"
}

wait_for_statefulsets_ready() {
  for statefulset in ${SCALE_STATEFULSETS}; do
    attempts=0
    while [ "${attempts}" -lt 180 ]; do
      status="$(api_request GET "/apis/apps/v1/namespaces/${POD_NAMESPACE}/statefulsets/${statefulset}")"
      if printf '%s' "${status}" | grep -Eq '"readyReplicas":[[:space:]]*1'; then
        log "statefulset/${statefulset} is ready"
        break
      fi
      attempts=$(( attempts + 1 ))
      sleep 2
    done
    if [ "${attempts}" -ge 180 ]; then
      log "timed out waiting for statefulset/${statefulset} readiness"
      return 1
    fi
  done
}

wait_for_deployments_stopped() {
  for deployment in ${SCALE_DEPLOYMENTS}; do
    attempts=0
    while [ "${attempts}" -lt 180 ]; do
      status="$(api_request GET "/apis/apps/v1/namespaces/${POD_NAMESPACE}/deployments/${deployment}")"
      if ! printf '%s' "${status}" | grep -Eq '"(availableReplicas|readyReplicas|replicas)":[[:space:]]*([1-9][0-9]*)'; then
        log "deployment/${deployment} is stopped"
        break
      fi
      attempts=$(( attempts + 1 ))
      sleep 2
    done
    if [ "${attempts}" -ge 180 ]; then
      log "timed out waiting for deployment/${deployment} to stop"
      return 1
    fi
  done
}

wake_all() {
  if [ -n "${SCALE_STATEFULSETS}" ]; then
    scale_statefulsets 1 || return 1
    wait_for_statefulsets_ready || return 1
  fi
  scale_deployments 1
}

park_all() {
  scale_deployments 0 || return 1
  wait_for_deployments_stopped || return 1
  if [ -n "${SCALE_STATEFULSETS}" ]; then
    scale_statefulsets 0 || return 1
  fi
}

reconcile() {
  if [ "$1" -eq 1 ]; then
    wake_all
  else
    park_all
  fi
}

last_size=0
if [ "${BOOT_STATE}" = "warm" ]; then
  last_access="$(date +%s)"
else
  last_access=$(( $(date +%s) - IDLE_SECONDS ))
fi
current=-1

log "activator started boot_state=${BOOT_STATE} idle_seconds=${IDLE_SECONDS} poll_seconds=${POLL_SECONDS} deployments=${SCALE_DEPLOYMENTS} statefulsets=${SCALE_STATEFULSETS}"

while :; do
  now="$(date +%s)"
  size=0
  if [ -f "${ACCESS_LOG}" ]; then
    size="$(wc -c <"${ACCESS_LOG}")"
  fi
  if [ "${size}" -ne "${last_size}" ]; then
    last_size="${size}"
    last_access="${now}"
  fi
  if [ $(( now - last_access )) -lt "${IDLE_SECONDS}" ]; then
    want=1
  else
    want=0
  fi
  if [ "${want}" -ne "${current}" ]; then
    if reconcile "${want}"; then
      current="${want}"
    fi
  fi
  sleep "${POLL_SECONDS}"
done
ACTIVATOR_SCRIPT_EOF
  cat <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
rules:
  - apiGroups:
      - apps
    resources:
      - deployments
      - deployments/scale
    resourceNames:
${activator_scale_resource_names}
    verbs:
      - get
      - patch
${activator_statefulset_rbac}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kestra-worker-activator
subjects:
  - kind: ServiceAccount
    name: kestra-worker-activator
    namespace: ${NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: kestra-worker-activator
    app.kubernetes.io/component: activator
    app.kubernetes.io/instance: kestra
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: kestra-worker-activator
      app.kubernetes.io/component: activator
      app.kubernetes.io/instance: kestra
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kestra-worker-activator
        app.kubernetes.io/component: activator
        app.kubernetes.io/instance: kestra
    spec:
      serviceAccountName: kestra-worker-activator
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 10
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
          volumeMounts:
            - name: activator-config
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
            - name: activator-log
              mountPath: /var/log/kestra-activator
        - name: scaler
          image: curlimages/curl:8.12.1
          command:
            - /bin/sh
            - /app/activator.sh
          env:
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: SCALE_DEPLOYMENTS
              value: "${activator_scale_deployments}"
            - name: SCALE_STATEFULSETS
              value: "${activator_scale_statefulsets}"
            - name: BOOT_STATE
              value: "${activator_boot_state}"
            - name: ACCESS_LOG
              value: /var/log/kestra-activator/access.log
            - name: IDLE_SECONDS
              value: "${LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS}"
            - name: POLL_SECONDS
              value: "${LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS}"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
          volumeMounts:
            - name: activator-config
              mountPath: /app/activator.sh
              subPath: activator.sh
            - name: activator-log
              mountPath: /var/log/kestra-activator
      volumes:
        - name: activator-config
          configMap:
            name: kestra-worker-activator
        - name: activator-log
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: kestra-worker-activator
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: kestra-worker-activator
    app.kubernetes.io/component: activator
    app.kubernetes.io/instance: kestra
  annotations:
    cloud.google.com/backend-config: '{"default": "kestra-worker-activator"}'
    cloud.google.com/neg: '{"ingress": true}'
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: kestra-worker-activator
    app.kubernetes.io/component: activator
    app.kubernetes.io/instance: kestra
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
EOF
}

delete_routed_worker_activator() {
  kubectl -n "$NAMESPACE" delete deployment kestra-worker-activator --ignore-not-found
  kubectl -n "$NAMESPACE" delete service kestra-worker-activator --ignore-not-found
  kubectl -n "$NAMESPACE" delete configmap kestra-worker-activator --ignore-not-found
  kubectl -n "$NAMESPACE" delete rolebinding kestra-worker-activator --ignore-not-found
  kubectl -n "$NAMESPACE" delete role kestra-worker-activator --ignore-not-found
  kubectl -n "$NAMESPACE" delete serviceaccount kestra-worker-activator --ignore-not-found
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
  if [[ "$LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED" == "true" ]]; then
    routed_worker_activator="${tmpdir}/routed-worker-activator.yaml"
    : >"$routed_worker_activator"
    render_routed_worker_activator >>"$routed_worker_activator"
    kubectl apply -f "$routed_worker_activator"
  else
    delete_routed_worker_activator
  fi
else
  delete_routed_worker_activator
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
  if [[ "$LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED" == "true" ]]; then
    kubectl -n "$NAMESPACE" rollout status deployment/kestra-worker-activator --timeout=10m
  else
    kubectl -n "$NAMESPACE" rollout status deployment/kestra-gke-worker-small --timeout=15m
    kubectl -n "$NAMESPACE" rollout status deployment/kestra-gke-worker-large --timeout=15m
  fi
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
