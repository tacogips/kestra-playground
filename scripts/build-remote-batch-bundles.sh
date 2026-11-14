#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:?usage: build-remote-batch-bundles.sh OUTPUT_DIR}"
STAGING_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "${STAGING_ROOT}"
}
trap cleanup EXIT

mkdir -p \
  "${OUTPUT_DIR}" \
  "${STAGING_ROOT}/batches/db_export/fixtures" \
  "${STAGING_ROOT}/batches/log_parse/fixtures"

uv run python \
  "${ROOT_DIR}/local/docker/remote-worker/seed_fixtures.py" \
  "${STAGING_ROOT}/fixtures"

cp \
  "${ROOT_DIR}/batches/db_export/export_database.py" \
  "${STAGING_ROOT}/batches/db_export/export_database.py"
cp \
  "${STAGING_ROOT}/fixtures/ecommerce.db" \
  "${STAGING_ROOT}/batches/db_export/fixtures/ecommerce.db"
cp \
  "${ROOT_DIR}/batches/log_parse/parse_logs.py" \
  "${STAGING_ROOT}/batches/log_parse/parse_logs.py"
cp \
  "${STAGING_ROOT}/fixtures/application.jsonl" \
  "${STAGING_ROOT}/batches/log_parse/fixtures/application.jsonl"

tar -czf "${OUTPUT_DIR}/db_export.tar.gz" \
  -C "${STAGING_ROOT}" \
  batches/db_export
tar -czf "${OUTPUT_DIR}/log_parse.tar.gz" \
  -C "${STAGING_ROOT}" \
  batches/log_parse

echo "Built remote batch bundles in ${OUTPUT_DIR}."
