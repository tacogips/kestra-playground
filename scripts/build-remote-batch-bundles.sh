#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:?usage: build-remote-batch-bundles.sh OUTPUT_DIR}"
STAGING_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "${STAGING_ROOT}"
}
trap cleanup EXIT

# Bundles mirror the repository layout so each batch project's tool.uv.sources
# path entry (../../../../batch-common) resolves identically inside the bundle.
# Registry-mode executions ignore the bundled library through uv --no-sources.
DB_EXPORT_ROOT="batch-groups/ec/batches/db_export"
LOG_PARSE_ROOT="batch-groups/ec/batches/log_parse"

mkdir -p \
  "${OUTPUT_DIR}" \
  "${STAGING_ROOT}/${DB_EXPORT_ROOT}/fixtures" \
  "${STAGING_ROOT}/${LOG_PARSE_ROOT}/fixtures" \
  "${STAGING_ROOT}/batch-common"

uv run python \
  "${ROOT_DIR}/local/docker/remote-worker/seed_fixtures.py" \
  "${STAGING_ROOT}/fixtures"

cp \
  "${ROOT_DIR}/batch-groups/ec/batches/db_export/export_database.py" \
  "${ROOT_DIR}/batch-groups/ec/batches/db_export/pyproject.toml" \
  "${ROOT_DIR}/batch-groups/ec/batches/db_export/uv.lock" \
  "${STAGING_ROOT}/${DB_EXPORT_ROOT}/"
cp \
  "${STAGING_ROOT}/fixtures/ecommerce.db" \
  "${STAGING_ROOT}/${DB_EXPORT_ROOT}/fixtures/ecommerce.db"
cp \
  "${ROOT_DIR}/batch-groups/ec/batches/log_parse/parse_logs.py" \
  "${ROOT_DIR}/batch-groups/ec/batches/log_parse/pyproject.toml" \
  "${ROOT_DIR}/batch-groups/ec/batches/log_parse/uv.lock" \
  "${STAGING_ROOT}/${LOG_PARSE_ROOT}/"
cp \
  "${STAGING_ROOT}/fixtures/application.jsonl" \
  "${STAGING_ROOT}/${LOG_PARSE_ROOT}/fixtures/application.jsonl"

cp "${ROOT_DIR}/batch-common/pyproject.toml" "${ROOT_DIR}/batch-common/README.md" \
  "${STAGING_ROOT}/batch-common/"
cp -R "${ROOT_DIR}/batch-common/src" "${STAGING_ROOT}/batch-common/src"
find "${STAGING_ROOT}/batch-common" -type d -name '__pycache__' -exec rm -rf {} +

tar -czf "${OUTPUT_DIR}/db_export.tar.gz" \
  -C "${STAGING_ROOT}" \
  "${DB_EXPORT_ROOT}" \
  batch-common
tar -czf "${OUTPUT_DIR}/log_parse.tar.gz" \
  -C "${STAGING_ROOT}" \
  "${LOG_PARSE_ROOT}" \
  batch-common

echo "Built remote batch bundles in ${OUTPUT_DIR}."
