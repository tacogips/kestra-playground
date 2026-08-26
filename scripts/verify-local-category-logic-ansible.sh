#!/usr/bin/env bash
set -euo pipefail

for command in docker jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

if ! command -v uvx >/dev/null 2>&1; then
  echo "Run this verifier through 'mise exec --' so uvx is available." >&2
  exit 1
fi

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/kestra-category-logic.XXXXXX")"
suffix="$$"
host_a="kestra-logic-host-a-${suffix}"
host_b="kestra-logic-host-b-${suffix}"
image_v1="localhost/kestra-category/orders:local-1.0.0-${suffix}"
image_v2="localhost/kestra-category/orders:local-1.1.0-${suffix}"
collection_dir="${runtime_dir}/collections"
inventory="${runtime_dir}/inventory.ini"
marker_archive="${runtime_dir}/worker-marker.tar"
archive_v1="${runtime_dir}/orders-1.0.0.tar"
archive_v2="${runtime_dir}/orders-1.1.0.tar"

cleanup() {
  docker container rm --force "$host_a" "$host_b" >/dev/null 2>&1 || true
  docker image rm "$image_v1" "$image_v2" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build \
  --build-arg LOGIC_VERSION=1.0.0 \
  --build-arg REVISION=local-v1 \
  --tag "$image_v1" \
  examples/category-batch-image >/dev/null
docker save --output "$archive_v1" "$image_v1"

docker build \
  --build-arg LOGIC_VERSION=1.1.0 \
  --build-arg REVISION=local-v2 \
  --tag "$image_v2" \
  examples/category-batch-image >/dev/null
docker save --output "$archive_v2" "$image_v2"

docker pull alpine:3.22.1 >/dev/null
docker save --output "$marker_archive" alpine:3.22.1

for host in "$host_a" "$host_b"; do
  docker run \
    --detach \
    --privileged \
    --name "$host" \
    quay.io/podman/stable:latest \
    sleep infinity >/dev/null
  docker cp "$marker_archive" "${host}:/tmp/worker-marker.tar"
  docker exec "$host" podman load --input /tmp/worker-marker.tar >/dev/null
  docker exec "$host" podman run \
    --detach \
    --name kestra-worker \
    docker.io/library/alpine:3.22.1 \
    sleep infinity >/dev/null
done

cat >"$inventory" <<EOF
[orders_workers]
${host_a} ansible_connection=community.docker.docker ansible_host=${host_a}
${host_b} ansible_connection=community.docker.docker ansible_host=${host_b}

[orders_workers:vars]
ansible_python_interpreter=/usr/bin/python3
EOF

uvx --from ansible-core ansible-galaxy collection install \
  'community.docker:==4.8.2' \
  --collections-path "$collection_dir" >/dev/null
export ANSIBLE_COLLECTIONS_PATH="$collection_dir"

worker_a_before="$(docker exec "$host_a" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"
worker_b_before="$(docker exec "$host_b" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"

scripts/deploy-category-logic-ansible.sh \
  "$inventory" orders_workers "$archive_v1" "$image_v1" 1.0.0 local-v1 kestra-worker
scripts/deploy-category-logic-ansible.sh \
  "$inventory" orders_workers "$archive_v2" "$image_v2" 1.1.0 local-v2 kestra-worker
if scripts/audit-category-logic-ansible.sh \
  "$inventory" orders_workers "$image_v2" 9.9.0 local-v2 kestra-worker; then
  echo "The version audit accepted an unexpected logic version." >&2
  exit 1
fi
scripts/audit-category-logic-ansible.sh \
  "$inventory" orders_workers "$image_v2" 1.1.0 local-v2 kestra-worker

worker_a_after="$(docker exec "$host_a" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"
worker_b_after="$(docker exec "$host_b" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"

if [[ "$worker_a_before" != "$worker_a_after" || "$worker_b_before" != "$worker_b_after" ]]; then
  echo "A Kestra worker marker restarted during category logic deployment." >&2
  exit 1
fi

for host in "$host_a" "$host_b"; do
  version_json="$(
    docker exec "$host" podman run --rm --pull=never \
      --env "WORKER_HOSTNAME=${host}" \
      "$image_v2" \
      /app/batches/version.sh
  )"
  jq -e \
    --arg host "$host" \
    '.category == "orders" and .version == "1.1.0" and .revision == "local-v2" and .worker_host == $host' \
    <<<"$version_json" >/dev/null
  worker_json="$(docker exec "$host" podman container inspect kestra-worker)"
  worker_id="$(jq -r '.[0].Id' <<<"$worker_json")"
  printf 'host=%s logic=%s worker=%s\n' "$host" "$version_json" "$worker_id"
done

echo "Verified category logic 1.0.0 -> 1.1.0 on two Podman hosts without restarting either worker."
