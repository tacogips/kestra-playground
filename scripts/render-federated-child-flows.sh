#!/usr/bin/env bash
set -euo pipefail

SERVER_KEY="${1:-}"
SOURCE_DIR="${2:-kestra/flows}"
OUTPUT_DIR="${3:-}"
BASE_NAMESPACE="${BASE_NAMESPACE:-playground.ecommerce}"

if [[ -z "${SERVER_KEY}" ]]; then
  echo "Usage: $0 <server-key> [source-dir] [output-dir]" >&2
  exit 1
fi

if [[ ! "${SERVER_KEY}" =~ ^[a-z0-9_]+$ ]]; then
  echo "Server key must match ^[a-z0-9_]+$: ${SERVER_KEY}" >&2
  exit 1
fi

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "Source flow directory does not exist: ${SOURCE_DIR}" >&2
  exit 1
fi

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kestra-${SERVER_KEY}-flows.XXXXXX")"
fi

mkdir -p "${OUTPUT_DIR}"

for flow in "${SOURCE_DIR}"/*.yaml; do
  [[ -e "${flow}" ]] || continue

  namespace="$(
    ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("namespace")' "${flow}"
  )"
  if [[ "${namespace}" != "${BASE_NAMESPACE}" ]]; then
    echo "Unexpected namespace in ${flow}: ${namespace} (expected ${BASE_NAMESPACE})" >&2
    exit 1
  fi

  target="${OUTPUT_DIR}/$(basename "${flow}")"
  sed "s/^namespace: ${BASE_NAMESPACE}$/namespace: ${BASE_NAMESPACE}.server_${SERVER_KEY}/" "${flow}" >"${target}"
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' "${target}" >/dev/null
done

echo "${OUTPUT_DIR}"
