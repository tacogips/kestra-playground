# Category Namespace Reconciliation Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-onprem-category-logic-deployment.md#category-namespace-reconciliation-contract`
**Created**: 2026-08-27
**Last Updated**: 2026-08-27

---

## Design Document Reference

**Source**: `design-docs/specs/design-onprem-category-logic-deployment.md`

### Summary

Replace the additive category-controller Flow deployment with an exact, category-scoped namespace
reconciler. A category controller tag must deploy every desired Flow from its immutable Git ref,
remove stale owned Flows safely, avoid revisions for unchanged sources, and prove that neither the
Kestra controller nor external workers restarted.

### Scope

**Included**: Python reconciliation logic and CLI, category manifest and dedicated namespace,
tag-workflow integration, on-prem/Ansible-compatible invocation, automated tests, documentation,
and live tag verification.

**Excluded**: Kestra runtime/plugin upgrades, worker replacement, infrastructure changes, and
production tenant isolation.

## Workstreams

### 1. Reconciliation Core

**Deliverables**:
- `src/kestra_playground/kestra_reconcile.py`
- `tests/test_kestra_reconcile.py`

**Status**: COMPLETED

**Validation**:
- Desired/actual plans distinguish create, update, delete, and unchanged.
- Failed create/update prevents deletion.
- A second apply performs no mutations.

**Checklist**:
- [x] Implement typed manifest and Flow models
- [x] Implement Kestra API client and validation
- [x] Implement guarded plan/apply/final verification
- [x] Cover success and failure behavior

### 2. Category Release Integration

**Deliverables**:
- `category-controllers/orders/category.yaml`
- `category-controllers/orders/flows/verify_gcp_category_logic_deployment.yaml`
- `scripts/reconcile-kestra-category-flows.sh`
- `scripts/deploy-category-controller-flows.sh`
- `.github/workflows/deploy-category-controller.yml`

**Status**: COMPLETED

**Validation**:
- `orders-controller-v*` resolves only the orders manifest and staging namespace.
- Deployment snapshots prove controller and worker continuity.
- No Terraform, rollout restart, or Ansible restart runs.

**Checklist**:
- [x] Add category manifest and dedicated Flow namespace
- [x] Add Python CLI wrapper
- [x] Replace additive registration in the controller deployer
- [x] Update tag workflow to the staging release contract

### 3. Operations And Verification

**Deliverables**:
- `design-docs/specs/command.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/design-onprem-category-logic-deployment.md`
- `design-docs/specs/notes.md`

**Status**: IN_PROGRESS

**Validation**:
- Runbook contains plan/apply/reapply and rollback procedures.
- Documentation distinguishes Flow reconciliation from runtime rollout.
- Live tag execution proves exact state and no restart.

**Checklist**:
- [x] Replace conceptual commands with implemented commands
- [x] Record migration and deletion safeguards
- [x] Execute and record tag verification evidence

## Status Table

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Reconciliation core | Python module and tests | COMPLETED | 7 focused tests passed |
| Category release integration | Manifest, Flow, scripts, workflow | COMPLETED | Local checks passed |
| Operations and verification | Runbook, design, live evidence | COMPLETED | Run 33053073015 passed |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| API reconciliation | Kestra Flow validate/get/create/update/delete endpoints | Available |
| Live controller release | GitHub staging environment, GCP OIDC, live Kestra URL | Previously proven for additive release; revalidation pending |
| Runtime continuity | GKE pod and GCE VM snapshot access | Previously proven; revalidation pending |

## Completion Criteria

- [x] Reconciler enforces one category namespace and ownership label.
- [x] Create, update, delete, unchanged, dry-run, and final verification are tested.
- [x] The same tag/ref reapplies without a new Flow revision.
- [x] Tag workflow uses the reconciler and performs no controller or worker restart.
- [x] Full project and script checks pass.
- [x] Changes are committed and pushed.
- [x] A controller tag run succeeds and records exact-state plus runtime-continuity evidence.

## Progress Log

### Session: 2026-08-27

**Tasks Completed**: Audited the additive implementation; implemented and tested the Python
reconciler, category manifest, dedicated namespace, tag integration, and operational documentation.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Kestra's namespace bulk-update implementation deletes stale Flows before it performs
creates and updates, so this release uses explicit mutations to guarantee deletion occurs last.
Live run `33053073015` proved create/delete, exact final state, one-revision idempotency, and
controller/worker runtime continuity.
