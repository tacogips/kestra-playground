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
dev_version="dev-local-${suffix}"
staging_version="1.1.0"
dev_revision="local-dev"
staging_revision="local-release"
dev_image="localhost/kestra-category/orders:${dev_version}"
staging_image="localhost/kestra-category/orders:${staging_version}"
dev_bundle="${runtime_dir}/dev-bundle"
staging_bundle="${runtime_dir}/staging-bundle"
release_store="${runtime_dir}/release-store"
collection_dir="${runtime_dir}/collections"
inventory="${runtime_dir}/inventory.ini"
marker_archive="${runtime_dir}/worker-marker.tar"
docker_architecture="$(docker info --format '{{.Architecture}}')"
case "$docker_architecture" in
  aarch64 | arm64) local_platform="linux/arm64" ;;
  x86_64 | amd64) local_platform="linux/amd64" ;;
  *)
    echo "Unsupported local Docker architecture: ${docker_architecture}" >&2
    exit 1
    ;;
esac

cleanup() {
  docker container rm --force "$host_a" "$host_b" >/dev/null 2>&1 || true
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

scripts/build-category-logic-bundle.sh \
  "$dev_bundle" "$dev_version" "$dev_revision" "$dev_image" "$local_platform" >/dev/null
scripts/build-category-logic-bundle.sh \
  "$staging_bundle" "$staging_version" "$staging_revision" "$staging_image" "$local_platform" >/dev/null
staging_release_directory="$(
  scripts/persist-category-logic-release.sh "$staging_bundle" "$release_store"
)"

staging_archive="$(jq -er '.archive' "${staging_bundle}/release-manifest.json")"
cmp "${staging_bundle}/${staging_archive}" "${staging_release_directory}/${staging_archive}"

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

uvx --from 'ansible-core==2.21.3' ansible-galaxy collection install \
  'community.docker:==4.8.2' \
  --collections-path "$collection_dir" >/dev/null
export ANSIBLE_COLLECTIONS_PATH="$collection_dir"

worker_a_before="$(docker exec "$host_a" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"
worker_b_before="$(docker exec "$host_b" podman container inspect kestra-worker | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"

echo "Simulating the DEV main-push workflow against the shared inventory."
scripts/deploy-category-logic-bundle.sh \
  "$dev_bundle" "$inventory" orders_workers kestra-worker

echo "Simulating the STAGING tag workflow against the same shared inventory."
scripts/deploy-category-logic-bundle.sh \
  "$staging_release_directory" "$inventory" orders_workers kestra-worker
if scripts/audit-category-logic-ansible.sh \
  "$inventory" orders_workers "$staging_image" 9.9.0 "$staging_revision" kestra-worker; then
  echo "The version audit accepted an unexpected logic version." >&2
  exit 1
fi
scripts/audit-category-logic-ansible.sh \
  "$inventory" orders_workers "$staging_image" "$staging_version" "$staging_revision" kestra-worker

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
      "$staging_image" \
      /app/batches/version.sh
  )"
  jq -e \
    --arg host "$host" \
    --arg version "$staging_version" \
    --arg revision "$staging_revision" \
    '.category == "orders" and .version == $version and .revision == $revision and .worker_host == $host' \
    <<<"$version_json" >/dev/null
  worker_json="$(docker exec "$host" podman container inspect kestra-worker)"
  worker_id="$(jq -r '.[0].Id' <<<"$worker_json")"
  printf 'host=%s logic=%s worker=%s\n' "$host" "$version_json" "$worker_id"
done

echo "Verified separate DEV and STAGING flows on one shared two-host inventory without restarting either worker."
