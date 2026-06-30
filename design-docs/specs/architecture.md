# Architecture Design

This document describes system architecture and design decisions.

## Overview

Architectural patterns, system structure, and technical decisions.

---

## Sections

(Add architecture design sections below)

---

## Kestra Deployment Playground

This repository is a playground for running the same Kestra ecommerce mock batch workload across
four deployment shapes:

1. Local Apple container runtime using PostgreSQL and file-based Kestra configuration.
2. GCP single-VM deployment managed by Terraform, with a new GCP project, Secret Manager, and
   Docker Compose on GCE running both Kestra and PostgreSQL.
3. GCP multi-VM Kestra cluster using separate Kestra server components, Cloud SQL, shared GCS
   internal storage, and a load-balanced webserver tier.
4. GKE Autopilot development deployment using Kustomize base manifests plus environment overlays.

### System Composition Summary

The important architectural traits are:

- The workload contract is shared: the same Kestra flow definitions, SQL fixtures, and runtime image
  are promoted through local, GCE, and GKE targets.
- Terraform owns cloud infrastructure: GCP project bootstrap, Artifact Registry, IAM, Secret
  Manager, Cloud SQL, GCS, GCE, GKE inputs, load balancers, Cloud Armor, and DNS records.
- Kustomize owns Kubernetes workload shape for GKE, with Terraform outputs bridged into the dev
  overlay by `scripts/apply-gke-dev.sh`.
- GitHub Actions is the default release controller and uses OIDC to deploy without long-lived GCP
  keys.
- Secret values are not source artifacts. Local env files, Secret Manager, GitHub Actions secrets,
  and `kinko` provide runtime values.

The live environment exposes three HTTPS targets under the same Cloudflare-backed domain:

| Target | URL | Runtime shape |
|--------|-----|---------------|
| `gce-compose` | `https://gce-compose.example.com` | One GCE VM running Kestra and PostgreSQL through Docker Compose |
| `gce-container` | `https://gce-container.example.com` | GCE instance group running split Kestra components with shared Cloud SQL and GCS |
| `k8s` | `https://k8s.example.com` | GKE Autopilot running split Kestra components from Kustomize manifests |

Cloud Armor is managed as a separate Terraform root so all live HTTPS targets can share one policy.
The GCE roots attach the policy self link to their backend services. The GKE path passes the policy
name through Terraform output and patches `BackendConfig.securityPolicy.name` during
`scripts/apply-gke-dev.sh`.

### Workload

The workload namespace is `playground.ecommerce`.

- `generate_ecommerce_mock_data` creates product, customer, order, order item, payment, inventory,
  and support ticket mock data for ecommerce operations.
- `build_ecommerce_daily_report` reads the mock tables and emits an operational daily report into
  `ecommerce_daily_reports`, with rows returned in the Kestra execution output.
- `build_ecommerce_customer_segments` writes a daily customer lifecycle segment snapshot into
  `ecommerce_customer_segments` and returns the segment summary.

Batch execution order is deliberately simple:

1. `generate_ecommerce_mock_data` prepares the source partition for the business date.
2. `build_ecommerce_daily_report` aggregates the generated facts into operational report rows.
3. `build_ecommerce_customer_segments` derives customer lifecycle segments from the same source
   partition.

All flows use the PostgreSQL JDBC plugin and read their target business database from Kestra
environment variables:

| Environment variable | Purpose |
|----------------------|---------|
| `ENV_BATCH_DB_URL` | JDBC URL for the ecommerce batch database |
| `ENV_BATCH_DB_USERNAME` | Batch database user |
| `ENV_BATCH_DB_PASSWORD` | Batch database password |

Local and GCP deployments switch values through environment files or platform secrets. In GCP,
Kestra's repository/queue tables and ecommerce batch tables share the same PostgreSQL instance but
live in separate logical databases: `kestra` for Kestra management state and `ecommerce_ops` for
batch data. Runtime configuration treats these as two separate connection families, exposed through
`KESTRA_DB_*` and `ENV_BATCH_DB_*` secrets.

### Local Runtime

The primary local target is Apple container. The scripts under `local/apple-container/` start:

- a `postgres:16` container with named volumes;
- a `kestra/kestra:latest` standalone container with `kestra/config/application.yaml`;
- a shared Apple container network for service DNS.

`local/docker/docker-compose.yml` is kept as a fallback for machines where Docker Compose is still
more convenient than Apple container.

### GCP Single VM

`infra/terraform/gce-single` creates a VM that runs Docker Compose for Kestra and PostgreSQL.
Terraform also creates a new GCP project when paired with `infra/terraform/bootstrap-project`,
Secret Manager secrets for database connection values, and a service account that can read only the
required secrets.

The VM shape is intentionally simple and non-clustered: one GCE instance, one Kestra standalone JVM,
and one PostgreSQL container with a persistent Docker volume.

When `domain_name` is set, the root also creates a Google HTTPS load balancer, a Google-managed SSL
certificate, a static global IP address, and a Cloud DNS A record for the environment subdomain.

### GCP GCE Cluster

`infra/terraform/gce-cluster` validates the cluster path by creating multiple GCE instances. Each VM
runs a multi-component Docker Compose stack with webserver, executor, scheduler, indexer, and worker
services. All instances share:

- Cloud SQL PostgreSQL for Kestra repository and queue;
- Cloud SQL PostgreSQL for ecommerce batch data;
- GCS for Kestra internal storage;
- Secret Manager for the Kestra DB, batch DB, Basic Auth, Cloud SQL instance, and GCS bucket runtime
  values.

The webserver component is exposed through an HTTP load balancer. This is still an infrastructure
playground, so defaults are intentionally dev-sized and deletion protection is disabled.

When `domain_name` is set, the cluster root adds a parallel HTTPS load balancer and DNS record for
the requested environment subdomain.

### GKE Development Manifests

GKE uses the official Kestra Helm chart for Kestra server components. `k8s/helm/kestra-values.yaml`
disables standalone mode and enables separate `webserver`, `executor`, `scheduler`, `indexer`, and
`worker` Deployments. The same values attach the Cloud SQL Auth Proxy sidecar, shared Secret and
ConfigMap environment, OTEL environment, GCS/Postgres application configuration, and a
`kestra-worker` HorizontalPodAutoscaler.

Kustomize still owns support resources that are not part of the chart contract:
`k8s/base` contains Namespace, ServiceAccount, Secret, ConfigMap, webserver LoadBalancer Service,
controller gRPC internal LoadBalancer Service, and the OTEL collector. `k8s/overlays/dev` adds
development namespace, labels, Workload Identity annotations, Ingress, ManagedCertificate,
BackendConfig, and runtime patches rendered from Terraform outputs.

For HTTPS, `infra/terraform/gke-dev` can reserve a global static IP and create the Cloud DNS record.
The dev overlay includes a GKE `ManagedCertificate` and Ingress placeholder that are patched with
the Terraform hostname and static IP name before apply.

Live development HTTPS currently uses Cloudflare DNS records for `example.com`:

- `https://k8s.example.com`
- `https://gce-container.example.com`
- `https://gce-compose.example.com`

GKE Basic Auth and database connection values are stored in Secret Manager and rendered into
Kubernetes only through the temporary manifest path in `scripts/apply-gke-dev.sh`. Terraform exports
Secret Manager IDs, not DB secret payloads, for the apply helper.

The production-like OSS hybrid path is federated rather than queue-shared:

- `gce-compose` is GCE worker A and receives the `playground.ecommerce.server_gce_a` namespace;
- `gce-container` is GCE worker B and receives the `playground.ecommerce.server_gce_b` namespace;
- `k8s` is the controller Kestra and deploys the Helm controller-only override so no
  `kestra-worker` Deployment or HPA is released;
- the `gke-dev` Terraform root creates a GCE `controller-worker` VM that runs only
  `kestra server worker` against the GKE controller backend;
- child flows from `kestra/flows` are rendered into server-specific namespaces before registration;
- controller flows from `kestra/flows-federated` are registered only on `k8s`;
- the controller flow calls child Kestra REST APIs, waits for child execution state, and records
  child execution IDs in controller task outputs.

The invariant is that no Kestra worker process runs in GKE. Any work executed by a Kestra worker,
including lightweight controller HTTP and polling tasks, is picked up by the GCE controller-worker
VM attached to the GKE controller backend. Ecommerce batch child flows are not registered or
executed on GKE; all JDBC batch work is placed on the two GCE child Kestra targets by URL and
namespace.

This OSS topology does not rely on a native Kestra `taskRunner` or Worker Group setting for sticky
placement. The sticky execution boundary is the child Kestra API endpoint plus the rendered
namespace: a controller task that calls `gce-compose` can only start `server_gce_a` flows, and a
controller task that calls `gce-container` can only start `server_gce_b` flows.

The custom OSS worker-routing image enables a second, stronger shared-backend topology:

- GKE deploys the official Kestra Helm chart with `k8s/helm/kestra-controller-only-values.yaml`, so
  only the webserver, scheduler, executor, and indexer roles run there.
- GCE workers connect to the same GKE Cloud SQL queue/repository and GCS internal storage.
- GCE workers connect outbound to an internal GKE LoadBalancer for Kestra controller gRPC; no worker
  port is exposed back to GKE.
- The GKE controller config defines static queues `gce-a` and `gce-b` under
  `kestra.worker.routing.queues`.
- Each GCE worker sets `kestra.worker.routing.workerGroupId` to the group it serves.
- Flow tasks use native `workerSelector.tags` to dispatch to a queue before worker pickup, so
  non-target workers do not run skip/no-op tasks.
- Script tasks that should run on the selected machine use
  `taskRunner: io.kestra.plugin.core.runner.Process`. Without that explicit task runner, script
  plugin defaults can try Docker execution and fail on a worker container that does not mount a
  Docker socket.
- The live image is built from `tacogips/kestra@feature/oss-worker-routing` and pushed to Google
  Artifact Registry as
  `${REGION}-docker.pkg.dev/${PROJECT_ID}/kestra-playground/kestra-oss-worker-routing:<tag>`.

This shared-backend route is the closer OSS analogue to Enterprise Worker Groups: GKE can observe,
retry, rerun, and inspect the routed execution in one controller Kestra, while the script task JVM
work runs only on GCE workers.

The same static routing mechanism can also be exercised inside GKE with explicit routed worker
Deployments. `LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true` makes `scripts/apply-gke-dev.sh` render
dedicated `kestra-gke-worker-small` and `kestra-gke-worker-large` Deployments. Each worker uses a
different `workerGroupId`, exposes its own queue tag (`gke-small` or `gke-large`), and injects its
pod name and node name into task logs. The verification flow
`playground.worker_routing.verify_gke_node_worker_routing` proves that tasks selected with
`workerSelector.tags` are claimed by the expected worker Deployment and therefore run in the worker
pod's placement domain.

The renderer supports two Kubernetes placement modes for those routed workers. The normal
Autopilot-compatible mode uses `LIVE_GKE_ROUTED_K8S_WORKER_*_NODE_SELECTOR_*` with an allowed label
such as `topology.kubernetes.io/zone`; this lets GKE schedule the pod and scale capacity. A
diagnostic exact-node mode uses `LIVE_GKE_ROUTED_K8S_WORKER_*_NODE_NAME` to render `spec.nodeName`.
Live testing showed that Autopilot accepts `spec.nodeName`, but because it bypasses normal
scheduling it does not trigger scale-up and can fail with node-local `OutOfmemory` or `OutOfcpu`.
Autopilot also rejects `nodeSelector: kubernetes.io/hostname`. Therefore, on the current live
Autopilot cluster, the verified production-like invariant is placement-domain routing plus
autoscaler cleanup, not durable exact hostname pinning. Exact hostname pinning with autoscaling
belongs on a GKE Standard design with node pools sized for the worker classes.

The `gke-dev` Terraform root now keeps Autopilot as the default but can create that Standard design
when `gke_autopilot_enabled=false`. In Standard mode, Terraform creates autoscaled node pools from
`gke_standard_node_pools`; the default pools are labeled
`kestra.tacogips.io/worker-group=gke-small` and
`kestra.tacogips.io/worker-group=gke-large` and tainted with the same worker-group values. Routed
worker Deployments should select those labels and tolerate the matching taints, not pin ephemeral
node names. This lets the scheduler place each worker class on the intended node pool, and gives the
GKE cluster autoscaler a cleaner worker-only node to drain after the routed workers are deleted.

The OSS Kubernetes pod-resource topology solves a different problem: per-batch CPU and memory
without sticky worker placement. In that topology, a regular GKE Kestra worker claims the
`PodCreate` task, then asks the Kubernetes API to create one pod per batch. Each task carries its
own pod spec, including `resources.requests` and `resources.limits`, and intentionally does not set
`nodeSelector`. Kubernetes schedules the pods and GKE autoscaling reacts to the requested resources.
Kestra still owns the execution graph, task state, rerun button, and task logs, but the heavy batch
process runs in the child Kubernetes pod rather than inside the Kestra worker pod. The verification
flow leaves labeled test pods in place long enough for the verifier to inspect their actual
CPU/memory requests and limits, then removes those pods.

This is a better OSS fit than worker routing when the requirement is only "different batches need
different vCPU/memory". It does not provide "run this batch on this specific machine" semantics.
For that, use Enterprise Worker Groups or the custom static worker-routing fork.

The operation-demo layout makes the development-operation delta explicit:

```text
batches/resource_probe/run.sh
  Shared batch implementation. Local, GKE PodCreate, and routed worker flows all execute this file.

kestra/flows-operation-demo/local/
  Local wrapper. It uses a Process task runner in the local standalone Kestra container.

kestra/flows-operation-demo/gke-pod-resources/
  GKE wrapper. It uses a Parallel flow task containing two OSS PodCreate tasks, one Kubernetes pod
  per batch, and sets per-batch requests/limits in the pod spec. The child pod image comes from
  ENV_RUNTIME_IMAGE, which is rendered from the deployed Kestra runtime image in
  `scripts/apply-gke-dev.sh`.

kestra/flows-operation-demo/routed-worker/
  GCE/on-prem-style wrapper. It uses the custom OSS `workerSelector.tags` routing fork and Process
  task runner so the same source runs on the selected worker host.
```

For a new batch, the intended source boundary is the same: put implementation code under
`batches/<batch-name>/`, unit-check it locally, then create small Kestra resource wrappers for the
runtime topology. The business code does not split between local, GKE, and on-prem paths. What
changes between environments is the Kestra execution wrapper:

| Path | Heavy work runs in | Kestra resource delta from local |
|------|--------------------|----------------------------------|
| Local standalone | Local Kestra worker container | Process task points at the mounted shared batch source. |
| GKE PodCreate | Kubernetes child pod | Replace Process task with Parallel PodCreate tasks and add pod image/resources. |
| GCE/on-prem routed worker | Selected external worker host | Keep Process task and add `workerSelector.tags`. |

This means GKE PodCreate needs a larger Kestra YAML change than local because Kubernetes pod
metadata, image, env, resources, and the parallel execution wrapper must be declared. The routed
worker path is closer to local: the task body remains a Process command and the main added config is
`workerSelector`.

The GKE operation-demo verifier captures pod resource evidence before waiting for final Kestra
execution state. Live testing showed that leaving PodCreate pods undeleted can trigger a Fabric8
final GET timeout after the child pod succeeds on the current 2.0 snapshot image, so the demo keeps
pods alive briefly with `SLEEP_SECONDS=45`, lets PodCreate clean them up, and inspects the pod specs
while they are still present.

Kestra Worker Groups remain an Enterprise Edition feature. The OSS runtime should not attach an
external Kestra worker to a shared queue when deterministic placement is required, because ordinary
workers load-balance tasks across all available workers. The removed DB-backed agent design remains
documented as an alternative analysis, but it is not the active implementation because it would make
local/staging and production workflows diverge too much.

For the Enterprise routing mechanism, component communication model, and authentication boundaries,
see `design-docs/specs/design-kestra-enterprise-worker-group-mechanism.md`.

### Operational Boundaries

GitHub Actions is the default release controller. A push to `main` validates source, Terraform, and
Kubernetes manifests; builds the runtime container; pushes it to Artifact Registry; deploys live
development infrastructure; and performs HTTPS health verification. Scheduled and manually requested
batch runs reuse the same verification helper so operational behavior stays close to local scripts.

Terraform owns cloud infrastructure, DNS records, load balancing, service accounts, Secret Manager
containers and versions, Cloud SQL, GCS, GCE, GKE cluster resources, and the shared Cloud Armor
policy. Kustomize owns Kubernetes workloads under `k8s/`, with `scripts/apply-gke-dev.sh` bridging
Terraform outputs into the dev overlay. Do not hand-edit live Kubernetes resources except for
short-lived diagnostics; commit and apply manifest changes instead.

Secret values are intentionally outside source control. Local development uses non-production values
from local env files. Live GCE and GKE credentials come from Secret Manager, and the Cloudflare token
is injected through `kinko` or GitHub Actions secrets.

### OpenTelemetry On GKE

The GKE dev manifests include an in-cluster OpenTelemetry Collector. Kestra components export
traces, metrics, and logs to the collector over OTLP/gRPC at `http://otel-collector:4317`.
The collector currently uses the `debug` exporter so telemetry delivery can be audited from
collector logs without adding a vendor-specific backend.

Kestra flow tracing is enabled with `kestra.traces.root: DEFAULT`, which produces execution and task
spans. The ecommerce batch flows are intentionally split into smaller SQL tasks so the OTEL trace
timeline can identify purge, insert, aggregation, and fetch steps separately. Collector spans expose
`kestra.uid`; that value maps to Kestra execution API task-run IDs for human-readable task names.

### GCP Runtime Decision

Use GKE Autopilot as the default production-like Kestra cluster runtime, with Cloud SQL and GCS for
durable state, and use Cloud Run Jobs or the Kestra Cloud Run task runner only for selected
ephemeral task execution. Do not use Cloud Run as the default host for the full Kestra control
plane, because Kestra's scheduler, executor, webserver, indexer, and workers are long-running
components.

The detailed decision report is in
`design-docs/specs/design-kestra-gcp-runtime-decision.md`.
