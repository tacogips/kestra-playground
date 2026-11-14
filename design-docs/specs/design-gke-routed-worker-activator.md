# GKE Routed Worker Activator (Scale-From-Zero)

This document describes the access-driven autoscaling model for the GKE-hosted routed workers that
simulate the on-prem worker topology (`kestra-gke-worker-small` and `kestra-gke-worker-large`).

## Overview

The routed workers pin one worker Deployment to one `workerGroupId` queue, reproducing the
"one machine = one worker" on-prem model. That model intentionally forbids
HorizontalPodAutoscaler-style replica scaling: a second replica of the same group would compete for
the same queue and break deterministic placement.

The autoscaling that is compatible with this model is therefore not horizontal replica scaling but
scale-from-zero / scale-to-zero of the whole fixed worker set:

- each routed worker Deployment idles at `replicas: 0`;
- a resident activator wakes all routed workers to `replicas: 1` on the first user access;
- an idle reaper returns them to `replicas: 0` after a configurable idle window;
- the worker-only mode leaves the control plane and PostgreSQL resident.

## Trigger Model

The wake trigger is user access, not control-plane startup. The control plane never launches
workers by itself; deploying or restarting the control plane leaves the routed workers at
`replicas: 0` until traffic arrives at the activator.

```text
user
  -> svc/kestra-worker-activator (resident nginx reverse proxy)
  -> nginx appends to shared access.log
  -> scaler sidecar polls access.log size
  -> on change from cold: PATCH deployments/scale replicas=1 for all routed workers
  -> woken worker opens outbound gRPC to kestra-controller-grpc and consumes its queue
  -> no access for IDLE_SECONDS: PATCH replicas=0 (idle reaper)
```

## Components

All resources are rendered by `render_routed_worker_activator` in `scripts/apply-gke-dev.sh` when
`LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true` (and routed K8s workers are enabled):

| Resource | Purpose |
|----------|---------|
| ConfigMap `kestra-worker-activator` | `nginx.conf` and the `activator.sh` scaler loop |
| Deployment `kestra-worker-activator` | nginx container plus `curlimages/curl` scaler sidecar sharing an `emptyDir` access log |
| Service `kestra-worker-activator` | ClusterIP entrypoint users port-forward to instead of the webserver |
| ServiceAccount/Role/RoleBinding `kestra-worker-activator` | `get`/`patch` on `deployments/scale`, restricted by `resourceNames` to the two routed worker Deployments |

The scaler sidecar does not use kubectl. It calls the Kubernetes scale subresource directly with
curl, a merge patch, and the mounted ServiceAccount token, so no kubectl image dependency is
needed.

## Behavior Details

- The scaler treats any access-log size change as activity and refreshes the idle deadline.
- Scaling is a state transition, not a per-request call: the scaler patches only when the desired
  replica count changes between 0 and 1.
- In the worker-only mode the scaler boots cold: the idle deadline is initialized as already
  expired and the first reconcile patches workers to 0. A restart of the activator while workers
  are awake parks them until the next access. (The control-plane mode below boots warm instead.)
- Re-running `scripts/apply-gke-dev.sh` with autoscale enabled re-applies `replicas: 0`, so a
  deploy also resets workers to cold.
- Kestra queue semantics make the cold window safe for API-triggered executions: tasks dispatched
  with `workerSelector.tags` wait in their routing queue until the woken worker subscribes through
  the WorkerController. Executions triggered without any activator access (for example a schedule
  trigger firing while everything is idle) do not wake workers and wait until the next access.

## Control-Plane And Database Autoscale Mode

`LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED=true` extends the same activator to the control plane:
`kestra-webserver`, `kestra-executor`, `kestra-scheduler`, and `kestra-indexer` join the scaled
deployment set and the Role's `resourceNames`. This is a dev-environment cost mode that accepts
cold-start latency.

Differences from the worker-only mode:

- The scaler boots `warm` instead of `cold`: after a deploy (or an activator restart) everything
  stays up for one full idle window before parking. This keeps the deploy pipeline's rollout waits
  and HTTPS health verification working, and matches "control plane up brings workers up" right
  after a deploy.
- While parked, the first access through the activator returns HTTP 503 from nginx until the webserver
  JVM boots (roughly 1-3 minutes, plus possible Autopilot node scale-up). The access is still
  logged, so the wake-up proceeds; the user retries or the UI reloads.
- The `kestra-controller-grpc` Service selects the webserver pods, so parking the webserver also
  removes the worker-controller gRPC endpoint. On wake, all deployments scale together and workers
  retry their outbound gRPC connect until the webserver answers.
- While parked, the scheduler does not fire schedule triggers. The HTTPS Ingress targets the
  activator, whose `/health` endpoint stays healthy without refreshing the idle timer.
- `LIVE_GKE_DATABASE_AUTOSCALE_ENABLED=true` wakes the PostgreSQL StatefulSet before the Kestra
  Deployments and parks it only after the Deployments stop. The database PVC, GCS, activator,
  load balancers, and cluster control plane remain billable.

The flag requires `LIVE_GKE_ROUTED_K8S_WORKERS_ENABLED=true` and
`LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED=true`; `scripts/apply-gke-dev.sh` exits with an error
otherwise.

## Configuration

| Environment variable | Default | Meaning |
|----------------------|---------|---------|
| `LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED` | `false` | Render workers at `replicas: 0` and deploy the activator |
| `LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS` | `1800` | Idle window before the reaper scales the managed set back to 0 |
| `LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS` | `10` | Access-log poll interval |
| `LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED` | `false` | Also park/wake the control plane deployments (warm boot) |
| `LIVE_GKE_DATABASE_AUTOSCALE_ENABLED` | control-plane flag | Also park/wake PostgreSQL in dependency order |

Access path while autoscale is enabled:

```bash
kubectl -n kestra-dev port-forward svc/kestra-worker-activator 8080:80
```

With control-plane autoscaling enabled, the HTTPS Ingress points at `kestra-worker-activator` and
uses its dedicated BackendConfig health check. See
`design-docs/specs/design-gke-full-stack-scale-to-zero.md` for the complete public-access and
PostgreSQL lifecycle.

## Cost Shape

With full-stack autoscale enabled and no traffic, routed workers, Kestra control-plane pods, and
the PostgreSQL pod disappear. The retained PVC, activator, OTEL collector, load balancers, GCS, and
GKE control plane remain.

## References

- `design-docs/specs/design-onprem-worker-model.md`
- `design-docs/specs/design-oss-worker-routing-sequence.md`
- `scripts/apply-gke-dev.sh`
