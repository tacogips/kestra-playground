#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 BUNDLE_DIRECTORY RELEASE_STORE" >&2
  exit 2
fi

bundle_directory="$1"
release_store="$2"
manifest_path="${bundle_directory}/release-manifest.json"

if [[ ! -f "$manifest_path" ]]; then
  echo "Missing release manifest: ${manifest_path}" >&2
  exit 1
fi
if [[ "$release_store" != /* ]]; then
  echo "The release store must be an absolute path: ${release_store}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

category="$(jq -er '.category' "$manifest_path")"
logic_version="$(jq -er '.version' "$manifest_path")"
archive_name="$(jq -er '.archive' "$manifest_path")"
expected_sha256="$(jq -er '.archiveSha256' "$manifest_path")"

if [[ "$category" != "orders" || "$archive_name" != "$(basename "$archive_name")" ]]; then
  echo "Invalid category release manifest: ${manifest_path}" >&2
  exit 1
fi
if [[ ! "$logic_version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  echo "Invalid category logic version: ${logic_version}" >&2
  exit 1
fi

archive_path="${bundle_directory}/${archive_name}"
if [[ ! -f "$archive_path" ]]; then
  echo "Missing release archive: ${archive_path}" >&2
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

release_directory="${release_store}/${category}/${logic_version}"
if [[ -d "$release_directory" ]]; then
  if cmp -s "$manifest_path" "${release_directory}/release-manifest.json" \
    && cmp -s "$archive_path" "${release_directory}/${archive_name}"; then
    printf '%s\n' "$release_directory"
    exit 0
  fi
  echo "Refusing to overwrite an existing immutable release: ${release_directory}" >&2
  exit 1
fi

temporary_directory="${release_directory}.tmp.$$"
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$(dirname "$release_directory")" "$temporary_directory"
install -m 0644 "$archive_path" "${temporary_directory}/${archive_name}"
install -m 0644 "$manifest_path" "${temporary_directory}/release-manifest.json"
install -m 0644 "${bundle_directory}/SHA256SUMS" "${temporary_directory}/SHA256SUMS"
mv "$temporary_directory" "$release_directory"
trap - EXIT

printf '%s\n' "$release_directory"
