#!/usr/bin/env bash
set -euo pipefail

container stop kestra >/dev/null 2>&1 || true
container stop kestra-postgres >/dev/null 2>&1 || true
container delete --force kestra >/dev/null 2>&1 || true
container delete --force kestra-postgres >/dev/null 2>&1 || true

echo "Stopped Kestra playground Apple containers."
