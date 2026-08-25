#!/usr/bin/env bash
set -euo pipefail

# Publish batch-common/ to the private GCP Artifact Registry Python repository.
#
# Configuration (environment):
#   PROJECT_ID / GCP_PROJECT_ID        target project (required unless PYTHON_REGISTRY_UPLOAD_URL is set)
#   PYTHON_REGISTRY_REGION             registry location (default: asia-northeast1)
#   PYTHON_REGISTRY_REPOSITORY         repository ID (default: python-batch-libs)
#   PYTHON_REGISTRY_UPLOAD_URL         full upload URL override
#
# Authentication uses the active gcloud account (roles/artifactregistry.writer).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-${GCP_PROJECT_ID:-}}"
REGION="${PYTHON_REGISTRY_REGION:-asia-northeast1}"
REPOSITORY="${PYTHON_REGISTRY_REPOSITORY:-python-batch-libs}"
UPLOAD_URL="${PYTHON_REGISTRY_UPLOAD_URL:-}"

if [[ -z "${UPLOAD_URL}" ]]; then
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "PROJECT_ID or GCP_PROJECT_ID is required when PYTHON_REGISTRY_UPLOAD_URL is unset." >&2
    exit 1
  fi
  UPLOAD_URL="https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPOSITORY}/"
fi

cd "${ROOT_DIR}/batch-common"

version="$(uv version --short)"
echo "Publishing kestra-batch-common ${version} to ${UPLOAD_URL}"

uv sync --dev
uv run pytest
rm -rf dist
uv build

UV_PUBLISH_USERNAME=oauth2accesstoken \
UV_PUBLISH_PASSWORD="$(gcloud auth print-access-token)" \
  uv publish --publish-url "${UPLOAD_URL}" dist/*

echo "Published kestra-batch-common ${version}."
