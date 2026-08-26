#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 4 || "$#" -gt 7 ]]; then
  echo "Usage: $0 INVENTORY TARGET_GROUP IMAGE EXPECTED_VERSION [EXPECTED_REVISION] [WORKER_CONTAINER] [CONTAINER_RUNTIME]" >&2
  exit 2
fi

inventory="$1"
target_group="$2"
logic_image="$3"
expected_logic_version="$4"
expected_logic_revision="${5:-}"
worker_container_name="${6:-kestra-worker}"
container_runtime_executable="${7:-podman}"
playbook="ops/ansible/category-logic/audit.yml"

for path in "$inventory" "$playbook"; do
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

extra_vars="$(
  jq -cn \
    --arg target_group "$target_group" \
    --arg logic_image "$logic_image" \
    --arg expected_logic_version "$expected_logic_version" \
    --arg expected_logic_revision "$expected_logic_revision" \
    --arg worker_container_name "$worker_container_name" \
    --arg container_runtime_executable "$container_runtime_executable" \
    '{
      target_group: $target_group,
      logic_image: $logic_image,
      expected_logic_version: $expected_logic_version,
      expected_logic_revision: $expected_logic_revision,
      worker_container_name: $worker_container_name,
      container_runtime_executable: $container_runtime_executable
    }'
)"

"${ansible_command[@]}" \
  --inventory "$inventory" \
  --forks "${ANSIBLE_FORKS:-20}" \
  --extra-vars "$extra_vars" \
  "$playbook"
