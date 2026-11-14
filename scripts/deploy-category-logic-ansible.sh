#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 6 || "$#" -gt 8 ]]; then
  echo "Usage: $0 INVENTORY TARGET_GROUP IMAGE_ARCHIVE IMAGE VERSION REVISION [WORKER_CONTAINER] [CONTAINER_RUNTIME]" >&2
  exit 2
fi

inventory="$1"
target_group="$2"
archive="$3"
logic_image="$4"
logic_version="$5"
logic_revision="$6"
worker_container_name="${7:-kestra-worker}"
container_runtime_executable="${8:-podman}"
playbook="ops/ansible/category-logic/deploy.yml"

for path in "$inventory" "$archive" "$playbook"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing required file: ${path}" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Missing required command: jq" >&2
  exit 1
fi

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible_command=(ansible-playbook)
elif command -v uvx >/dev/null 2>&1; then
  ansible_command=(uvx --from 'ansible-core==2.21.3' ansible-playbook)
else
  echo "Install ansible-playbook or uvx." >&2
  exit 1
fi

archive="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
if command -v sha256sum >/dev/null 2>&1; then
  archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
else
  archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
fi
extra_vars="$(
  jq -cn \
    --arg target_group "$target_group" \
    --arg logic_image_archive "$archive" \
    --arg logic_image "$logic_image" \
    --arg logic_version "$logic_version" \
    --arg logic_revision "$logic_revision" \
    --arg logic_archive_sha256 "$archive_sha256" \
    --arg worker_container_name "$worker_container_name" \
    --arg container_runtime_executable "$container_runtime_executable" \
    '{
      target_group: $target_group,
      logic_image_archive: $logic_image_archive,
      logic_image: $logic_image,
      logic_version: $logic_version,
      logic_revision: $logic_revision,
      logic_archive_sha256: $logic_archive_sha256,
      worker_container_name: $worker_container_name,
      container_runtime_executable: $container_runtime_executable
    }'
)"

"${ansible_command[@]}" \
  --inventory "$inventory" \
  --forks "${ANSIBLE_FORKS:-20}" \
  --extra-vars "$extra_vars" \
  "$playbook"
