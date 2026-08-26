#!/bin/sh
set -eu

printf 'category=orders batch=normal target=default-worker image_revision=%s pod=%s node=%s\n' \
  "${IMAGE_REVISION:-unknown}" \
  "${POD_NAME:-unknown}" \
  "${K8S_NODE_NAME:-unknown}"
sleep "${SLEEP_SECONDS:-20}"
