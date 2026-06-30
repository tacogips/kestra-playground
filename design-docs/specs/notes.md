# Design Notes

This document contains research findings, investigations, and miscellaneous design notes.

## Overview

Notable items that do not fit into architecture or client categories.

---

## Sections

(Add design notes sections below)

---

## Kestra Deployment Notes

- Kestra's Docker Compose documentation shows standalone mode backed by PostgreSQL and a
  config-file option mounted into `/etc/config/application.yaml`.
- Kestra can run individual server components with `kestra server webserver`, `executor`, `worker`,
  `scheduler`, and `indexer`; the GCE cluster and GKE manifests use that component split.
- The local Apple container path uses explicit `container run` commands because Apple container does
  not provide a native Compose feature in the official command reference.
- The Terraform roots are intentionally separate:
  - `bootstrap-project` creates a new GCP project and enables services.
  - `gce-single` deploys the non-clustered VM shape.
  - `gce-cluster` deploys multi-VM Kestra components.
  - `gke-dev` deploys GKE Autopilot and managed backing services.
- Cloud resources default to dev-sized settings and `deletion_protection = false`; production
  evaluation must revisit availability, backups, IAM boundaries, ingress authentication, TLS, and
  persistent state retention.
- HTTPS/domain support is optional and parameterized by `domain_name`. If Terraform creates a new
  Cloud DNS managed zone, the registrar or parent zone still needs NS delegation to the output name
  servers before Google-managed certificates can become active.
- The live development domain path uses Cloudflare DNS values injected from `kinko` or CI
  secrets/variables. Do not commit real project, domain, Cloudflare zone, or state bucket values.
- Live HTTPS targets use one shared Cloud Armor policy for rate limiting. Keep one policy unless
  environment-specific thresholds are needed, because duplicated policies add avoidable monthly
  fixed cost.
- Scheduled and default helper-script batch runs use the current date in `Asia/Tokyo`. Historical
  replays should pass `BUSINESS_DATE=YYYY-MM-DD` explicitly; invalid date strings fail before a
  Kestra execution is created.
- `task kestra:live:verify` is a health and flow-registration check only. Use
  `task kestra:live:run-batch` when the deployment must prove the ecommerce batch can write and read
  the business database.
- UI verification is separate from API verification. When the user asks to touch the live Kestra UI,
  use Brave Browser through Computer Use, avoid printing secret values, and verify each public
  subdomain independently.
- The GKE secret render path is intentionally temporary-file based. If that helper fails, inspect the
  temporary render and Kubernetes Secret key set, but do not commit rendered secret manifests.
- GKE OTEL currently exports to the in-cluster collector's `debug` exporter. This proves Kestra can
  emit and the cluster can receive OTLP telemetry; add a vendor-specific exporter later when a
  durable observability backend is chosen.
- The active OSS hybrid shape is federated Kestra, not Worker Groups and not the DB-backed external
  agent. `gce-compose` and `gce-container` are the two sticky GCE batch targets. `k8s` is the GKE
  controller target and registers only the controller flow. The GKE controller flow calls GCE child
  Kestra APIs and waits for child execution state. This keeps local/staging and production workflow
  contracts closer than the DB-backed agent wrapper.
- The shared-backend routed GCP path uses the custom image built from
  `tacogips/kestra@feature/oss-worker-routing` and pushed to Google Artifact Registry as
  `kestra-playground/kestra-oss-worker-routing`. Do not verify that path with upstream
  `kestra/kestra:latest`: the static `kestra.worker.routing` queue/group configuration only has
  routing semantics in the forked image.
- The GKE routed-worker verification has two separate placement facts:
  - `workerSelector.tags` plus the custom routing fork correctly routes tasks to the matching
    always-on worker Deployment. Live execution `7ZIs6V4XlUZWS1ztUAQzlT` proved `gke-small` and
    `gke-large` tasks were claimed by different worker pods and logged their Kubernetes node names.
  - On the current GKE Autopilot cluster, exact hostname placement is not the autoscaling design.
    `nodeSelector: kubernetes.io/hostname` is rejected by Autopilot admission. `spec.nodeName` is
    accepted by the API, but it bypasses the scheduler, does not trigger Autopilot scale-up, and
    live tests failed with node-local `OutOfmemory` or `OutOfcpu` when the chosen node lacked free
    capacity. Use allowed placement labels such as `topology.kubernetes.io/zone` for the
    Autopilot-compatible routed-worker test.
- Autoscale cleanup was observed after deleting temporary routed workers: the former large-worker
  node changed to `Ready,SchedulingDisabled`, and later unused nodes disappeared from
  `kubectl get nodes`. This proves cleanup of unused Autopilot capacity for the placement-domain
  worker test, not exact node-name autoscaling.
- Exact worker-to-node-style routing with autoscaling should be modeled as a GKE Standard topology:
  create labeled node pools per worker class, let the cluster autoscaler manage node count, and
  render routed worker Deployments with node selectors or required affinity for the node pool/class
  labels. Worker pools should also be tainted and routed workers should tolerate the matching taint;
  otherwise GKE/GMP system pods can occupy an otherwise unused worker node and delay autoscaler
  cleanup. Avoid `spec.nodeName` for autoscaled workloads because it pins to an ephemeral node object
  that may disappear after scale-down.
- The GKE Terraform root has a variable-gated implementation of that Standard topology:
  `gke_autopilot_enabled=false` creates autoscaled `gke_standard_node_pools` with worker-class
  labels and worker-group taints.
- A temporary GKE Standard cluster (`kestra-std-route-vfy`, later deleted) verified the Standard
  topology end to end. The `gke-small` task ran in
  `kestra-gke-worker-small-f8bc4f74f-9rgdk` on node
  `gke-kestra-std-route-vfy-kestra-small-ea37409c-4hq4`, and the `gke-large` task ran in
  `kestra-gke-worker-large-544f45f877-gh6cl` on node
  `gke-kestra-std-route-vfy-default-pool-fc568772-r49n`. The execution
  `5wLyIdzUikEaUWtNKycWQx` finished `SUCCESS`.
- The same temporary cluster showed why worker-pool taints matter. An untainted worker pool stayed
  alive because GKE/GMP system pods occupied the node. After recreating the small worker pool with a
  worker-group `NoSchedule` taint and a matching worker toleration, the worker pod triggered
  scale-up from 0 to 1 and, after deleting the worker Deployment, the node was marked
  `Ready,SchedulingDisabled` with the `DeletionCandidateOfClusterAutoscaler` taint.
- The DB-backed external agent and Enterprise Worker Group approaches remain documented in
  `design-docs/specs/design-kestra-enterprise-worker-group-mechanism.md` as design alternatives,
  but their runtime source has been removed.
- The GKE operation-demo PodCreate resource test produced live Kubernetes and Kestra evidence on
  2026-06-30 with execution `RtQuw62twarib4dJ0a3wP`: the small child pod used `500m` CPU /
  `512Mi` memory requests and `1` CPU / `1Gi` limits, while the large child pod used `2` CPU /
  `4Gi` memory requests and `4` CPU / `8Gi` limits. The Kestra task summary reported `SUCCESS` for
  the Parallel wrapper and both PodCreate tasks. This proves per-batch pod resource sizing without
  node pinning against the deployed GKE Kestra endpoint.
- OSS PodCreate requires a GKE worker to claim and finalize the PodCreate control tasks. A GKE
  controller-only deployment remains valid for the federated GCE/on-prem controller pattern, but it
  is not the right live shape for the PodCreate resource-sizing topology.
- The worker-enabled GKE topology needs more DB connection headroom than the controller-only path.
  With `KESTRA_DB_MAX_POOL_SIZE=2`, the executor hit Hikari connection timeouts while consuming
  queue messages after the worker was enabled. The Helm value now sets the common GKE pool size to
  `4`; the final verification ran after all webserver, executor, scheduler, indexer, and worker
  Deployments were available.
- The routed GCE/on-prem-style operation-demo image was built and pushed to Artifact Registry as a
  thin derivative of the verified custom routing image with `batches/resource_probe` included:
  `kestra-oss-worker-routing:operation-demo-routed-53f6458-20260630081041`.
  Live execution `6zPZucUaVSEizIGE0dnv7N` verified the routed path on 2026-06-30 with no
  `kestra-worker` deployment in GKE. `batch_1_on_gce_a` logged `hostname=kestra-dev-gce-a` and
  `worker_group=gce-a`; `batch_2_on_gce_b` logged `hostname=kestra-dev-gce-b` and
  `worker_group=gce-b`.
- The live routed verification required two operational workarounds in the current dev project:
  Terraform was run with `GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"` to avoid a
  stale ADC `invalid_rapt` refresh, and the unrelated `kestra-cluster-dev-mig` was temporarily
  resized from 2 to 1 because `asia-northeast1` was at the regional `IN_USE_ADDRESSES` quota. This
  is an environment quota constraint, not a source-layout requirement.
- The live GKE shared backend is tied to the custom `kestra-oss-worker-routing` image schema. An
  upstream `kestra/kestra:v1.3.15` server-role rollout failed against the existing Cloud SQL database
  because the upstream queue migration expected a `queue_type` enum, while the live `queues.type`
  column is text with custom event-name values. Keep server roles on the compatible custom image
  unless the database is rebuilt or explicitly migrated.
