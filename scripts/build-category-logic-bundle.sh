#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 4 || "$#" -gt 5 ]]; then
  echo "Usage: $0 OUTPUT_DIRECTORY VERSION REVISION IMAGE [PLATFORM]" >&2
  exit 2
fi

output_directory="$1"
logic_version="$2"
logic_revision="$3"
logic_image="$4"
platform="${5:-linux/amd64}"

for command in docker jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

if [[ ! "$logic_version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "Invalid category logic version: ${logic_version}" >&2
  exit 1
fi
if [[ ! "$logic_revision" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "Invalid category logic revision: ${logic_revision}" >&2
  exit 1
fi
if [[ "$logic_image" == *[[:space:]]* || "$logic_image" != *:* ]]; then
  echo "Invalid category logic image reference: ${logic_image}" >&2
  exit 1
fi
if [[ "$platform" != "linux/amd64" && "$platform" != "linux/arm64" ]]; then
  echo "Unsupported category logic platform: ${platform}" >&2
  exit 1
fi

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
archive_name="orders-${logic_version}.tar"
archive_path="${output_directory}/${archive_name}"

docker buildx build \
  --build-arg "LOGIC_VERSION=${logic_version}" \
  --build-arg "REVISION=${logic_revision}" \
  --platform "$platform" \
  --tag "$logic_image" \
  --output "type=docker,dest=${archive_path}" \
  examples/category-batch-image

if command -v sha256sum >/dev/null 2>&1; then
  archive_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"
else
  archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
fi

jq -n \
  --arg category orders \
  --arg version "$logic_version" \
  --arg revision "$logic_revision" \
  --arg image "$logic_image" \
  --arg archive "$archive_name" \
  --arg archive_sha256 "$archive_sha256" \
  '{
    category: $category,
    version: $version,
    revision: $revision,
    image: $image,
    archive: $archive,
    archiveSha256: $archive_sha256
  }' >"${output_directory}/release-manifest.json"
printf '%s  %s\n' "$archive_sha256" "$archive_name" >"${output_directory}/SHA256SUMS"

printf '%s\n' "$output_directory"
