#!/usr/bin/env sh
set -eu

: "${REMOTE_BATCH_PASSWORD:?REMOTE_BATCH_PASSWORD is required}"

printf '%s:%s\n' batch "${REMOTE_BATCH_PASSWORD}" | chpasswd
exec /usr/sbin/sshd -D -e
