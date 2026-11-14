#!/usr/bin/env bash

default_business_date() {
  TZ="${BUSINESS_DATE_TZ:-Asia/Tokyo}" date +%F
}

business_date_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    printf '%s\n' python
    return 0
  fi

  echo "Missing required command: python or python3" >&2
  return 1
}

is_valid_business_date() {
  local value="$1"
  local python_bin

  python_bin="$(business_date_python)" || return 1
  "${python_bin}" - "${value}" <<'PY'
import datetime
import sys

try:
    datetime.date.fromisoformat(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
}

resolve_business_date() {
  local value="${1:-${BUSINESS_DATE:-}}"

  if [[ -z "${value}" ]]; then
    value="$(default_business_date)"
  fi

  if [[ ! "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! is_valid_business_date "${value}"; then
    echo "Invalid business date: ${value}. Use YYYY-MM-DD." >&2
    return 1
  fi

  printf '%s\n' "${value}"
}
