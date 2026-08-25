#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends openssh-server python3 python3-pip curl
rm -rf /var/lib/apt/lists/*

if ! id batch >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash batch
fi

# Staging/production targets install the shared batch library from the private
# GCP Artifact Registry Python repository. The index URL and optional version
# spec arrive through instance metadata; authentication uses the instance
# service account token from the metadata server.
install_batch_common() {
  local metadata_base='http://metadata.google.internal/computeMetadata/v1'
  local index_url package_spec access_token

  index_url="$(curl --fail --silent --max-time 5 -H 'Metadata-Flavor: Google' \
    "${metadata_base}/instance/attributes/python-registry-index-url" 2>/dev/null || true)"
  if [[ -z "${index_url}" ]]; then
    echo "python-registry-index-url metadata is not set; skipping kestra-batch-common install." >&2
    return 0
  fi

  package_spec="$(curl --fail --silent --max-time 5 -H 'Metadata-Flavor: Google' \
    "${metadata_base}/instance/attributes/kestra-batch-common-spec" 2>/dev/null || true)"
  package_spec="${package_spec:-kestra-batch-common}"

  access_token="$(curl --fail --silent --max-time 5 -H 'Metadata-Flavor: Google' \
    "${metadata_base}/instance/service-accounts/default/token" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["access_token"])')"

  python3 -m pip install --break-system-packages --no-cache-dir \
    --index-url "https://oauth2accesstoken:${access_token}@${index_url#https://}" \
    "${package_spec}"
}
install_batch_common

install -d -m 755 /opt/batch-inputs
python3 - <<'PY'
import json
from pathlib import Path

records = [
    {
        "timestamp": "2026-06-25T00:00:01Z",
        "level": "INFO",
        "service": "api",
        "message": "request accepted",
    },
    {
        "timestamp": "2026-06-25T00:00:02Z",
        "level": "ERROR",
        "service": "worker",
        "message": "temporary downstream failure",
    },
    {
        "timestamp": "2026-06-25T00:00:03Z",
        "level": "WARN",
        "service": "api",
        "message": "retry scheduled",
    },
]
path = Path("/opt/batch-inputs/application.jsonl")
path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")
PY
chmod -R a+rX /opt/batch-inputs

install -d -m 755 /etc/ssh/sshd_config.d
printf '%s\n' \
  'PasswordAuthentication yes' \
  'PermitRootLogin no' \
  > /etc/ssh/sshd_config.d/60-kestra-remote-batch.conf
systemctl restart ssh

cat >/usr/local/sbin/kestra-remote-batch-sshd-control <<'CONTROL'
#!/usr/bin/env bash
set -u

metadata_url='http://metadata.google.internal/computeMetadata/v1/instance/attributes/remote-batch-sshd-disabled'
while true; do
  disabled="$(curl --fail --silent --max-time 2 -H 'Metadata-Flavor: Google' "${metadata_url}" 2>/dev/null || true)"
  if [[ "${disabled}" == "true" ]]; then
    systemctl stop ssh
  else
    systemctl start ssh
  fi
  sleep 2
done
CONTROL
chmod 755 /usr/local/sbin/kestra-remote-batch-sshd-control

cat >/etc/systemd/system/kestra-remote-batch-sshd-control.service <<'UNIT'
[Unit]
Description=Kestra remote-batch SSH fault-injection control
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/kestra-remote-batch-sshd-control
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now kestra-remote-batch-sshd-control.service
touch /var/lib/kestra-remote-batch-ready
