# Design Notes

This document contains research findings, investigations, and miscellaneous design notes.

## Overview

Notable items that do not fit into architecture or client categories.

- GKE full-stack scale-to-zero uses a PostgreSQL StatefulSet rather than Cloud SQL. The StatefulSet
  can reach zero compute replicas while its `standard-rwo` PVC remains allocated and billable. The
  resident activator and load-balancer resources also remain; zero refers to Kestra and PostgreSQL
  pods, not every GCP resource.
- The legacy GKE Cloud SQL instance was removed after the live StatefulSet passed two cold-wake
  cycles. Portable finalization dumps for both logical databases are retained in the GKE storage
  bucket.

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
  `tacogips/kestra@bf0e3240580448a80c4fc4850883d88c50e484a7` and pushed to Google Artifact Registry as
  `kestra-playground/kestra-oss-worker-routing`. Do not verify that path with upstream
  `kestra/kestra:latest`: the static `kestra.worker.routing` queue/group configuration only has
  routing semantics in the forked image.
- Live GKE broadcast verification on 2026-07-15 proved execution
  `4ObzrngkaE8xk1sRJxudB2` completed on two `gke-small` pods with two worker-keyed output maps. The
  investigation also showed that Kubernetes pod readiness can precede gRPC Worker Queue
  registration and that terminating rollout pods can retain `Ready=True`. The live verifier now
  restarts the test worker Deployment, waits for each active pod's controller-connection log, and
  excludes pods with a deletion timestamp before dispatch.
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
- The remote Python batch framework was verified locally on 2026-07-13 with Kestra `1.3.24` and
  File System plugin `2.10.2`. Database export parent/runner executions
  `T3Wksz8ugIv0r7gcaGYxj` / `tROeLH4b0KcyhLQ90v9gr` and log parse executions
  `5D4NRFjQVMr8Ac98KJ6vEe` / `6XLDH659FyCySBLNKVRv1Y` completed all source-resolution, SSH,
  SFTP, execution, artifact, and cleanup stages successfully. Missing-log parent/runner executions
  `5SiYk5YQ3h5usHNaY3Wm69` / `3E4No3T5vnjjiwZSSl4bPQ` proved failure propagation and verified
  error cleanup. After every case, a direct destination-container scan found no execution
  directory below `/home/batch/kestra-runs`.
- Multi-target SSH fan-out and failed-step retry were reverified on 2026-08-17 with the then-current
  `tacogips/kestra` `main` revision `6f6012b5e0d8f302b894d465672d8dda5222515f`, reported by the
  runtime as `2.0.0-SNAPSHOT`. Local baseline `3raectlQzoNjERiZibLzFu` gave A and B one execute
  attempt each; local fault execution `79SWnUIO4RB0jup860UFP9` kept A at one and recorded failed
  plus successful execute attempts only on B. Live GCP baseline `4mt1mU5SOQhCYWgRa41jsv` gave both
  targets one execute attempt; live fault execution `20xWDrLr7mN31DYUBsDSc7` kept GCP A at one and
  recorded the execute retry only on GCP B. Each target retained one child execution and one
  prepare/stage attempt, every artifact had a SHA-256 checksum, workspaces were empty, and direct
  scans found no Kestra binary, server process, or container on either GCE target.
- The same fork revision replaces `ForEach` with the Kestra 2.0 `Loop` task and `item.value`
  context. Loop iterations are stored as internal sub-executions, so verification resolves children
  by `system.correlationId` plus `target_id` instead of relying on 1.3 nested task outputs. Its UI
  `package.json` and committed lockfile were out of sync for `@vueuse`; the repeatable build task
  falls back from `npm ci` to `npm install` inside an isolated temporary checkout and labels the
  resulting image with the resolved source SHA.
- The SSH batch business lifecycle was split into `validate_input`, `execute_batch`, and
  `validate_output` tasks and reverified on 2026-08-18. Local baseline
  `LzrjTbLWQ7cAiRNGd8y0H` had `1/1/1` attempt records for both targets; local fault execution
  `7OGX6eZNlQ17VqzQsMAjLy` kept A at `1/1/1` and recorded B at `1/3/1`. Live GCP baseline
  `2PZav3nG5psPq8bWeQmp70` and fault execution `7YfUJH9kLuJziKP0zMlg0k` produced the same result.
  The live verifier also proved no target Kestra runtime, valid artifact checksums, and empty remote
  workspace roots. After success, `kestra-remote-batch-a` and `kestra-remote-batch-b` were stopped
  and verified `TERMINATED`; their reserved external addresses still exist.
- The remote batch routed adapter was verified live against the full-parking
  `fix/gke-scale-to-zero` GKE topology on 2026-07-13. Export parent/runner executions
  `5j7sL3tbIDEc3bmqDdZbir` / `2xVMqy5OqujuXAUEFUEKDm` ran on `gke-small`; parse executions
  `2oC6pDl9NszxdB44ZrYAlZ` / `1UNLWWW8Bo7gcyw5iHujxc` ran on `gke-large`; missing-input
  executions `5ffTMRIUlLfoq7reU7z4RA` / `3gL0SlobVApt0wwzQE3Tgb` failed as intended. Each EXIT trap
  deleted and then checked the execution bundle, extracted source, uv cache, and uv-managed Python
  directory before logging `runtime_cleaned verified=true`. All six activator-managed Deployments
  returned to zero replicas.
- The custom routed worker-controller endpoint does not implement
  `NamespaceFileMetadataService/findAll`, so `namespaceFiles.include` fails on an external routed
  worker. Execution FILE inputs resolve to exact `kestra:///` objects and work with `inputFiles`;
  this is the selected no-SSH source-copy contract.
- `workerSelector.tags` is validated as a literal RFC 1123 label and cannot contain a Pebble input.
  `routed_batch_runner` therefore uses one Switch with static `gke-small` and `gke-large` cases.
  Adding a batch only selects an existing case; adding a new worker group requires one framework
  case.
- In full control-plane parking mode, a terminating webserver can briefly answer the activator root
  before the replacement JVM is stable. The live verifier keeps activator traffic alive while all
  managed Deployments become ready and retries flow registration and transient execution reads.

## Monorepo Multi-Team Release Methodology Survey

Surveyed on 2026-08-19 to validate the per-category batch group CI/CD design against industry
practice. The convergent mainstream model is: one trunk, one directory per component with
`CODEOWNERS`, automated change scoping, generated per-component tags, immutable artifacts promoted
between environments, declarative scoped deployment, and roll-forward or rollback ahead of release
branches.

The survey produced four corrections to the design. Two were substantive: the hotfix fix-direction
was backwards (fixes must originate on trunk and be cherry-picked into a release branch, not fixed
on the branch and forward-ported), and Kestra's namespace deployment deletes absent resources by
default rather than through an opt-in flag, with official `kestra-io/validate-action` and
`kestra-io/deploy-action` replacing hand-rolled `curl`.

Full survey, fit assessment, and deliberate divergences:
`design-docs/specs/design-monorepo-release-methodology-survey.md`.

## Batch Group Deploy Workflow Findings (2026-08-19)

Observations recorded while designing per-category batch group CI/CD. Both are about the repository
as it stands, not about the proposed design.

- `.github/workflows/deploy-batch-groups.yml` is stale and will fail on every run. Its `validate`,
  `deploy-ec`, and `deploy-affiliate` jobs invoke `nix develop -c task ci`,
  `nix develop -c task scripts:check`, and `nix develop -c scripts/deploy-batch-group.sh`, but commit
  `8b36cab` ("chore: migrate development workflow to mise") deleted `flake.nix`, `flake.lock`, and
  `Taskfile.yml`. That migration converted `.github/workflows/deploy.yml` to `mise run` and
  `mise exec --` but did not convert `deploy-batch-groups.yml`. The fix is the same substitution
  already applied to `deploy.yml`: replace the Nix installer step with `jdx/mise-action` and the
  `nix develop -c task ...` invocations with their `mise` equivalents.
- The repository already deploys each batch group to a separate Kestra instance. `affiliate` runs its
  own container on port 8082 with its own database and its own deploy URL, and is constrained to the
  official `kestra/kestra` distribution while the EC group may run a `tacogips/kestra` fork build.
  Both instances nonetheless share one `kestra/config/application.yaml`, one `docker-compose.yml`,
  and one deploy path, which is the concrete evidence that separate runtimes raise rather than lower
  the value of shared provisioning code.

See `design-docs/specs/design-per-category-batch-group-cicd.md` for the design these findings feed
into, including its current-implementation baseline and tag-convention decision.

## Category Controller Tag Deployment Verification (2026-08-27)

- Tag `orders-controller-v1.0.0` at commit `eacbbfb4e56eb9045ebc38a9815b2284f3bd91ce`
  triggered GitHub Actions run `33045520418`. Both `Validate Controller Release` and `Deploy
  Controller Flows Without Restart` completed successfully.
- The live deployment woke the parked GKE control plane, registered
  `playground.worker_routing.verify_gcp_category_logic_deployment`, and read the Flow back through
  the Kestra API. The before/after snapshots matched for the webserver, executor, scheduler, and
  indexer pod UIDs and restart counts and for both external GCE worker VM IDs, states, and start
  timestamps. The workflow reported `controller_restarted=false workers_restarted=false`.
- The Workload Identity provider required an explicit `orders-controller-v` release-tag prefix.
  OpenTofu applied one in-place provider-condition update with zero resources added or destroyed.
- The category-logic bundle build from the same main push succeeded after adding the missing Buildx
  setup step. Its deployment job remained queued because no online self-hosted runner with labels
  `onprem` and `category-deploy` was registered. That runner is required for worker-side Ansible
  releases but is not required for controller Flow releases, which use a GitHub-hosted runner and
  GCP OIDC.
