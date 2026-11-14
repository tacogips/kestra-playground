#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Stop one batch group, or the whole stack:
#   local/docker/stop.sh            remove the whole stack (default)
#   local/docker/stop.sh ec         stop only the EC Kestra and its SSH workers
#   local/docker/stop.sh affiliate  stop only the affiliate Kestra
BATCH_GROUP="${1:-${BATCH_GROUP:-all}}"

compose() {
  docker compose -f "${ROOT_DIR}/local/docker/docker-compose.yml" "$@"
}

case "${BATCH_GROUP}" in
  all)
    # PostgreSQL and Mailpit are shared, so only the full stop removes them.
    compose down
    ;;
  ec)
    compose stop kestra-ec remote-worker remote-worker-b
    ;;
  affiliate)
    compose stop kestra-affiliate
    ;;
  *)
    echo "Unknown batch group: ${BATCH_GROUP}" >&2
    echo "Use one of: all, ec, affiliate" >&2
    exit 1
    ;;
esac
