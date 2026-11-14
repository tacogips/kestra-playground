# GKE Full-Stack Scale-To-Zero

This design moves the GKE Kestra metadata and batch databases into GKE and coordinates their
lifecycle with the access-driven Kestra activator.

## Objective

The public Kestra HTTPS endpoint must remain reachable through a small resident activator while
the PostgreSQL pod, Kestra control-plane Deployments, and routed worker Deployments are all at zero
replicas. The first non-health-check request wakes the stack. After the configured idle window, the
stack returns to zero without deleting database storage.

## Topology

```text
Google HTTPS load balancer
  -> GKE Ingress
  -> svc/kestra-worker-activator (resident nginx + scaler)
       -> access log wakes the stack
       -> svc/kestra-webserver after warm-up

scaler wake order:
  statefulset/kestra-postgres 0 -> 1
  wait for PostgreSQL Ready
  Kestra Deployments 0 -> 1

scaler park order:
  Kestra Deployments 1 -> 0
  wait for all Kestra pods to stop
  statefulset/kestra-postgres 1 -> 0
```

PostgreSQL uses a single `postgres:16.13-alpine` replica and a `standard-rwo` 10 Gi PVC. Both
`whenScaled` and `whenDeleted` retention policies are `Retain`, so pod scale-down does not delete
the PersistentVolumeClaim. This is a development cost topology, not a highly available production
database.

The database has three Services:

- `kestra-postgres-headless` provides the stable StatefulSet network identity.
- `kestra-postgres` is the in-cluster JDBC endpoint used by Kestra pods.
- `kestra-postgres-internal` is a VPC-internal LoadBalancer with a Terraform-reserved address for
  the GCE routed-worker compatibility path.

## Access And Health Checks

When full-stack autoscaling is enabled, `scripts/apply-gke-dev.sh` patches the public Ingress to
target `kestra-worker-activator`. The activator `/health` endpoint does not write to the access log,
so Google load-balancer health checks do not keep the stack awake. User/API paths do write to the
log and trigger wake-up.

The first cold request can receive HTTP 503 with `Retry-After: 5` while PostgreSQL and the Kestra
JVMs start. Returning an explicit warming response is preferable to presenting the load balancer
with an unhealthy zero-replica backend. Clients must retry until the webserver becomes ready.

## Database Lifecycle

The PostgreSQL entrypoint initializes two logical databases on an empty PVC:

- `kestra` for the Kestra repository and queue;
- `ecommerce_ops` for the example batch data.

Credentials remain in Secret Manager and are rendered into `kestra-secrets`; no credential values
are committed. GKE pods use the ClusterIP hostname. GCE workers use the VPC-internal LoadBalancer
address stored in their Secret Manager JDBC URLs.

The Cloud SQL migration source was removed after the StatefulSet passed two cold-wake cycles with
the same PVC and persistent marker. Finalization captures PostgreSQL custom-format dumps for both
logical databases under `gs://<gke-storage-bucket>/postgres-finalization/<timestamp>/` before
Terraform deletes the legacy instance. Normal GKE applies no longer contain migration-sidecar or
Cloud SQL cutover logic.

## Failure Behavior

- PostgreSQL readiness failure prevents the scaler from starting Kestra Deployments.
- Kestra shutdown timeout prevents PostgreSQL scale-down, avoiding an intentional database stop
  while application pods still report non-zero replicas.
- The PVC remains after StatefulSet scale-down or deletion and must be removed explicitly.
- Scheduled Kestra triggers do not run while the scheduler is at zero; only public activator access
  wakes the environment.
- The resident activator, external HTTPS load balancer, internal PostgreSQL LoadBalancer, GCS
  storage, PVC, and GKE control-plane charges remain; "zero" refers to application/database pods.

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `LIVE_GKE_ROUTED_K8S_WORKER_AUTOSCALE_ENABLED` | `false` | Park routed worker Deployments |
| `LIVE_GKE_CONTROL_PLANE_AUTOSCALE_ENABLED` | `false` | Park Kestra control-plane Deployments and route Ingress through the activator |
| `LIVE_GKE_DATABASE_AUTOSCALE_ENABLED` | control-plane flag | Park `statefulset/kestra-postgres` after application shutdown |
| `LIVE_GKE_ROUTED_K8S_WORKER_IDLE_SECONDS` | `1800` | Idle interval before ordered shutdown |
| `LIVE_GKE_ROUTED_K8S_WORKER_ACTIVATOR_POLL_SECONDS` | `10` | Activator reconciliation interval |

`LIVE_GKE_DATABASE_AUTOSCALE_ENABLED=true` requires control-plane autoscaling. The routed live
entrypoint enables all three autoscaling flags.

## Verification Contract

Completion requires live evidence for all of the following:

1. Public HTTPS `/health` remains healthy while PostgreSQL and Kestra are at zero.
2. A public non-health request changes PostgreSQL from zero to one before Kestra becomes ready.
3. Kestra becomes accessible and existing database state is readable after wake-up.
4. After the idle window, all managed Deployments and PostgreSQL return to zero.
5. The PostgreSQL PVC remains Bound and the same data is readable after a second wake-up.
6. Portable dumps exist in GCS and the legacy Cloud SQL instance is absent after the proven cutover.

## References

See `design-docs/references/README.md`.
