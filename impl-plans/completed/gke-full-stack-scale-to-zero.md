# GKE Full-Stack Scale-To-Zero Plan

**Status**: COMPLETE
**Design Reference**: `design-docs/specs/design-gke-full-stack-scale-to-zero.md`
**Created**: 2026-07-17
**Last Updated**: 2026-07-17

## Scope

Move the GKE Kestra and batch databases from Cloud SQL to a PostgreSQL StatefulSet, route public
Kestra traffic through a resident activator, and prove ordered request-driven wake-up plus idle
scale-down to zero while retaining database data.

Cloud SQL removal is intentionally the final workstream because it is the rollback source during
cutover. This plan does not claim PostgreSQL high availability.

## Status

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Architecture | Design and runbook updates | COMPLETE | Requirements and ordering documented |
| GKE database | PostgreSQL Services, StatefulSet, PVC | COMPLETE | Kustomize render and schema tests pass |
| Activator | Public ingress and ordered scaler | COMPLETE | Generated YAML and script tests pass |
| Terraform wiring | Internal address and secrets | COMPLETE | OpenTofu validation and live no-op apply pass |
| Live migration | Automated backup and idempotent restore path | COMPLETE | Portable dumps uploaded before retirement |
| Live verification | Cold wake, idle park, second wake | COMPLETE | Run `29578095529` passed both cycles |
| Cloud SQL retirement | Remove legacy resources | COMPLETE | Legacy instance, databases, IAM, and desired-state resources removed |

## Workstreams

### 1. Architecture

**Deliverables**:
- `design-docs/specs/design-gke-full-stack-scale-to-zero.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`

**Validation**:
- Public trigger, ordered lifecycle, persistence, and cost floor are explicit.

### 2. GKE PostgreSQL

**Deliverables**:
- `k8s/base/postgres.yaml`
- GKE overlay for the internal LoadBalancer address
- Helm and runtime configuration without Cloud SQL sidecars

**Validation**:
- StatefulSet uses `standard-rwo`, one replica, and PVC retention.
- Both logical databases exist and survive a zero-to-one cycle.

### 3. Activator And Ingress

**Deliverables**:
- Ordered StatefulSet/Deployment scaling in `scripts/apply-gke-dev.sh`
- Activator BackendConfig and public Ingress routing

**Validation**:
- Health checks do not refresh activity.
- Wake order is database then application; park order is application then database.

### 4. Terraform And External Workers

**Deliverables**:
- Reserved VPC-internal PostgreSQL address
- Secret Manager JDBC URLs for GCE workers
- GCE worker startup without Cloud SQL Proxy

**Validation**:
- OpenTofu format, validation, and reviewed plan succeed.
- GCE workers reach only the internal PostgreSQL endpoint.

### 5. Live Migration And Verification

**Deliverables**:
- Cloud SQL backup/dump evidence
- Live deployment and scale transition evidence
- Persistence verifier or documented commands

**Validation**:
- Public cold access wakes the complete stack.
- Idle interval returns managed pods to zero.
- Data remains after a second wake.

### 6. Cloud SQL Retirement

**Deliverables**:
- Remove temporary Cloud SQL resources, secrets, IAM, and documentation
- Final OpenTofu apply

**Validation**:
- No GKE runtime or GCE worker references Cloud SQL.
- Live behavior remains correct after Cloud SQL deletion.

## Dependencies

- Existing GCP project, GKE cluster, DNS, Secret Manager, and Workload Identity.
- A reviewed decision on whether live Kestra history must be restored or a backup-only fresh
  cutover is acceptable.
- Public HTTPS and Kubernetes API access for live verification.

## Completion Criteria

- [x] All six workstreams are complete.
- [x] Repository CI and infrastructure rendering pass.
- [x] Live public access proves ordered zero-to-one wake-up.
- [x] Live idle state proves PostgreSQL and all managed Kestra workloads at zero.
- [x] The same PVC and database data survive a second wake-up.
- [x] Legacy Cloud SQL is backed up and retired.
- [x] Operations documentation reflects the final topology.

## Progress Log

### Session: 2026-07-17

**Completed**: Implemented and deployed the retained PostgreSQL StatefulSet, internal routing for
GCE workers, resident public activator, ordered full-stack scale-to-zero, portable backup tooling,
and Cloud SQL retirement. GitHub Actions run `29578095529` validated the repository and
infrastructure, uploaded final backups under
`gs://kestra-playground-260625-kestra-dev-storage-0fd43c76/postgres-finalization/20260717T115717Z/`,
confirmed a no-op desired-state apply, and passed two public wake cycles. Marker
`scale-zero-20260717T115941Z` survived the second wake on PVC UID
`1b67764d-7216-44c0-9722-69e2ba2811cc`.

**Blockers**: None for implementation or live automated verification. Visible Brave UI inspection
was unavailable in the final session because the required Computer Use MCP was not exposed; the
public HTTPS verifier exercised the same routed Kestra endpoint successfully.
