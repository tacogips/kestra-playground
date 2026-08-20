#!/usr/bin/env bash
# Download the Kestra plugin JARs that the local EC Kestra image does not bundle.
#
# The EC batch group runs the tacogips/kestra fork build, which is based on
# ghcr.io/kestra-io/kestra-base:latest-no-plugins and therefore ships only the
# handful of plugins baked into that image. The mail notification flows need the
# Email plugin, so it is fetched here and bind-mounted into /app/plugins by
# docker-compose.yml.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN_DIR="${ROOT_DIR}/local/docker/plugins"
MAVEN_BASE="${KESTRA_PLUGIN_MAVEN_BASE:-https://repo1.maven.org/maven2}"
EMAIL_PLUGIN_VERSION="${KESTRA_EMAIL_PLUGIN_VERSION:-1.5.1}"
# The EC batch group flows need the PostgreSQL plugin and the remote-batch demos
# need the Shell plugin. These versions match the ones the routed image build in
# .github/workflows/deploy.yml installs, so local and GKE run the same set.
JDBC_POSTGRES_PLUGIN_VERSION="${KESTRA_JDBC_POSTGRES_PLUGIN_VERSION:-1.15.4}"
SCRIPT_SHELL_PLUGIN_VERSION="${KESTRA_SCRIPT_SHELL_PLUGIN_VERSION:-1.9.0}"

mkdir -p "${PLUGIN_DIR}"

fetch_plugin() {
  local artifact="$1"
  local version="$2"
  local jar="${artifact}-${version}.jar"
  local target="${PLUGIN_DIR}/${jar}"
  local url="${MAVEN_BASE}/io/kestra/plugin/${artifact}/${version}/${jar}"

  if [[ -s "${target}" ]]; then
    echo "Plugin ${jar} already present."
    return
  fi

  echo "Downloading ${jar}"
  curl --silent --show-error --fail --location -o "${target}.tmp" "${url}"

  local expected actual
  expected="$(curl --silent --show-error --fail --location "${url}.sha1" | tr -d '[:space:]')"
  if command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 1 "${target}.tmp" | awk '{print $1}')"
  else
    actual="$(sha1sum "${target}.tmp" | awk '{print $1}')"
  fi
  if [[ "${expected}" != "${actual}" ]]; then
    rm -f "${target}.tmp"
    echo "Checksum mismatch for ${jar}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi

  mv "${target}.tmp" "${target}"
}

fetch_plugin "plugin-email" "${EMAIL_PLUGIN_VERSION}"
fetch_plugin "plugin-jdbc-postgres" "${JDBC_POSTGRES_PLUGIN_VERSION}"
fetch_plugin "plugin-script-shell" "${SCRIPT_SHELL_PLUGIN_VERSION}"
