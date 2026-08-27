#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec uv run python -m kestra_playground.kestra_reconcile --repo-root "$repo_root" "$@"
