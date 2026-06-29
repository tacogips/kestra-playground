# Kestra GCP Runtime Decision

Decision report for choosing the GCP runtime shape for a cost-conscious Kestra deployment.

## Overview

Kestra should run its control plane on GKE Autopilot for a production-like cluster, while bursty or
infrequent task execution should be offloaded to Cloud Run Jobs or the Kestra Cloud Run task runner
when the task type supports it.

Cloud Run is not the preferred host for the full Kestra cluster. It is better treated as an
ephemeral execution backend for selected tasks. Kestra has long-running control-plane components,
including webserver, scheduler, executor, indexer, and workers. Those components fit Kubernetes
Deployments more naturally than request-driven Cloud Run services.

## Decision

Use this default runtime model:

1. Run the Kestra control plane on GKE Autopilot with Cloud SQL for PostgreSQL and GCS for internal
   storage.
2. Keep control-plane resource requests small and explicit so Autopilot bills only the resources
   that the running pods request.
3. Scale non-production Kestra Deployments to zero outside active use windows when schedules do not
   need to fire.
4. Use Cloud Run Jobs or the Kestra Cloud Run task runner for intermittent script or containerized
   batch tasks where startup latency is acceptable.
5. For the lowest-cost development target, keep the single-VM GCE deployment available as a simpler
   alternative when high availability and Kubernetes behavior are not being evaluated.

## Rationale

Kestra's own Kubernetes guidance recommends separate component pods for production deployments to
improve scalability and resource isolation. This matches the repository's GKE shape: the official
Kestra Helm chart manages separate Kestra server roles, Kustomize manages supporting Kubernetes
resources, and Terraform manages GKE, Cloud SQL, GCS, IAM, load balancing, DNS, and Cloud Armor.

GKE Autopilot minimizes idle node cost better than GKE Standard because Google manages node
provisioning and bills general-purpose Autopilot workloads primarily by requested pod resources.
Autopilot clusters can also scale down to zero usable nodes when no user workloads are running.
This reduces wasted compute for dev or scheduled environments.

The important caveat is that a running Kestra cluster is not idle from Autopilot's perspective. If
webserver, scheduler, executor, worker, indexer, sidecars, and telemetry collectors remain running,
Autopilot keeps capacity for those pods and bills their requested resources. Real idle savings
therefore require scaling those workloads down or deleting/suspending the environment.

Cloud Run is cost-effective for intermittent execution because services and jobs can be billed only
while instances are starting, stopping, or processing work, depending on billing mode. However,
Kestra's scheduler and workers are long-running processes. Running the full control plane on Cloud
Run would either fight the platform model or require always-on service behavior, which removes much
of Cloud Run's cost advantage.

## Option Comparison

| Option | Fit for Kestra control plane | Idle cost behavior | Operational notes |
|--------|------------------------------|--------------------|-------------------|
| GKE Autopilot | Strong | Can scale nodes to zero only when user workloads are gone | Best production-like fit; requires Kubernetes operations and Cloud SQL/GCS |
| Cloud Run Services | Weak | Very low for request-driven services, poor for always-on schedulers | Request/service model does not fit the full Kestra cluster well |
| Cloud Run Jobs | Not a control-plane host | Very low for intermittent jobs | Good execution backend for batch tasks, not for managing Kestra itself |
| Single GCE VM | Moderate for dev/small use | VM cost continues while running | Lowest operational complexity; weaker HA and scaling story |
| GCE multi-VM cluster | Moderate | VM cost continues while running | Useful comparison target, but less managed than GKE Autopilot |

## Cost Guidance

Use GKE Autopilot when the goal is to validate or operate a real Kestra cluster. It has a cluster
management fee, but Google Cloud's GKE free tier can offset roughly one Autopilot or zonal cluster's
monthly management fee. Application compute still depends on the requested CPU, memory, and
ephemeral storage of running pods.

The main non-compute cost driver is likely Cloud SQL, because Kestra requires a durable repository
database and this repository's GKE design also uses PostgreSQL for the ecommerce batch workload. For
development environments, stop Cloud SQL when the environment is not needed, if the operational
workflow can tolerate startup delay and unavailable schedules.

For a cost-conscious non-production environment:

1. Keep GKE Autopilot cluster resources small.
2. Use minimum viable pod requests for Kestra components.
3. Disable or scale down optional components such as the OTEL collector when not evaluating
   telemetry.
4. Scale Kestra Deployments to zero outside active windows.
5. Stop Cloud SQL outside active windows.
6. Prefer Cloud Run Jobs for infrequent heavy task execution instead of keeping large worker pods
   warm.

For production:

1. Keep at least the scheduler, executor, webserver, and required workers running.
2. Use horizontal scaling for worker capacity instead of overprovisioning fixed replicas.
3. Use task runners for bursty workloads where task startup latency is acceptable.
4. Treat scale-to-zero of the control plane as a non-production optimization unless schedules and
   event triggers are intentionally suspended.

## Recommended Architecture

The recommended GCP architecture is:

- GKE Autopilot for Kestra webserver, scheduler, executor, indexer, and worker Deployments.
- Cloud SQL for Kestra repository and queue state.
- GCS for Kestra internal storage.
- Secret Manager plus Workload Identity for sensitive configuration.
- Google HTTPS load balancing, managed certificates, Cloud Armor, and DNS for UI/API ingress.
- Cloud Run Jobs or Kestra Cloud Run task runner for selected bursty scripts and container tasks.

This keeps the orchestration control plane stable while allowing task execution to become more
pay-per-use.

## Non-Goals

- Do not run the full Kestra control plane on Cloud Run as the default design.
- Do not rely on Autopilot scale-to-zero while Kestra schedules must continue firing.
- Do not optimize only for the cluster management fee; Cloud SQL, load balancing, logging, and
  storage must be included in actual cost review.

## Open Questions

- What is the expected monthly schedule density for production workloads?
- How much startup latency is acceptable for batch task execution?
- Which task types must run on always-on Kestra workers because task runners do not support them?
- Should development environments be automatically suspended on a daily schedule?

## References

See `design-docs/references/README.md`.
