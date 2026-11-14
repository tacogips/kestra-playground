#!/usr/bin/env sh
set -eu

: "${REMOTE_BATCH_PASSWORD:?REMOTE_BATCH_PASSWORD is required}"

printf '%s:%s\n' batch "${REMOTE_BATCH_PASSWORD}" | chpasswd

# Keep the fixture container alive while tests deliberately disable only sshd. A stable container
# IP makes the client receive connection-refused promptly, which exercises Kestra retry instead of
# waiting inside DNS resolution for a stopped Compose service to reappear.
while true; do
  if [ -e /tmp/disable-sshd ]; then
    sleep 1
    continue
  fi

  /usr/sbin/sshd -D -e || true
done
