# kestra-playground

Kestra deployment playground for ecommerce batch workflows. The repository keeps a small Python
package scaffold, but the primary assets are Kestra flows, local runtime scripts, Terraform, and
Kubernetes manifests.

## Requirements

- Python 3.12 or newer
- `uv`
- Nix with flakes for the full infrastructure toolchain
- Apple container for the primary local runtime, or Docker Compose as a fallback

## Quick Start

```bash
uv sync --dev
uv run python -m kestra_playground
uv run pytest
```

## Kestra Workloads

Three mock ecommerce flows live under `kestra/flows/`:

- `generate_ecommerce_mock_data` creates product, customer, order, payment, inventory, and support
  ticket data in PostgreSQL.
- `build_ecommerce_daily_report` writes and fetches daily operational metrics from that data.
- `build_ecommerce_customer_segments` writes and fetches a customer lifecycle segment snapshot from
  the generated order and support activity.

The batch relationship is intentionally linear: generate the partition first, then build derived
outputs for the same business date.

```mermaid
sequenceDiagram
    actor Operator
    participant Kestra
    participant DB as Ecommerce PostgreSQL

    Operator->>Kestra: Register flows
    Operator->>Kestra: Run generate_ecommerce_mock_data(date)
    Kestra->>DB: Create tables, seed dimensions, replace daily facts
    DB-->>Kestra: Source partition ready
    Kestra-->>Operator: Generator execution SUCCESS

    Operator->>Kestra: Run build_ecommerce_daily_report(date)
    Kestra->>DB: Aggregate orders, payments, inventory, support
    DB-->>Kestra: Daily report rows
    Kestra-->>Operator: Report execution SUCCESS

    Operator->>Kestra: Run build_ecommerce_customer_segments(date)
    Kestra->>DB: Derive lifecycle segments from orders and support
    DB-->>Kestra: Segment summary rows
    Kestra-->>Operator: Segment execution SUCCESS
```

All three flows use `ENV_BATCH_DB_URL`, `ENV_BATCH_DB_USERNAME`, and `ENV_BATCH_DB_PASSWORD` so
local and GCP database connection values can be switched by environment file, Secret Manager, or
Kubernetes Secret.

In GCP, Kestra management state and ecommerce batch data share one database instance but use
separate logical databases: `kestra` for Kestra repository/queue tables and `ecommerce_ops` for
batch tables. Runtime connection values are stored as separate Secret Manager entries for the
Kestra connection and the batch connection, even when a development target temporarily uses the same
PostgreSQL login behind both secret families.

The generated ecommerce data is tracked in `kestra/fixtures/ecommerce/`. The generator flow embeds
those SQL fixtures into PostgreSQL tasks, and the test suite checks that the deployed flow SQL stays
in sync with the committed fixture files.

Current Kestra OSS requires Basic Auth. Local defaults are in `local/docker/.env.example`; the GCP
Terraform roots generate/store runtime credentials in Secret Manager. The GCE roots read Basic Auth
directly from Secret Manager at startup, and the GKE apply helper renders the Kubernetes Secret from
GKE-specific Secret Manager entries.

## Local Kestra

Apple container path:

```bash
cp kestra/config/envs/local.env.example kestra/config/envs/local.env
task kestra:local:apple:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:flows:segments
task kestra:local:apple:stop
```

Docker Compose fallback:

```bash
cp local/docker/.env.example local/docker/.env
task kestra:local:docker:start
task kestra:flows:register
task kestra:flows:generate
task kestra:flows:report
task kestra:flows:segments
task kestra:local:docker:stop
```

Kestra UI defaults to `http://localhost:8080`.

Flow helper scripts can load credentials, URL settings, and default batch date settings from an env
file:

```bash
KESTRA_ENV_FILE=kestra/config/envs/local.env scripts/register-flows.sh
KESTRA_ENV_FILE=local/docker/.env scripts/register-flows.sh
```

The `task kestra:flows:*` commands use `KESTRA_ENV_FILE` when provided, otherwise they prefer
`local/docker/.env` and fall back to `kestra/config/envs/local.env`.

Registering/running flows against an authenticated endpoint. If a business date is not provided,
the helper scripts default to the current date in `Asia/Tokyo`; set `BUSINESS_DATE_TZ` to override
that default timezone. Explicit dates must use `YYYY-MM-DD`.

```bash
export KESTRA_BASIC_AUTH_USERNAME=...
export KESTRA_BASIC_AUTH_PASSWORD=...
scripts/register-flows.sh http://34.84.21.87:8080
scripts/run-flow.sh generate_ecommerce_mock_data 2026-06-25 http://34.84.21.87:8080
scripts/run-flow.sh build_ecommerce_daily_report 2026-06-25 http://34.84.21.87:8080
scripts/run-flow.sh build_ecommerce_customer_segments 2026-06-25 http://34.84.21.87:8080
```

## GCP Deployment Shapes

Terraform roots are split by phase:

- `infra/terraform/bootstrap-project`: creates a new GCP project and enables required APIs.
- `infra/terraform/github-actions`: creates the GitHub OIDC provider and deploy service account
  used by the push/manual/cron workflow.
- `infra/terraform/cloud-armor`: creates the shared Cloud Armor policy used by live HTTPS targets.
- `infra/terraform/gce-single`: one GCE VM running Kestra and PostgreSQL through Docker Compose,
  with separate Kestra and batch DB connection values loaded from Secret Manager.
- `infra/terraform/gce-cluster`: multiple GCE VMs running separated Kestra components against shared
  Cloud SQL and GCS. The Cloud SQL instance contains separate `kestra` and `ecommerce_ops`
  databases, and each JDBC connection family has its own Secret Manager entries.
- `infra/terraform/gke-dev`: GKE Autopilot, Cloud SQL, GCS, and Workload Identity inputs for the
  Kubernetes manifests. It stores GKE runtime DB connection values in Secret Manager, renders them
  into Kubernetes only during apply, and acts as the federated OSS controller.

System shape, at a high level:

- One workload contract: the same Kestra flows and runtime image are used locally, on GCE, and on
  GKE.
- One release artifact: GitHub Actions builds the Kestra runtime image and publishes it to Artifact
  Registry with a commit tag plus `latest`.
- Three live HTTPS targets: single-VM Docker Compose, GCE component cluster, and GKE Autopilot each
  have their own subdomain under `example.com`.
- Terraform owns cloud infrastructure, DNS records, Secret Manager entries, load balancers, and
  managed data services. Kustomize owns Kubernetes workload shape.
- A shared Google Cloud Armor policy protects the HTTPS backends with per-client rate limiting and
  an optional source block list.
- Secret values stay outside git; local env files, Secret Manager, GitHub Actions secrets, and
  `kinko` provide runtime values.

The GCE cluster root runs Cloud SQL Proxy as a Docker Compose service, so Kestra uses
`cloud-sql-proxy:5432`. The GKE manifests run Cloud SQL Proxy as a sidecar in each Pod, so those
JDBC URLs use `127.0.0.1:5432`.

For the OSS-compatible federated execution pattern, keep separate Kestra deployments instead of
trying to attach remote workers to one OSS worker queue. In the live dev-as-prod topology:

- `gce-compose` is GCE worker A and receives `playground.ecommerce.server_gce_a`;
- `gce-container` is GCE worker B and receives `playground.ecommerce.server_gce_b`;
- `k8s` is the controller Kestra only and does not run a `kestra-worker` Deployment;
- the `gke-dev` Terraform root also creates a GCE `controller-worker` VM that runs only
  `kestra server worker` against the GKE controller backend;
- `kestra/flows` is rendered and registered only on the two GCE child deployments;
- `kestra/flows-federated` is registered only on the GKE controller.

The controller flow calls child Kestra REST APIs, waits for child execution status, and records child
execution IDs in its own task outputs. Rerunning the controller flow reruns the GCE child
executions. This keeps production-like workflow shape without using Enterprise Worker Groups or the
removed DB-backed agent implementation.

No Kestra worker process is allowed to run in GKE. Lightweight controller HTTP, polling, and
assertion tasks are claimed by the GCE `controller-worker` VM because it uses the same GKE
controller DB, queue, and GCS storage configuration. The two GCE child Kestra deployments remain the
execution targets for ecommerce batch work; they are separate from the controller-worker process.

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy:federated
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-federated
```

Example bootstrap:

```bash
cd infra/terraform/bootstrap-project
tofu init
tofu apply \
  -var='project_id=kestra-playground-dev-<unique-suffix>' \
  -var='billing_account=XXXXXX-XXXXXX-XXXXXX' \
  -var='org_id=123456789012'
```

The commands use OpenTofu from the Nix shell; the files are Terraform-compatible.

Set the live development project through `PROJECT_ID` or `GCP_PROJECT_ID`; do not commit real
project IDs.

Kestra runtime images are published to Artifact Registry:

```text
<region>-docker.pkg.dev/<project-id>/kestra-playground/kestra-runtime
<region>-docker.pkg.dev/<project-id>/kestra-playground/kestra-oss-worker-routing
```

The runtime image extends `kestra/kestra:latest` and bakes in `kestra/flows/`,
`kestra/fixtures/`, `kestra/config/`, and the Python batch source under `src/`. The deployment
workflow builds and pushes a commit-SHA tag plus `latest`, then passes the SHA-tagged image to
Terraform through `KESTRA_IMAGE`. The GCE roots use that image in Docker Compose; the GKE apply
helper applies the same image through Kustomize before `kubectl apply`.

For the shared-backend routed target, the deployment workflow checks out
`tacogips/kestra@feature/oss-worker-routing`, builds the custom Kestra executable, installs the GCS
storage plugin, pushes `kestra-oss-worker-routing` tags to Artifact Registry, and deploys the
commit-SHA tag.

Live dev tfvars and backend config are generated under `infra/live/dev/` and ignored by git. They
contain environment-specific project, domain, Cloudflare zone, and state bucket values. Keep those
values in `kinko` locally, or in GitHub repository variables/secrets for CI:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

Limit a command to one environment with `TARGET_ENVIRONMENT`:

```bash
TARGET_ENVIRONMENT=gce-container BUSINESS_DATE=2026-06-25 task kestra:live:run-batch
```

Direct batch execution is disabled for `TARGET_ENVIRONMENT=k8s`; use
`task kestra:live:run-federated` for the GKE controller path.

GitHub Actions deploys on push to `main`, supports manual dispatch for selected environments, and
runs the ecommerce batch on a daily cron. The workflow uses GitHub OIDC for Google Cloud auth and
expects these repository secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_SERVICE_ACCOUNT`
- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`

It also expects repository variables for the live project, domain, state bucket, image repository,
and optional environment URL.

Live Terraform state uses a GCS bucket provided through generated backend config. The live roots use
per-root prefixes so GitHub Actions can deploy from a fresh checkout without recreating existing
resources.

## Operations Flow

The normal operating path is:

1. Change flows, fixtures, app source, Terraform, Kubernetes manifests, or docs.
2. Run local validation through `task ci` and targeted infrastructure checks.
3. Push to `main`; GitHub Actions builds and publishes the runtime image.
4. Deploy the selected live targets with the SHA-tagged image.
5. Verify HTTPS readiness and register the checked-in flows.
6. Run the batch sequence for a business date: generate data, build the report, then build customer
   segments.
7. Check Cloud Armor policy attachment and logs when investigating abuse or rate limiting.
8. For GKE, check the OpenTelemetry Collector when trace-level evidence is needed.

Manual operations use the same scripts as CI:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
```

## HTTPS Domains

The GCE single-VM, GCE cluster, and GKE dev Terraform roots support HTTPS domain configuration.
The Cloudflare-backed development hostnames are derived from generated live config:

- GKE: `https://k8s.example.com`
- GCE clustered container environment: `https://gce-container.example.com`
- GCE single VM Docker Compose environment: `https://gce-compose.example.com`

Start from the checked-in example variables for the root you are applying:

```bash
cp infra/terraform/gce-cluster/terraform.tfvars.example infra/terraform/gce-cluster/terraform.tfvars
```

Then set `domain_name` plus an environment subdomain and apply:

```bash
tofu apply \
  -var='project_id=<project-id>' \
  -var='domain_name=example.com' \
  -var='subdomain=gce-container' \
  -var='dns_provider=cloudflare' \
  -var='cloudflare_zone_id=<cloudflare-zone-id>'
```

When `dns_provider=cloudflare`, set `CLOUDFLARE_API_TOKEN` in the environment. In this workspace,
the token and live DNS values are stored in `kinko`, so Terraform can be run with:

```bash
kinko exec --env CLOUDFLARE_API_TOKEN,CLOUDFLARE_ZONE_ID,LIVE_DOMAIN_NAME -- tofu apply ...
```

When `dns_provider=google` and `create_dns_zone=true`, the root creates a Cloud DNS managed zone and outputs
`dns_name_servers`; delegate the parent domain to those name servers at the registrar. When using an
existing Cloud DNS zone, set `create_dns_zone=false` and `dns_zone_name=<zone-name>`.

After DNS record propagation, Google-managed certificates can take several minutes to become active.
The GKE root reserves the static ingress IP and creates the Cloudflare A record; the dev Kubernetes
overlay contains the matching `k8s.example.com` host and `kestra-dev-ingress` static IP name.

## Cloud Armor DoS Mitigation

`infra/terraform/cloud-armor` creates one shared Google Cloud Armor security policy for the live
HTTPS targets. The deploy helper applies that root first, reads the policy outputs, and renders the
ignored live tfvars so:

- `gce-compose` attaches the policy to the single-VM HTTPS backend service.
- `gce-container` attaches the same policy to the clustered web backend service.
- `k8s` attaches the same policy through the GKE `BackendConfig`.

The default policy throttles each client IP after 300 requests per 60 seconds and returns HTTP 429
for excess requests. Tune `CLOUD_ARMOR_RATE_LIMIT_REQUESTS_PER_INTERVAL`,
`CLOUD_ARMOR_RATE_LIMIT_INTERVAL_SEC`, and `CLOUD_ARMOR_PREVIEW` through `kinko` or CI variables
before deploy when a different threshold or observe-only rollout is needed.

Cloud Armor Standard cost is roughly one security policy plus rules and request processing. For this
playground, expect a small fixed monthly cost for one shared policy and its rules, plus request
volume charges.

## Kubernetes

Kubernetes manifests are Kustomize-based:

```bash
kustomize build k8s/overlays/dev
scripts/apply-gke-dev.sh
```

The GKE dev overlay includes an in-cluster OpenTelemetry Collector at
`otel-collector.kestra-dev.svc.cluster.local` with OTLP/gRPC on `4317` and OTLP/HTTP on `4318`.
Kestra's Kubernetes `application.yaml` enables Micronaut OpenTelemetry and Kestra flow traces by
default, exporting traces, metrics, and logs to `http://otel-collector:4317`.

Each GKE Kestra control component sets a distinct `OTEL_SERVICE_NAME` (`kestra-webserver`,
`kestra-executor`, `kestra-scheduler`, and `kestra-indexer`) plus resource attributes for the
namespace, pod, environment, and Kestra component. The GKE overlay intentionally does not run a
`kestra-worker` Pod; worker telemetry for executed tasks must come from the GCE worker environment.
Batch flow tasks are split into granular SQL steps so OTEL traces expose auditable spans for
purging, inserts, summaries, and fetches.

After applying GKE, verify telemetry is being received by checking the collector rollout and logs:

```bash
kubectl -n kestra-dev rollout status deployment/otel-collector
kubectl -n kestra-dev logs deployment/otel-collector --tail=200
```

Collector spans include `kestra.executionId`, `kestra.flowId`, and `kestra.uid`. The `kestra.uid`
value maps to the task-run ID returned by the Kestra execution API, which lets operators correlate
collector spans back to specific granular batch tasks.

Apply the live GKE overlay with Terraform outputs without writing real secrets into the repository:

```bash
task k8s:apply:dev
```

For the live GKE environment, Kestra Basic Auth and database connection values are stored in Secret
Manager under the `kestra-dev-gke-*` prefix. `scripts/apply-gke-dev.sh` reads the secret IDs from
Terraform outputs, accesses the latest enabled versions at apply time, and writes values only into a
temporary rendered manifest before updating the Kubernetes Secret.

## Common Commands

```bash
task sync
task run
task test
task lint
task typecheck
task fmt
task build
task scripts:check
task kestra:local:apple:start
task kestra:flows:register
task infra:fmt
task k8s:build:dev
task k8s:apply:dev
```
