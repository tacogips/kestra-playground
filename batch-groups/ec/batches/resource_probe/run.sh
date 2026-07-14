#!/usr/bin/env sh
set -eu

batch_id="${BATCH_ID:-resource_probe}"
resource_class="${RESOURCE_CLASS:-local}"
business_date="${BUSINESS_DATE:-1970-01-01}"
output_path="${OUTPUT_PATH:-}"
sleep_seconds="${SLEEP_SECONDS:-0}"

case "${business_date}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *)
    echo "Invalid BUSINESS_DATE: ${business_date}" >&2
    exit 64
    ;;
esac

month="${business_date#????-}"
month="${month%-??}"
day="${business_date##????-??-}"
if [ "${month}" -lt 1 ] || [ "${month}" -gt 12 ] || [ "${day}" -lt 1 ] || [ "${day}" -gt 31 ]; then
  echo "Invalid BUSINESS_DATE: ${business_date}" >&2
  exit 64
fi

host_name="$(hostname 2>/dev/null || printf unknown)"
cpu_limit="${CPU_LIMIT:-unknown}"
memory_limit="${MEMORY_LIMIT:-unknown}"
worker_group="${WORKER_GROUP:-${KESTRA_WORKER_GROUP:-unknown}}"

echo "batch_id=${batch_id}"
echo "resource_class=${resource_class}"
echo "business_date=${business_date}"
echo "hostname=${host_name}"
echo "worker_group=${worker_group}"
echo "cpu_limit=${cpu_limit}"
echo "memory_limit=${memory_limit}"

case "${sleep_seconds}" in
  ''|*[!0-9]*)
    echo "Invalid SLEEP_SECONDS: ${sleep_seconds}" >&2
    exit 64
    ;;
esac

if [ -n "${output_path}" ]; then
  mkdir -p "$(dirname "${output_path}")"
  cat >"${output_path}" <<EOF
{"batch_id":"${batch_id}","resource_class":"${resource_class}","business_date":"${business_date}","hostname":"${host_name}","worker_group":"${worker_group}","cpu_limit":"${cpu_limit}","memory_limit":"${memory_limit}"}
EOF
fi

if [ "${sleep_seconds}" -gt 0 ]; then
  echo "sleep_seconds=${sleep_seconds}"
  sleep "${sleep_seconds}"
fi
