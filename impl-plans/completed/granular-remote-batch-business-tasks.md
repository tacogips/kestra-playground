# Granular Remote Batch Business Tasks Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-remote-python-batch-runner.md#sshsftp-adapter`
**Created**: 2026-08-18
**Last Updated**: 2026-08-18

## Design Reference And Scope

Split the remote Python business lifecycle into separately visible and retryable Kestra tasks while
retaining one isolated child execution per target. Included work covers both example programs, the
SSH runner, local and GCP retry evidence, documentation, and stopping the GCE targets after success.
The routed-worker adapter and provisioning of additional infrastructure are outside this change.

## Workstreams

### 1. Phase Contract And Flow

**Deliverables**: Python example programs and `00_remote_batch_runner.yaml`.

**Status**: COMPLETED

**Validation**: Input validation, execute, and output validation are separate retryable task runs.

**Checklist**:
- [x] Add phase-aware Python entry points.
- [x] Add three explicit Kestra business tasks.
- [x] Preserve no-argument direct execution compatibility.

### 2. Automated Verification

**Deliverables**: Unit tests and local/live multi-target verifier scripts.

**Status**: COMPLETED

**Validation**: Only target B's execute task retries; both validation tasks remain at one attempt.

**Checklist**:
- [x] Add focused phase and manifest tests.
- [x] Pass local multi-target runtime verification.
- [x] Pass live workerless GCE runtime verification.

### 3. Operations And Documentation

**Deliverables**: README, design/runbook notes, final execution evidence, and stopped GCE targets.

**Status**: COMPLETED

**Validation**: Runbook matches the implemented boundaries and both target VMs end in TERMINATED.

**Checklist**:
- [x] Document the phase contract and task ownership.
- [x] Record current local and live execution evidence.
- [x] Stop and verify both GCE targets after successful live verification.

## Status

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Phase Contract And Flow | Python and Kestra flow | COMPLETED | Focused static/unit checks passed |
| Automated Verification | Tests and verifiers | COMPLETED | Local and GCP runtime checks passed |
| Operations And Documentation | Docs, evidence, stopped VMs | COMPLETED | Both instances TERMINATED |

## Dependencies

- Local `tacogips/kestra` 2.0 runtime and Docker Compose environment.
- Authenticated GCP project `kestra-playground-260625` with the two existing SSH targets.

## Completion Criteria

- [x] Both targets succeed with all three business tasks independently visible.
- [x] One injected execute failure retries only target B's execute task.
- [x] Unit, lint, type, shell, and full project gates pass.
- [x] Live targets contain no Kestra runtime and have no residual workspaces.
- [x] Both GCE instances are stopped after successful verification.
- [x] Final evidence and operational notes are recorded.

## Progress Log

### Session: 2026-08-18

**Tasks Completed**: Audited the existing single execute boundary, introduced the three-phase
contract, updated the SSH flow and verifiers, and passed focused tests.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Local baseline `LzrjTbLWQ7cAiRNGd8y0H` and retry `7OGX6eZNlQ17VqzQsMAjLy`
showed A at `1/1/1` and retry B at `1/3/1` for input-validation/execute/output-validation
attempt records. Live baseline `2PZav3nG5psPq8bWeQmp70` and retry
`7YfUJH9kLuJziKP0zMlg0k` showed the same isolation. Both GCE instances were then verified
`TERMINATED`.
