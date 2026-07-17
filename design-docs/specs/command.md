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
cp local/docker/.env.example local/docker/.env
cp batch-groups/ec/config/envs/local.env.example batch-groups/ec/config/envs/local.env
cp batch-groups/affiliate/config/envs/local.env.example batch-groups/affiliate/config/envs/local.env
task kestra:local:docker:start
scripts/register-flows.sh http://localhost:8080
scripts/run-flow.sh generate_ecommerce_mock_data
scripts/run-flow.sh build_ecommerce_daily_report
scripts/run-flow.sh build_ecommerce_customer_segments
task kestra:local:docker:stop
```

`local/docker/.env` contains shared PostgreSQL provisioning only. Each Kestra service receives its
runtime variables from its owning batch group under `batch-groups/<group>/config/envs/local.env`.
Both local start scripts create ignored env files from the checked-in examples when they are absent.

GCP flow deployment uses `batch-groups/<group>/config/envs/gcp.env` when present and otherwise reads
the checked-in `.example`. The file owns only non-secret routing defaults and Secret Manager name
prefixes; inject `PROJECT_ID` and `LIVE_DOMAIN_NAME` through kinko or CI:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- scripts/deploy-batch-group.sh ec
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- scripts/deploy-batch-group.sh affiliate
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
temporary manifest only, applies non-Kestra support resources with Kustomize, installs Kestra server
roles with the official Helm chart, and waits for the rendered Deployments to roll out.

By default the GKE Helm install enables split `webserver`, `scheduler`, `executor`, `indexer`, and
`worker` Deployments with a worker-only HPA. Set `GKE_WORKER_ENABLED=false` when GKE should be a
controller-only Kestra that observes and reruns executions while external GCE/on-prem workers claim
the actual work through the shared backend or federated API pattern.
The shared startup probe allows five seconds per health request and a 300-second startup window so
plugin scanning on dev-sized CPU allocations is not mistaken for a failed JVM start.

### Federated OSS Dev-As-Prod

Use the federated live path when dev should behave like the production split topology without
Kestra Enterprise Worker Groups:

- `gce-compose` is GCE worker A;
- `gce-container` is GCE worker B and is deployed with `LIVE_GCE_CLUSTER_SIZE=1` by
  `task kestra:live:deploy:federated`, giving two GCE batch hosts total;
- `k8s` is the controller Kestra only and the GKE Helm controller-only override does not release
  `kestra-worker`;
- `infra/terraform/gke-dev` creates a GCE `controller-worker` VM that runs only
  `kestra server worker` against the GKE controller backend;
- child flows from `kestra/flows` are rendered into server-specific namespaces before registration;
- `playground.ecommerce.server_gce_a` is registered on `gce-compose`;
- `playground.ecommerce.server_gce_b` is registered on `gce-container`;
- controller flows from `kestra/flows-federated` are registered only on `k8s`.
- `task kestra:live:run-federated` removes known stale ecommerce batch flows from `k8s` before
  asserting that GKE is controller-only for batch work.

Because no Kestra worker runs in GKE, controller flow execution depends on the GCE
`controller-worker` VM attached to the controller backend. That worker claims the controller
HTTP/poll/assert tasks while ecommerce batch work remains on the two GCE child Kestra targets.

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy:federated
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-federated
```

### Shared-Backend OSS Worker Routing

Use the routed live path to exercise the custom OSS Kestra image that implements config-backed
worker routing in a single shared Kestra backend:

- GKE runs the Helm-rendered `webserver`, `scheduler`, `executor`, and `indexer` roles only;
- `GKE_WORKER_ENABLED=false` adds `k8s/helm/kestra-controller-only-values.yaml`, so no
  generic `kestra-worker` Deployment or HPA is released in GKE;
- the routed live entry point routes public HTTPS and Cloud Run access through the resident
  activator, which wakes `kestra-gke-worker-small` and `kestra-gke-worker-large` from zero;
- GCE `kestra-dev-controller-worker` subscribes to the default/system queues for lightweight
  unrouted work;
- GCE `kestra-dev-gce-a` starts `kestra server worker` with `workerGroupId: gce-a`;
- GCE `kestra-dev-gce-b` starts `kestra server worker` with `workerGroupId: gce-b`;
- GCE workers dial the GKE controller gRPC endpoint through an internal LoadBalancer IP reserved by
  Terraform;
- all components use
  `${REGION}-docker.pkg.dev/${PROJECT_ID}/kestra-playground/kestra-oss-worker-routing:<tag>`
  unless `KESTRA_IMAGE` is explicitly overridden;
- GitHub Actions builds this routed image from the pinned broadcast-capable
  `tacogips/kestra@bf0e3240580448a80c4fc4850883d88c50e484a7` revision,
  installs GCS storage plus the shell, Kubernetes, and PostgreSQL JDBC runtime plugins, pushes it
  to Artifact Registry, and deploys the commit-SHA tag;
- `kestra/flows-worker-routing/verify_gcp_worker_routing.yaml` is registered on the GKE controller
  and uses `workerSelector.tags` to force one task onto `gce-a` and another onto `gce-b`;
- routed shell tasks set `taskRunner: io.kestra.plugin.core.runner.Process` so the command runs as
  a local process on the selected GCE worker container instead of requiring Docker-in-Docker or a
  mounted Docker socket;
- routed verification shell tasks set `timeout: PT2M`, and the live verifier prints periodic
  task-run summaries plus Kestra execution logs on failure or timeout.

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy:routed
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-routed
```

The verification command checks that GKE has no generic worker Deployment/pods, that all GCE worker
instances are `RUNNING`, and that the two routed tasks complete with different worker IDs. The
dedicated `gke-small` and `gke-large` workers wake for Cloud Run remote-batch requests.
`scripts/deploy-routed-live.sh` uses `ZONE` for both the OpenTofu worker placement and subsequent
instance resets; its live default is `asia-northeast1-a`. It forces
`LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true`, worker/control-plane/database autoscaling, and a
five-minute live idle window.

To prove batch-group broadcast on the routed fork, run:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch-group-broadcast
```

For a container-free local proof using a sibling `tacogips/kestra` checkout, first build that fork's
executable, then run the verifier from this repository's Nix shell (which includes Java 25):

```bash
task kestra:flows:run-batch-group-broadcast-local
```

The local verifier starts an isolated PostgreSQL instance, one standalone controller, and two worker
processes in the `broadcast-batch` worker group. Both subscribe to the `gke-small` Worker Queue. It
then registers and executes `verify_batch_group_broadcast`, requires a successful single task run,
requires exactly two worker-keyed outputs, and requires logs from `batch-worker-a` and
`batch-worker-b`. All temporary processes and data are removed afterward. Override the fork paths
with `KESTRA_SOURCE_DIR`, `KESTRA_EXECUTABLE`, or `KESTRA_PLUGIN_SOURCE_DIR` when the sibling checkout
uses a different layout.

During the live proof, the verifier temporarily scales `kestra-gke-worker-small` to two replicas,
restarts that Deployment, and waits for every active pod to log its gRPC connection to the current
controller. Kubernetes readiness alone is insufficient because a worker can become Ready before it
registers for its Worker Queue. The verifier then runs `verify_batch_group_broadcast` with an
explicit `workerSelector.broadcast: true` and requires the single visible task run to expose two
worker-keyed output maps. It also compares the batch log's `batch_group_member` values with the two
ready, non-terminating `gke-small` pods. The original replica count is restored on success or
failure. Override the test size with `BROADCAST_WORKER_REPLICAS`; it must be at least two.

### Shared-Backend OSS GKE Routed Workers

Use this path when testing the custom OSS routing fork inside Kubernetes while still letting the GKE
controller observe the whole execution in one Kestra UI/API.

- `LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true` renders two extra worker Deployments:
  `kestra-gke-worker-small` and `kestra-gke-worker-large`.
- Each worker gets a separate `workerGroupId` and queue tag: `gke-small` or `gke-large`.
- `kestra/flows-worker-routing/verify_gke_node_worker_routing.yaml` uses
  `workerSelector.tags` so each task is claimed only by its matching worker.
- The verification tasks use the Process task runner and log `POD_NAME` plus `K8S_NODE_NAME`, so
  the execution log proves where the script ran.
- For exact live-node pinning, set `LIVE_GKE_ROUTED_K8S_WORKER_*_NODE_NAME` to a current Kubernetes
  node name. This renders `spec.nodeName` on the worker pod template.
- On GKE Autopilot, `nodeSelector: kubernetes.io/hostname` is rejected by admission policy. Use
  allowed selector keys such as `topology.kubernetes.io/zone` for the autoscaling
  placement-domain test.
- `spec.nodeName` is accepted by the API, but it bypasses normal scheduling and does not trigger
  Autopilot scale-up. Live verification showed node-local `OutOfmemory`/`OutOfcpu` failures when
  the selected node did not already have free capacity. Treat `NODE_NAME` as a short-lived
  diagnostic option, not the autoscaling topology.

Example placement-domain verification that can use GKE autoscaling:

```bash
LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true \
LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_KEY=topology.kubernetes.io/zone \
LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_VALUE=asia-northeast1-c \
LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_KEY=topology.kubernetes.io/zone \
LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_VALUE=asia-northeast1-b \
scripts/apply-gke-dev.sh

task kestra:live:run-gke-node-routing
```

For exact worker-class placement with autoscaling, use a GKE Standard cluster instead of the live
Autopilot cluster. Set `gke_autopilot_enabled=false` in the `gke-dev` Terraform root so Terraform
creates autoscaled node pools labeled by worker class. Then select those node-pool labels from the
routed worker Deployments:

```bash
cd infra/terraform/gke-dev
tofu apply \
  -var='project_id=<project-id>' \
  -var='gke_autopilot_enabled=false'

LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true \
LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_KEY=kestra.tacogips.io/worker-group \
LIVE_GKE_ROUTED_K8S_WORKER_SMALL_NODE_SELECTOR_VALUE=gke-small \
LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_KEY=kestra.tacogips.io/worker-group \
LIVE_GKE_ROUTED_K8S_WORKER_LARGE_NODE_SELECTOR_VALUE=gke-large \
scripts/apply-gke-dev.sh

task kestra:live:run-gke-node-routing
```

The default Standard node-pool definitions also add a `NoSchedule` taint matching
`kestra.tacogips.io/worker-group`, and `scripts/apply-gke-dev.sh` renders a matching toleration
when a routed worker selector is configured. This matters for scale-down: an untainted worker pool
can be kept alive by GKE/GMP system pods even after the Kestra worker Deployment is deleted.

After deleting `kestra-gke-worker-small` and `kestra-gke-worker-large`, verify scale-down with:

```bash
kubectl get nodes -L kestra.tacogips.io/worker-group,cloud.google.com/gke-nodepool
```

The expected signal is the worker-class node becoming `SchedulingDisabled` and then disappearing
after the cluster autoscaler removes unused node-pool capacity.

### Routed Worker Scale-From-Zero (Activator)

Use this path to run the routed on-prem-simulation workers with access-driven autoscaling instead
of fixed replicas. HPA is intentionally not used; the mechanism is documented in
`design-docs/specs/design-gke-routed-worker-activator.md`.

```bash
LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true \
LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true \
scripts/apply-gke-dev.sh

# Access Kestra through the activator so workers wake from replicas: 0.
kubectl -n kestra-dev port-forward svc/kestra-worker-activator 8080:80

# Observe wake-up and idle reaping.
kubectl -n kestra-dev get deployment kestra-gke-worker-small kestra-gke-worker-large -w
kubectl -n kestra-dev logs deployment/kestra-worker-activator -c scaler -f
```

Tune the idle window with `LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS` (default 1800 seconds) and the
poll interval with `LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS` (default 10 seconds). When
control-plane autoscaling is enabled, the HTTPS Ingress targets the activator and public browser or
Cloud Run requests wake the stack. The activator health endpoint is excluded from activity
accounting.

For the dev-only full parking mode, add `LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true` so the
activator also parks `kestra-webserver`, `kestra-executor`, `kestra-scheduler`, and
`kestra-indexer` after the idle window and wakes them on the next activator access:

```bash
LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true \
LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true \
LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true \
LIVE_GKE_DATABASE_AUTOSCALE_ENABLED=true \
scripts/apply-gke-dev.sh
```

In this mode the scaler boots warm (everything stays up for one idle window after deploy). It wakes
`statefulset/kestra-postgres`, waits for readiness, and then wakes the Kestra Deployments. On idle
shutdown it stops the Deployments first and PostgreSQL last. The first access to a parked stack can
return HTTP 503 with `Retry-After: 5` until the webserver JVM boots; schedule triggers do not fire
while parked. The retained PVC survives PostgreSQL scale-to-zero. See
`design-docs/specs/design-gke-full-stack-scale-to-zero.md`.

Observe the full lifecycle with:

```bash
kubectl -n kestra-dev get statefulset/kestra-postgres \
  deployment/kestra-webserver deployment/kestra-executor \
  deployment/kestra-scheduler deployment/kestra-indexer \
  deployment/kestra-gke-worker-small deployment/kestra-gke-worker-large -w
kubectl -n kestra-dev get pvc data-kestra-postgres-0
kubectl -n kestra-dev logs deployment/kestra-worker-activator -c scaler -f
```

Before the first Cloud SQL-to-StatefulSet cutover, create and verify an on-demand source backup:

```bash
gcloud sql backups create \
  --project "${PROJECT_ID}" \
  --instance kestra-dev-postgres \
  --description pre-gke-postgres-cutover
gcloud sql backups list \
  --project "${PROJECT_ID}" \
  --instance kestra-dev-postgres \
  --limit 5
```

Do not remove the legacy Cloud SQL Terraform resources until the backup reports `SUCCESS` and the
StatefulSet has passed two wake cycles with retained data. Run the end-to-end verifier with:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- \
  task kestra:live:verify-gke-full-stack-scale-to-zero
```

On the first deployment, `scripts/apply-gke-dev.sh` detects missing migration markers, creates the
Cloud SQL backup, scales existing GKE Kestra Deployments to zero, stops running GCE workers, and
runs `kestra-postgres-cloud-sql-migration`. The Job uses Cloud SQL Auth Proxy as a native sidecar,
restores only empty destination databases, and records `_gke_cloud_sql_migration` in both logical
databases. Subsequent deploys see both markers and skip the cutover. A failed migration
intentionally leaves writers stopped for investigation instead of restarting them against a
partial database.

### OSS K8s Per-Batch Pod Resources

Use `kestra/flows-k8s-pod-resources/verify_k8s_pod_resources.yaml` when the goal is different
resource sizes per batch, not deterministic worker placement.

- Kestra runs on GKE with a normal worker enabled.
- Each batch task is `io.kestra.plugin.kubernetes.core.PodCreate`.
- Each task defines its own Kubernetes pod `resources.requests` and `resources.limits`.
- The flow does not set `nodeSelector`, so GKE schedules pods and autoscaling responds to resource
  requests.
- Verification pods are labeled with the Kestra execution ID and resource class; the verifier reads
  the created pod specs with `kubectl`, checks CPU/memory values, then deletes the verification
  pods.
- `k8s/base/kestra-podcreate-rbac.yaml` grants the Kestra service account pod create/delete/watch
  and pod log read permissions in the namespace.
- The routed custom image build also installs `io.kestra.plugin:plugin-kubernetes:1.9.5` so this
  topology can be tested on the same runtime family when needed.

Example resource split:

```yaml
tasks:
  - id: batch_1_small_pod
    type: io.kestra.plugin.kubernetes.core.PodCreate
    spec:
      containers:
        - name: main
          resources:
            requests:
              cpu: "500m"
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
  - id: batch_2_large_pod
    type: io.kestra.plugin.kubernetes.core.PodCreate
    spec:
      containers:
        - name: main
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
```

### Operation Demo: Same Batch Source Across Local, GKE, And Routed Workers

Use this path to model the requested development operation for a newly added batch:

1. Add the batch implementation once under `batches/<batch-name>/`.
2. Unit-check that source locally.
3. Register and run a local Kestra wrapper from `kestra/flows-operation-demo/local`.
4. Promote the same source to staging by registering either:
   - `kestra/flows-operation-demo/gke-pod-resources` for OSS GKE PodCreate with per-batch
     vCPU/memory; or
   - `kestra/flows-operation-demo/routed-worker` for the custom OSS GCE/on-prem-style routed
     worker topology.

The current concrete example is:

```text
batches/resource_probe/run.sh
kestra/flows-operation-demo/local/resource_probe_local.yaml
kestra/flows-operation-demo/gke-pod-resources/resource_probe_gke_pod_resources.yaml
kestra/flows-operation-demo/routed-worker/resource_probe_routed_workers.yaml
```

Local verification:

```bash
task kestra:local:docker:start
task kestra:flows:run-operation-demo-local
task kestra:local:docker:stop
```

GKE PodCreate staging verification, after deploying the normal GKE Kestra worker:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-operation-demo-gke-pod-resources
```

This verifier starts the Kestra execution, waits for both labeled child pods to be created, checks
their Kubernetes `resources.requests` and `resources.limits` directly with `kubectl`, then waits for
Kestra execution state and prints task/log diagnostics. The flow runs both PodCreate tasks through a
`Parallel` wrapper and sets `SLEEP_SECONDS=45` so both resource-class pods are inspectable before
PodCreate cleanup.

This topology requires a normal GKE Kestra worker. A controller-only GKE deployment is suitable for
the federated GCE/on-prem controller pattern, but it cannot reliably execute OSS `PodCreate` control
tasks because no worker is present to claim and finalize those tasks.

Routed GCE/on-prem-style staging verification, after deploying the custom routed topology:

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-operation-demo-routed
```

For the live dev quota shape, the routed operation demo can be deployed with only the two routed
workers because both demo tasks are explicitly tagged `gce-a` or `gce-b`:

```bash
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
LIVE_GKE_CONTROLLER_WORKER_ENABLED=false \
KESTRA_IMAGE="<artifact-registry>/kestra-oss-worker-routing:<operation-demo-tag>" \
task kestra:live:deploy:routed
```

This keeps GKE controller-only: `webserver`, `scheduler`, `executor`, and `indexer` run in GKE, and
the script tasks run on GCE workers. The live 2026-06-30 verification used execution
`6zPZucUaVSEizIGE0dnv7N` and asserted `hostname=kestra-dev-gce-a` / `worker_group=gce-a` for the
first task and `hostname=kestra-dev-gce-b` / `worker_group=gce-b` for the second task.

GitHub Actions can run the same operation demo after deployment through `workflow_dispatch` by
setting `operation_demo` to `gke-pod-resources` or `routed-workers`.

The file-level config delta is intentionally small:

| Promotion path | Batch source change | Kestra wrapper change |
|----------------|---------------------|------------------------|
| Local to GKE PodCreate | None | Process command becomes PodCreate; pod image and resources are added. |
| Local to GCE/on-prem routed worker | None | Process command stays; `workerSelector.tags` chooses the worker group. |
| Local to local/staging split | None | Register a different flow directory for the environment. |

Operational caveat: live testing on the current GKE/Kestra 2.0 snapshot image observed a Fabric8
Kubernetes client final GET timeout after a child pod had already reached `Succeeded` when
`delete: false` was used. The operation-demo GKE flow therefore lets PodCreate clean up pods and the
verifier captures pod resource evidence before final task cleanup.

### Remote Python Batch Examples Over SSH/SFTP

Use this path when Kestra must copy a Python program onto an SSH-accessible machine for each
execution, run it there, and collect the result into Kestra internal storage.

```bash
task kestra:local:docker:start
task kestra:flows:run-remote-batch-examples
task kestra:local:docker:stop
```

The verification registers `kestra/flows-remote-batch`, uploads the two Python programs as
Namespace Files, executes the database export and log parser, then runs the parser with a missing
remote input. It asserts:

- Namespace File resolution and SFTP source staging;
- all success-path SSH/SFTP task states;
- controller-visible remote progress logs and structured variables;
- internal-storage artifact URIs and SHA-256 checksums;
- non-zero remote exit propagation to the runner and caller flows;
- success/error cleanup markers emitted only after the execution directory is absent;
- a direct destination-container scan showing no execution directories after every case.

Worker connection defaults come from `ENV_REMOTE_BATCH_HOST` and
`ENV_REMOTE_BATCH_USERNAME`. The password is read through `secret('REMOTE_BATCH_PASSWORD')`; OSS
deployments provide the base64-encoded value as `SECRET_REMOTE_BATCH_PASSWORD`.

For a new batch, upload a standalone Python source into the `playground.remote_batch` namespace and
create a one-task caller flow that invokes `remote_batch_runner` with `script_name`, `config_json`,
`output_file`, and worker coordinates. Do not repeat SSH, SFTP, cleanup, or error handling in the
caller.

### Remote Python Batch On Scale-From-Zero Routed Workers

Use this path for the `fix/gke-scale-to-zero` GKE/on-prem simulation. It requires that topology's
routed worker and activator resources, but does not require `sshd` or SFTP on the worker pod. The
verifier accesses Kestra through `svc/kestra-worker-activator`, so the first request wakes the cold
control plane and `gke-small`/`gke-large` workers.

```bash
nix develop -c task kestra:live:run-remote-batch-routed
```

The command confirms the zero-replica baseline, waits through cold start, registers flows, builds
and uploads an execution FILE bundle per run, runs SQLite export on `gke-small`, runs JSONL parsing
on `gke-large`, verifies an intentional Python failure, and confirms the activator-managed
Deployments return to zero. It checks
worker identity, progress logs, structured variables, artifacts, checksums, parent/child state, and
the success/failure `runtime_cleaned verified=true` signal emitted only after the localized bundle,
source, uv cache, and uv-managed Python directory have each been checked as absent.

The caller supplies only `batch_bundle`, `source_root`, `script_name`, business `config_json`,
`output_file`, and `worker_group`. `routed_batch_runner` owns localization, uv/Python invocation,
artifact persistence, checksum emission, cleanup, and worker selection.

Live GKE image caveat: the current shared-backend GKE deployment uses the custom
`kestra-oss-worker-routing` image and database schema. Do not replace the GKE webserver, scheduler,
executor, indexer, or worker Deployments with upstream `kestra/kestra:v1.3.x` against the existing
database; live testing found the upstream queue migration expects a `queue_type` enum while the
custom fork schema stores queue event names as text. The PodCreate child batch image is separate and
may still use the operation-demo runtime image through `ENV_RUNTIME_IMAGE`.

### Live Operations

```bash
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy:federated
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME,CLOUDFLARE_ZONE_ID,TOFU_STATE_BUCKET,CLOUDFLARE_API_TOKEN -- task kestra:live:deploy:routed
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:verify
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-batch
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-federated
kinko exec --env PROJECT_ID,LIVE_DOMAIN_NAME -- task kestra:live:run-routed
```

Direct batch execution is disabled for `TARGET_ENVIRONMENT=k8s`; use
`task kestra:live:run-federated` for the GKE controller path.

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

### Local To Staging/Production Promotion Checklist

Use this checklist when the goal is smooth movement from local development to staging or
production-like release:

1. Keep business logic in one source boundary. Put reusable batch implementation under
   `batches/<batch-name>/`, `src/`, or checked-in SQL fixtures instead of copying logic into
   environment-specific flow files.
2. Keep Kestra YAML changes environment-scoped. Local wrappers may use a Process task, GKE
   resource-sizing wrappers may use PodCreate, and routed-worker wrappers may add
   `workerSelector.tags`; the business command and inputs should remain the same.
3. Prove local behavior first with `task ci` plus the relevant local flow verifier, such as
   `task kestra:flows:run-operation-demo-local` for operation-demo work.
4. Promote through one image artifact. GitHub Actions publishes a commit-SHA tag and `latest`, but
   deploys should use the SHA-tagged image through `KESTRA_IMAGE` so rollback and audit are
   deterministic.
5. Use the same deploy and verify scripts locally and in CI. Manual live operations should call the
   `task kestra:live:*` commands through `kinko`; GitHub Actions calls the same underlying scripts.
6. Verify the topology that matches the release question:
   - use `task kestra:live:run-operation-demo-gke-pod-resources` when staging must prove per-batch
     Kubernetes CPU/memory requests and limits;
   - use `task kestra:live:run-operation-demo-routed` when staging must prove selected
     GCE/on-prem-style worker placement;
   - use `task kestra:live:run-federated` when production-like control-plane orchestration should
     stay on GKE while batch execution stays on GCE child Kestra targets.
7. Treat GKE-only staging as a contract test unless it runs the same execution topology as
   production. If production depends on GCE or on-prem-style routed workers, staging must exercise
   that routed or federated path before release.

The important invariant is not identical YAML in every environment. The invariant is one business
source, one released runtime image, the same inputs and business date behavior, and explicit
environment wrappers only where the runtime substrate requires them.

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

Run the federated controller after the collector is ready, then inspect collector logs for spans from
the GKE Kestra control component services and execution IDs:

```bash
BUSINESS_DATE=2026-06-25 task kestra:live:run-federated
kubectl -n kestra-dev logs deployment/otel-collector --since=10m | \
  rg 'kestra.executionId|generate_ecommerce_mock_data|build_ecommerce_daily_report|build_ecommerce_customer_segments'
```

Expected GKE service names include `kestra-webserver`, `kestra-executor`, `kestra-scheduler`, and
`kestra-indexer`. `kestra-worker` should not appear as a GKE Deployment, HPA, or service name in
this topology.

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

Verify Secret Manager versions are enabled without printing secret payloads. For GKE, the database
and storage runtime values are under the same `kestra-dev-gke-*` prefix as Basic Auth:

```bash
for secret in \
  kestra-dev-kestra-basic-auth-username \
  kestra-dev-kestra-basic-auth-password \
  kestra-cluster-dev-kestra-basic-auth-username \
  kestra-cluster-dev-kestra-basic-auth-password \
  kestra-dev-gke-kestra-basic-auth-username \
  kestra-dev-gke-kestra-basic-auth-password \
  kestra-dev-gke-kestra-db-url \
  kestra-dev-gke-kestra-db-username \
  kestra-dev-gke-kestra-db-password \
  kestra-dev-gke-batch-db-url \
  kestra-dev-gke-batch-db-username \
  kestra-dev-gke-batch-db-password \
  kestra-dev-gke-kestra-gcs-bucket; do
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
