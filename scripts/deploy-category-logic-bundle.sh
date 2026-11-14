#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 5 ]]; then
  echo "Usage: $0 BUNDLE_DIRECTORY INVENTORY TARGET_GROUP [WORKER_CONTAINER] [CONTAINER_RUNTIME]" >&2
  exit 2
fi

bundle_directory="$1"
inventory="$2"
target_group="$3"
worker_container_name="${4:-kestra-worker}"
container_runtime_executable="${5:-podman}"
manifest_path="${bundle_directory}/release-manifest.json"

if [[ ! -f "$manifest_path" ]]; then
  echo "Missing release manifest: ${manifest_path}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

logic_image="$(jq -er '.image' "$manifest_path")"
logic_version="$(jq -er '.version' "$manifest_path")"
logic_revision="$(jq -er '.revision' "$manifest_path")"
archive_name="$(jq -er '.archive' "$manifest_path")"
expected_sha256="$(jq -er '.archiveSha256' "$manifest_path")"
archive_path="${bundle_directory}/${archive_name}"

if [[ "$archive_name" != "$(basename "$archive_name")" || ! -f "$archive_path" ]]; then
  echo "Invalid or missing release archive: ${archive_path}" >&2
  exit 1
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
else
  actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
fi
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "Release archive checksum mismatch: ${archive_path}" >&2
  exit 1
fi

scripts/deploy-category-logic-ansible.sh \
  "$inventory" \
  "$target_group" \
  "$archive_path" \
  "$logic_image" \
  "$logic_version" \
  "$logic_revision" \
  "$worker_container_name" \
  "$container_runtime_executable"
