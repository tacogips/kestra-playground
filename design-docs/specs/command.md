# Command Design

This document describes CLI command interface design specifications.

## Overview

Command-line interface design decisions, including subcommands, flags, options, and environment variables.

---

## Sections

### Subcommands

Define the CLI subcommand structure and hierarchy.

### Flags and Options

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| (Add flags here) | | | |

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| (Add env vars here) | | | |

## Kestra Playground Commands

### Local Apple Container

```bash
local/apple-container/start.sh
scripts/register-flows.sh http://localhost:8080
scripts/run-flow.sh generate_ecommerce_mock_data
scripts/run-flow.sh build_ecommerce_daily_report
scripts/run-flow.sh build_ecommerce_customer_segments
local/apple-container/stop.sh
```

### Local Docker Compose Fallback

```bash
docker compose --env-file local/docker/.env.example -f local/docker/docker-compose.yml up -d
scripts/register-flows.sh http://localhost:8080
scripts/run-flow.sh generate_ecommerce_mock_data
scripts/run-flow.sh build_ecommerce_daily_report
scripts/run-flow.sh build_ecommerce_customer_segments
docker compose -f local/docker/docker-compose.yml down
```

Flow execution defaults to the current date in `Asia/Tokyo` when no business date is provided. Set
`BUSINESS_DATE=YYYY-MM-DD` or pass the second `scripts/run-flow.sh` argument to run a specific
partition. `scripts/run-flow.sh` also honors `BUSINESS_DATE` and `BUSINESS_DATE_TZ` from
`KESTRA_ENV_FILE`; explicit dates must use `YYYY-MM-DD`.

### Terraform Project Bootstrap

```bash
cd infra/terraform/bootstrap-project
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='billing_account=XXXXXX-XXXXXX-XXXXXX' \
  -var='org_id=123456789012'
```

### Terraform GCE Single VM

```bash
cd infra/terraform/gce-single
tofu init
tofu apply -var='project_id=kestra-playground-dev-<unique-suffix>'
```

With HTTPS domain resources:

```bash
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='domain_name=example.com' \
  -var='subdomain=dev'
```

### Terraform GCE Cluster

```bash
cd infra/terraform/gce-cluster
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2'
```

With HTTPS domain resources:

```bash
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='cluster_size=2' \
  -var='domain_name=example.com' \
  -var='subdomain=cluster-dev'
```

### Terraform GKE Dev

```bash
cd infra/terraform/gke-dev
tofu init
tofu apply -var='project_id=kestra-playground-dev-<unique-suffix>'
gcloud container clusters get-credentials kestra-dev --region asia-northeast1
scripts/apply-gke-dev.sh
```

For GKE HTTPS, pass `domain_name`, `subdomain`, and the DNS provider inputs, then run
`scripts/apply-gke-dev.sh`. The helper reads Terraform outputs, renders sensitive values into a
temporary manifest only, and waits for Kestra deployments to roll out.

To add one external GCE worker for Enterprise Worker Group routing, set:

```hcl
external_gce_worker_enabled      = true
external_gce_worker_group_key    = "gce-heavy"
external_gce_worker_machine_type = "e2-standard-4"
external_gce_worker_subnet_cidr  = "10.42.0.0/24"
```

For a GPU host, also set a compatible machine type and accelerator values:

```hcl
external_gce_worker_gpu_type  = "nvidia-tesla-t4"
external_gce_worker_gpu_count = 1
```

The VM uses Container-Optimized OS, has no public IP address, reads Secret Manager through the
metadata-token API, starts Cloud SQL Proxy over private IP, and runs only the Kestra worker
component. GPU workloads still need a compatible image, driver/toolchain installation, and quota
sized for the selected accelerator.

Register the Enterprise flow overlay after normal flow registration to route
`build_ecommerce_customer_segments` tasks to the external worker group:

```bash
scripts/register-flows.sh https://k8s.example.com kestra/flows
scripts/register-flows.sh https://k8s.example.com kestra/flows-enterprise
```

For live verification, set `KESTRA_ADDITIONAL_FLOW_DIRS=kestra/flows-enterprise` so the helper
updates the selected flow after registering the default flow set:

```bash
TARGET_ENVIRONMENT=k8s \
KESTRA_ADDITIONAL_FLOW_DIRS=kestra/flows-enterprise \
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

### Live Operations

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
TARGET_ENVIRONMENT=k8s BUSINESS_DATE=2026-06-25 kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

## Kestra GCP Operations Runbook

Use this runbook when building, releasing, deploying, or verifying the live development Kestra
playground. The current live project is `example-project-id` in `asia-northeast1`.

### Operations Flow Summary

The normal operating flow is:

1. Change flows, fixtures, source, Terraform, Kubernetes manifests, or docs.
2. Validate locally with `task ci` and targeted infrastructure checks.
3. Push to `main`; GitHub Actions builds the Kestra runtime image and pushes it to Artifact
   Registry.
4. Deploy the selected live targets with the SHA-tagged image.
5. Verify HTTPS readiness and register the checked-in flows.
6. Run the batch sequence for one business date:
   `generate_ecommerce_mock_data`, `build_ecommerce_daily_report`, then
   `build_ecommerce_customer_segments`.
7. Check Cloud Armor policy attachment and logs when investigating abusive traffic.
8. For GKE, inspect OpenTelemetry Collector logs when execution trace evidence is needed.

### Environment Map

| Target | Alias | Public URL | Terraform root | Runtime shape |
|--------|-------|------------|----------------|---------------|
| `gce-compose` | `gce-single` | `https://gce-compose.example.com` | `infra/terraform/gce-single` | Single GCE VM running Docker Compose |
| `gce-container` | `gce-cluster` | `https://gce-container.example.com` | `infra/terraform/gce-cluster` | GCE managed instance group running split Kestra components |
| `k8s` | `gke-dev` | `https://k8s.example.com` | `infra/terraform/gke-dev` | GKE Autopilot with Kustomize manifests |

The runtime image repository is:

```text
asia-northeast1-docker.pkg.dev/example-project-id/kestra-playground/kestra-runtime
```

### Prerequisites

Run commands through the Nix development shell so `python`, `gcloud`, `tofu`, `kubectl`,
`kustomize`, `task`, `docker`, `jq`, and `shellcheck` are available:

```bash
nix develop
```

Authenticate to Google Cloud before live operations:

```bash
gcloud auth login
gcloud config set project example-project-id
gcloud auth application-default login
```

Cloudflare DNS changes require `CLOUDFLARE_API_TOKEN`. Load it from `kinko`; do not write the token
to repository files:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

Cloud Armor configuration is rendered from ignored live config. The default rate limit is 300
requests per 60 seconds per client IP. Tune `CLOUD_ARMOR_RATE_LIMIT_REQUESTS_PER_INTERVAL`,
`CLOUD_ARMOR_RATE_LIMIT_INTERVAL_SEC`, or `CLOUD_ARMOR_PREVIEW` through `kinko` or CI variables when
needed.

### Local Development Check

Start the local runtime, register flows, and run the three batch flows:

```bash
task kestra:local:docker:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:flows:segments
```

To run a fixed partition, pass `BUSINESS_DATE`:

```bash
BUSINESS_DATE=2026-06-25 task kestra:flows:segments
```

Stop local Docker services when finished:

```bash
task kestra:local:docker:stop
```

### Release Path

The normal release path is a push to `main`. GitHub Actions validates the repo, builds the runtime
container, pushes two Artifact Registry tags, then deploys the SHA-tagged image:

```text
<repository>:<git-sha>
<repository>:latest
```

The deploy job passes the SHA-tagged image as `KESTRA_IMAGE` to `scripts/deploy-live-environments.sh`.
The deploy script applies `infra/terraform/cloud-armor` first, then injects the policy self link or
name into the GCE and GKE live tfvars before applying the selected target.
For a manual local redeploy of an existing image, set `KESTRA_IMAGE` explicitly:

```bash
export KESTRA_IMAGE="<region>-docker.pkg.dev/<project-id>/kestra-playground/kestra-runtime:<git-sha>"
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

### Deploy Targets

Deploy all environments:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

Deploy one environment:

```bash
TARGET_ENVIRONMENT=gce-compose kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
TARGET_ENVIRONMENT=gce-container kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
TARGET_ENVIRONMENT=k8s kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
```

The GKE deploy path also refreshes local kubeconfig and applies the rendered Kustomize overlay:

```bash
gcloud container clusters get-credentials kestra-dev --region asia-northeast1 --project "$PROJECT_ID"
scripts/apply-gke-dev.sh
```

The live config renderer forwards optional external GCE worker values from:

- `LIVE_GKE_EXTERNAL_GCE_WORKER_ENABLED`
- `LIVE_GKE_EXTERNAL_GCE_WORKER_GROUP_KEY`
- `LIVE_GKE_EXTERNAL_GCE_WORKER_MACHINE_TYPE`
- `LIVE_GKE_EXTERNAL_GCE_WORKER_GPU_TYPE`
- `LIVE_GKE_EXTERNAL_GCE_WORKER_GPU_COUNT`

### Health Verification

Run health verification after every deploy. This waits for each HTTPS UI endpoint and registers the
checked-in flows without executing batch work:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
TARGET_ENVIRONMENT=k8s kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
```

Health verification does not consume or validate `BUSINESS_DATE`; date resolution is only part of
batch execution.

### Cloud Armor Checks

Verify the shared security policy exists:

```bash
gcloud compute security-policies describe kestra-dev-cloud-armor --project="$PROJECT_ID"
```

Check GCE backend attachment:

```bash
gcloud compute backend-services describe kestra-dev-https \
  --global \
  --project="$PROJECT_ID" \
  --format='value(securityPolicy)'

gcloud compute backend-services describe kestra-cluster-dev-web \
  --global \
  --project="$PROJECT_ID" \
  --format='value(securityPolicy)'
```

Check GKE attachment through BackendConfig:

```bash
kubectl -n kestra-dev get backendconfig kestra-webserver -o yaml | rg 'securityPolicy|name:'
```

Cloud Armor Standard pricing is based on one security policy, its rules, and request volume. This
repo intentionally uses one shared policy to avoid per-environment policy duplication.

### Batch Verification

Run all batch flows in dependency order:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

For repeatable verification, pin the business date:

```bash
BUSINESS_DATE=2026-06-25 kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
TARGET_ENVIRONMENT=gce-container BUSINESS_DATE=2026-06-25 kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

If `BUSINESS_DATE` is unset or blank, the helper uses the current `Asia/Tokyo` date. Set
`BUSINESS_DATE_TZ` to use a different default timezone. Invalid date strings fail before any flow is
started.

The live verification helper loads Kestra Basic Auth credentials from Secret Manager and runs:

1. `generate_ecommerce_mock_data`
2. `build_ecommerce_daily_report`
3. `build_ecommerce_customer_segments`

### OpenTelemetry Verification

GKE dev deploys an in-cluster OpenTelemetry Collector and configures Kestra to send traces, metrics,
and logs to it through OTLP/gRPC:

```bash
kubectl -n kestra-dev rollout status deployment/otel-collector
kubectl -n kestra-dev get service otel-collector
kubectl -n kestra-dev logs deployment/otel-collector --tail=200
```

Run a batch after the collector is ready, then inspect collector logs for spans from the Kestra
component services and execution IDs:

```bash
TARGET_ENVIRONMENT=k8s BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
kubectl -n kestra-dev logs deployment/otel-collector --since=10m | \
  rg 'kestra.executionId|generate_ecommerce_mock_data|build_ecommerce_daily_report|build_ecommerce_customer_segments'
```

Expected service names include `kestra-webserver`, `kestra-executor`, `kestra-scheduler`,
`kestra-indexer`, and `kestra-worker`.

Collector spans include `kestra.uid`, which maps to the task-run ID in the Kestra execution API.
Use that mapping to audit span timing back to granular task names:

```bash
curl --fail --silent --show-error \
  -u "${KESTRA_BASIC_AUTH_USERNAME}:${KESTRA_BASIC_AUTH_PASSWORD}" \
  "https://k8s.example.com/api/v1/main/executions/<execution-id>" | \
  jq -r '.taskRunList[] | [.id, .taskId, .state.current] | @tsv'
```

### UI Verification

When visible browser verification is required, use Computer Use with Brave Browser and visit the
public URL for each target. Confirm that login succeeds, open
`playground.ecommerce/build_ecommerce_customer_segments`, and check that recent executions show
`SUCCESS`.

Do not print live Basic Auth secret values. Retrieve them from Secret Manager only into process
environment variables, clipboard, or a non-committed local shell.

### Secret Checks

Verify Secret Manager versions are enabled without printing secret payloads:

```bash
for secret in \
  kestra-dev-kestra-basic-auth-username \
  kestra-dev-kestra-basic-auth-password \
  kestra-cluster-dev-kestra-basic-auth-username \
  kestra-cluster-dev-kestra-basic-auth-password \
  kestra-dev-gke-kestra-basic-auth-username \
  kestra-dev-gke-kestra-basic-auth-password; do
  gcloud secrets versions list "$secret" \
    --project="$PROJECT_ID" \
    --filter='state:ENABLED' \
    --limit=1 \
    --format='value(name,state)'
done
```

For GKE, confirm the rendered Kubernetes Secret contains both helper and canonical Kestra Basic Auth
keys:

```bash
kubectl -n kestra-dev get secret kestra-secrets -o json | jq -r '.data | keys[]' | sort
```

Expected key families include:

- `ENV_BATCH_DB_*`
- `KESTRA_DB_*`
- `KESTRA_BASIC_AUTH_*`
- `KESTRA_SERVER_BASIC__AUTH_*`
- `KESTRA_GCS_BUCKET`

### Image And Rollout Checks

Check the latest Artifact Registry image:

```bash
gcloud artifacts docker images list \
  "${REGION}-docker.pkg.dev/${PROJECT_ID}/kestra-playground/kestra-runtime" \
  --include-tags \
  --sort-by='~UPDATE_TIME' \
  --limit=5
```

Check GKE deployment images and readiness:

```bash
kubectl -n kestra-dev get deployments
kubectl -n kestra-dev get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Check GCE instance health:

```bash
gcloud compute instance-groups unmanaged list-instances kestra-dev-single \
  --zone=asia-northeast1-a \
  --project="$PROJECT_ID"

gcloud compute instance-groups managed describe kestra-cluster-dev-mig \
  --region=asia-northeast1 \
  --project="$PROJECT_ID" \
  --format=json | jq '.targetSize,.currentActions'
```

### Drift Checks

Before changing live infrastructure, render ignored live config from `kinko`, then run targeted
plans:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- scripts/render-live-config.sh
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/cloud-armor init -backend-config=../../live/dev/cloud-armor.backend.hcl
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/cloud-armor plan -var-file=../../live/dev/cloud-armor.tfvars
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/gce-single init -backend-config=../../live/dev/gce-single.backend.hcl
kinko exec --env CLOUDFLARE_API_TOKEN -- \
  tofu -chdir=infra/terraform/gce-single plan -var-file=../../live/dev/gce-single.tfvars
```

### Troubleshooting

Use these checks before changing infrastructure:

```bash
curl -I https://gce-compose.example.com/ui/
curl -I https://gce-container.example.com/ui/
curl -I https://k8s.example.com/ui/
```

For failed Kestra executions, inspect the execution in the UI first, then query by execution ID with
Basic Auth if needed. For failed GKE rollouts, prefer `kubectl -n kestra-dev describe deployment`,
`kubectl -n kestra-dev describe pod`, and container logs before reapplying Terraform.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| (Add more exit codes as needed) | |

---
