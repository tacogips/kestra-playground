#!/bin/sh
set -eu

category="orders"
version="${LOGIC_VERSION:-unknown}"
revision="${LOGIC_REVISION:-unknown}"
worker_host="${WORKER_HOSTNAME:-$(hostname)}"

if [ "${1:-}" = "--kestra-output" ]; then
  printf '::{"outputs":{"category":"%s","logic_version":"%s","logic_revision":"%s","worker_host":"%s"}}::\n' \
    "$category" "$version" "$revision" "$worker_host"
else
  printf '{"category":"%s","version":"%s","revision":"%s","worker_host":"%s"}\n' \
    "$category" "$version" "$revision" "$worker_host"
fi
