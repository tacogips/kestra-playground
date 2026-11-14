#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REPOSITORY="${KESTRA_SOURCE_REPOSITORY:-https://github.com/tacogips/kestra.git}"
SOURCE_REF="${KESTRA_SOURCE_REF:-main}"
PLUGIN_FS_VERSION="${KESTRA_PLUGIN_FS_VERSION:-2.11.1}"
IMAGE_REPOSITORY="${KESTRA_LOCAL_IMAGE_REPOSITORY:-tacogips-kestra}"
SOURCE_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "${SOURCE_DIR}"
}
trap cleanup EXIT

git clone --filter=blob:none --branch "${SOURCE_REF}" --single-branch \
  "${SOURCE_REPOSITORY}" "${SOURCE_DIR}"
source_sha="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
image="${IMAGE_REPOSITORY}:${source_sha}"
latest_image="${IMAGE_REPOSITORY}:latest"

if ! (cd "${SOURCE_DIR}/ui" && npm ci); then
  echo "The fork UI lockfile is out of sync; regenerating dependencies in the temporary checkout." >&2
  (cd "${SOURCE_DIR}/ui" && npm install)
fi
(cd "${SOURCE_DIR}/ui" && npm run build)
(cd "${SOURCE_DIR}" && ./gradlew writeExecutableJar --no-daemon)

cp \
  "${SOURCE_DIR}/build/executable/kestra-2.0.0-SNAPSHOT" \
  "${SOURCE_DIR}/docker/app/kestra"
chmod 755 "${SOURCE_DIR}/docker/app/kestra"
"${SOURCE_DIR}/docker/app/kestra" plugins install \
  "io.kestra.plugin:plugin-fs:${PLUGIN_FS_VERSION}" \
  --plugins "${SOURCE_DIR}/docker/app/plugins"

docker build \
  --file "${ROOT_DIR}/local/docker/tacogips-kestra.Dockerfile" \
  --label "org.opencontainers.image.revision=${source_sha}" \
  --label "org.opencontainers.image.source=https://github.com/tacogips/kestra" \
  --tag "${image}" \
  --tag "${latest_image}" \
  "${SOURCE_DIR}"

echo "Built ${image} and ${latest_image} from ${SOURCE_REPOSITORY} ${SOURCE_REF}."
