#!/usr/bin/env bash
set -euo pipefail

for name in kestra kestra-ec kestra-affiliate kestra-postgres; do
  container stop "${name}" >/dev/null 2>&1 || true
  container delete --force "${name}" >/dev/null 2>&1 || true
done

echo "Stopped Kestra playground Apple containers."
