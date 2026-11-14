# Multi-Target SSH Batch Retry Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-remote-python-batch-runner.md#multi-target-fan-out-and-retry`
**Created**: 2026-08-17
**Last Updated**: 2026-08-17

---

## Design Document Reference

**Source**: `design-docs/specs/design-remote-python-batch-runner.md`

### Summary

Add bounded parallel SSH fan-out that runs one existing remote-batch child execution per target and
automatically retries the failed SSH/SFTP step on only the affected target.

### Scope

**Included**: Generic multi-target flow, an example caller, local two-target verification,
transient-failure retry evidence, GCP SSH target provisioning/startup, live execution evidence, and
operational documentation.

**Excluded**: Unbounded data fan-out, target discovery, and cross-target rollback.

## Workstreams

### 1. Flow Contract

**Deliverables**:
- `kestra/flows-remote-batch/02_multi_target_remote_batch_runner.yaml`
- `kestra/flows-remote-batch/parse_application_logs_multi_target.yaml`

**Status**: COMPLETED

**Validation**:
- Each target creates an isolated child execution.
- Concurrency and retry budgets are explicit static policy.

**Checklist**:
- [x] Add bounded Kestra 2.0 `Loop` fan-out.
- [x] Add granular retry to every SSH/SFTP step and retain a per-target Subflow fallback.
- [x] Preserve secret-name-only target configuration.

### 2. Local Verification

**Deliverables**:
- `local/docker/docker-compose.yml`
- `scripts/register-remote-batch-demo.sh`
- `scripts/verify-local-remote-batch.sh`
- `tests/test_remote_batch_examples.py`

**Status**: COMPLETED

**Validation**:
- Two targets succeed in one parent execution.
- One execute-step failure retries and later succeeds without repeating earlier steps or the
  successful target.
- Failed child workspaces are absent.

**Checklist**:
- [x] Provision a second local SSH target.
- [x] Extend registration and verification.
- [x] Add regression assertions.

### 3. GCP Target Operations

**Deliverables**:
- `scripts/provision-live-remote-batch-targets.sh`
- `scripts/verify-live-remote-batch-ssh.sh`
- `mise.toml`

**Status**: COMPLETED

**Validation**:
- Two workerless GCE SSH targets are running and reachable only from the verifier source range.
- A live Kestra 2.0 execution records two successful targets and an isolated failed-step retry.

**Checklist**:
- [x] Add idempotent target provisioning/start commands.
- [x] Keep password payloads out of files, logs, and metadata.
- [x] Capture instance and execution evidence without secret values.

### 4. Documentation And Quality Gates

**Deliverables**:
- `README.md`
- `design-docs/specs/command.md`
- `design-docs/specs/notes.md`
- `design-docs/specs/design-remote-python-batch-runner.md`

**Status**: COMPLETED

**Validation**:
- Runbook explains local and GCP procedures.
- `task ci`, targeted shell checks, and live verifier pass.

**Checklist**:
- [x] Document contracts and commands.
- [x] Run formatting, lint, type, unit, local, and live checks.
- [x] Record execution IDs and observed retry attempts.

## Status

| Workstream | Deliverables | Status | Validation |
|------------|--------------|--------|------------|
| Flow Contract | Multi-target flows | COMPLETED | Registered on latest Kestra 2.0 fork |
| Local Verification | Compose, verifier, tests | COMPLETED | A execute=1; only B has failed/success retry evidence |
| GCP Target Operations | Provision and live verifier scripts | COMPLETED | Two running GCE targets verified |
| Documentation And Quality Gates | Docs and evidence | COMPLETED | Runbook and evidence recorded |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Multi-target fan-out | Existing `remote_batch_runner` | Available |
| Isolated retry | Kestra task retries plus target Subflow fallback | Available in verified 2.0 fork |
| Live verification | Active Google Cloud authentication and Compute Engine quota | Available and verified |

## Completion Criteria

- [x] All workstreams completed.
- [x] Successful targets are not rerun when another target retries.
- [x] Retry exhaustion behavior remains covered by single-target failure propagation and every failed child cleans its workspace.
- [x] `uv run ruff format .`, `uv run ruff check .`, `uv run ty check .`, and `uv run pytest` pass.
- [x] Local two-target and live GCP two-target verification pass.
- [x] Operational evidence and any remaining issues are documented.

## Progress Log

### Session: 2026-08-17

**Tasks Completed**: Implemented, tested, documented, and live-verified multi-target SSH fan-out and
isolated retry on two GCP targets.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Local retry execution `79SWnUIO4RB0jup860UFP9` and live GCP retry execution
`20xWDrLr7mN31DYUBsDSc7` used `tacogips/kestra` revision
`6f6012b5e0d8f302b894d465672d8dda5222515f`. Each proved one child and one prepare/stage run per
target, A execute success without retry, and failed plus successful execute records only on B. Both
GCE targets were also verified to contain no Kestra runtime.
