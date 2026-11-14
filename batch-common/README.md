# kestra-batch-common

Shared runtime helpers used by every Python batch under `batch-groups/*/batches/`.

The library standardizes the contract between Kestra flows and batch scripts:

- `KESTRA_BATCH_CONFIG`: JSON business configuration read with `load_config()`.
- `KESTRA_BATCH_OUTPUT`: artifact destination read with `output_path()`.
- `emit_progress()` / `emit_kestra_result()`: structured stdout lines that Kestra
  captures as progress logs, outputs, and metrics.
- `select_phase()` / `PHASES`: the independently retryable
  `validate-input` / `execute` / `validate-output` phase contract.
- `report_batch_error()` / `BATCH_ERROR_EXIT_CODE`: uniform expected-error reporting.

## Consumption model

- Local development resolves this project through a `tool.uv.sources` path entry in each
  batch project, so edits are picked up immediately.
- Staging and production resolve the published `kestra-batch-common` wheel from the
  GCP Artifact Registry Python repository (`uv ... --no-sources`, or `pip install`
  with the registry index URL on SSH batch targets).

See `design-docs/specs/design-batch-common-registry-operation.md` for the full
operation guide, including publishing a new version.

## Development

```bash
cd batch-common
uv sync --dev
uv run pytest
uv run ruff format .
uv run ruff check .
uv build
```
