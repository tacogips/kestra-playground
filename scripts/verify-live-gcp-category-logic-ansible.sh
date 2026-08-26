#!/usr/bin/env bash
set -euo pipefail

for command in ansible-playbook curl docker gcloud jq scp ssh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: ${command}" >&2
    exit 1
  fi
done

project_id="${GCP_PROJECT_ID:?Set GCP_PROJECT_ID}"
live_domain_name="${LIVE_DOMAIN_NAME:?Set LIVE_DOMAIN_NAME}"
zone="${GCP_CATEGORY_LOGIC_ZONE:-asia-northeast1-a}"
instance_a="${GCP_CATEGORY_LOGIC_INSTANCE_A:-kestra-dev-gce-a}"
instance_b="${GCP_CATEGORY_LOGIC_INSTANCE_B:-kestra-dev-gce-b}"
expected_machine_type="${GCP_CATEGORY_LOGIC_MACHINE_TYPE:-e2-small}"
worker_container="${KESTRA_WORKER_CONTAINER:-kestra-worker_kestra-worker_1}"
ssh_user="${GCP_CATEGORY_LOGIC_SSH_USER:-$(id -un)}"
ssh_key="${GCP_CATEGORY_LOGIC_SSH_KEY:-${HOME}/.ssh/google_compute_engine}"
stop_after_verify="${GCP_STOP_AFTER_VERIFY:-true}"
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/kestra-gcp-category-logic.XXXXXX")"
inventory="${runtime_dir}/inventory.ini"
ssh_config="${runtime_dir}/ssh_config"
release_store="${runtime_dir}/release-store"
image="localhost/kestra-category/orders:current"
revision="$(git rev-parse --short=12 HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  revision="${revision}-dirty"
fi
build_id="$(date -u +%Y%m%d%H%M%S)"
dev_version="dev-gcp-${build_id}"
staging_version="1.1.0-gcp-${build_id}"

stop_instances() {
  if [[ "$stop_after_verify" == "true" ]]; then
    echo "Stopping the two GCE workers to cap test cost."
    gcloud compute instances stop "$instance_a" "$instance_b" \
      --project "$project_id" --zone "$zone" --quiet || true
  fi
}

cleanup() {
  stop_instances
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

for instance in "$instance_a" "$instance_b"; do
  machine_type="$(gcloud compute instances describe "$instance" \
    --project "$project_id" --zone "$zone" --format='value(machineType.basename())')"
  if [[ "$machine_type" != "$expected_machine_type" ]]; then
    echo "Instance ${instance} uses ${machine_type}; expected low-cost ${expected_machine_type}." >&2
    exit 1
  fi
done

gcloud compute instances start "$instance_a" "$instance_b" \
  --project "$project_id" --zone "$zone" --quiet >/dev/null

instance_a_id="$(gcloud compute instances describe "$instance_a" \
  --project "$project_id" --zone "$zone" --format='value(id)')"
instance_b_id="$(gcloud compute instances describe "$instance_b" \
  --project "$project_id" --zone "$zone" --format='value(id)')"

cat >"$ssh_config" <<EOF
Host kestra-gcp-a
  HostName compute.${instance_a_id}
  HostKeyAlias compute.${instance_a_id}
  User ${ssh_user}
  IdentityFile ${ssh_key}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand gcloud compute start-iap-tunnel ${instance_a} %p --listen-on-stdin --project=${project_id} --zone=${zone} --verbosity=warning

Host kestra-gcp-b
  HostName compute.${instance_b_id}
  HostKeyAlias compute.${instance_b_id}
  User ${ssh_user}
  IdentityFile ${ssh_key}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand gcloud compute start-iap-tunnel ${instance_b} %p --listen-on-stdin --project=${project_id} --zone=${zone} --verbosity=warning
EOF

for host in kestra-gcp-a kestra-gcp-b; do
  connected=false
  for _ in {1..12}; do
    if ssh -F "$ssh_config" -o ConnectTimeout=10 "$host" true; then
      connected=true
      break
    fi
    sleep 5
  done
  if [[ "$connected" != "true" ]]; then
    echo "Cannot reach ${host} through IAP." >&2
    exit 1
  fi
done

kestra_url="https://${LIVE_GKE_SUBDOMAIN:-k8s}.${live_domain_name}"
kestra_username="$(gcloud secrets versions access latest \
  --project "$project_id" --secret kestra-dev-gke-kestra-basic-auth-username)"
kestra_password="$(gcloud secrets versions access latest \
  --project "$project_id" --secret kestra-dev-gke-kestra-basic-auth-password)"
for _ in {1..120}; do
  if curl --fail --silent --show-error --max-time 20 \
    --user "${kestra_username}:${kestra_password}" "${kestra_url}/" >/dev/null; then
    break
  fi
  sleep 10
done
if ! curl --fail --silent --show-error --max-time 20 \
  --user "${kestra_username}:${kestra_password}" "${kestra_url}/" >/dev/null; then
  echo "Kestra did not become ready: ${kestra_url}" >&2
  exit 1
fi

for host in kestra-gcp-a kestra-gcp-b; do
  ssh -F "$ssh_config" "$host" \
    'for _ in {1..120}; do state="$(systemctl is-system-running 2>/dev/null || true)"; if [[ "$state" == "running" || "$state" == "degraded" ]]; then exit 0; fi; sleep 5; done; exit 1'
done

for host in kestra-gcp-a kestra-gcp-b; do
  if ! ssh -F "$ssh_config" "$host" \
    "docker container inspect ${worker_container}" \
    | grep -Fq '"Destination": "/var/run/docker.sock"'; then
    ssh -F "$ssh_config" "$host" \
      "sudo mkdir -p /tmp/kestra-wd && sudo sed -i 's#/tmp/kestra-worker-wd:/tmp/kestra-wd#/tmp/kestra-wd:/tmp/kestra-wd#' /opt/kestra-worker/docker-compose.yml && sudo sed -i '\|application.yaml:/etc/kestra/application.yaml:ro|a\      - /var/run/docker.sock:/var/run/docker.sock' /opt/kestra-worker/docker-compose.yml && if docker compose version >/dev/null 2>&1; then sudo docker compose -f /opt/kestra-worker/docker-compose.yml --env-file /opt/kestra-worker/.env up -d --force-recreate; else sudo docker-compose -f /opt/kestra-worker/docker-compose.yml --env-file /opt/kestra-worker/.env up -d --force-recreate; fi"
  fi
done

wait_for_worker_stability() {
  local host="$1"
  local worker_group="${host#kestra-gcp-}"
  local current_worker=""
  local previous_worker=""
  local stable_samples=0

  for _ in {1..36}; do
    current_worker="$(ssh -F "$ssh_config" "$host" \
      "docker container inspect ${worker_container}" \
      | jq -r '.[0] | [.Id, .State.StartedAt, .RestartCount, .State.Running] | @tsv')"
    if [[ "$current_worker" == *$'\ttrue' && "$current_worker" == "$previous_worker" ]]; then
      stable_samples=$((stable_samples + 1))
    else
      stable_samples=0
    fi
    if ((stable_samples >= 6)); then
      if ssh -F "$ssh_config" "$host" "docker logs --since 10m ${worker_container} 2>&1" \
        | grep -Fq "Connected to controller, workerGroup: gce-${worker_group}"; then
        return 0
      fi
    fi
    previous_worker="$current_worker"
    sleep 10
  done

  echo "Kestra worker on ${host} did not remain stable and controller-connected." >&2
  return 1
}

for host in kestra-gcp-a kestra-gcp-b; do
  wait_for_worker_stability "$host"
done

cat >"$inventory" <<EOF
[orders_workers]
kestra-gcp-a ansible_host=kestra-gcp-a
kestra-gcp-b ansible_host=kestra-gcp-b
EOF
export ANSIBLE_SSH_ARGS="-F ${ssh_config}"

timer_unit="${runtime_dir}/kestra-worker-nightly-poweroff.timer"
service_unit="${runtime_dir}/kestra-worker-nightly-poweroff.service"
cat >"$timer_unit" <<'EOF'
[Unit]
Description=Power off the Kestra GCE worker daily at 23:00 JST

[Timer]
OnCalendar=*-*-* 23:00:00 Asia/Tokyo
AccuracySec=1min
Unit=kestra-worker-nightly-poweroff.service

[Install]
WantedBy=timers.target
EOF
cat >"$service_unit" <<'EOF'
[Unit]
Description=Power off the Kestra GCE worker at the nightly cost boundary

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl poweroff
EOF

for host in kestra-gcp-a kestra-gcp-b; do
  scp -F "$ssh_config" "$timer_unit" "$service_unit" "${host}:/tmp/"
  ssh -F "$ssh_config" "$host" \
    "sudo install -m 0644 /tmp/kestra-worker-nightly-poweroff.timer /tmp/kestra-worker-nightly-poweroff.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now kestra-worker-nightly-poweroff.timer && systemctl list-timers kestra-worker-nightly-poweroff.timer --no-pager"
done

scripts/build-category-logic-bundle.sh \
  "${runtime_dir}/dev-bundle" "$dev_version" "$revision" "$image" >/dev/null
scripts/build-category-logic-bundle.sh \
  "${runtime_dir}/staging-bundle" "$staging_version" "$revision" "$image" >/dev/null
staging_release_directory="$(scripts/persist-category-logic-release.sh \
  "${runtime_dir}/staging-bundle" "$release_store")"

worker_a_before="$(ssh -F "$ssh_config" kestra-gcp-a \
  "docker container inspect ${worker_container}" | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"
worker_b_before="$(ssh -F "$ssh_config" kestra-gcp-b \
  "docker container inspect ${worker_container}" | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"

echo "Deploying the DEV main-push artifact to the shared low-cost GCE inventory."
scripts/deploy-category-logic-bundle.sh \
  "${runtime_dir}/dev-bundle" "$inventory" orders_workers "$worker_container" docker
scripts/verify-live-gcp-category-logic-flow.sh "$image" "$dev_version" "$revision"

echo "Deploying the persisted STAGING tag artifact to the same GCE inventory."
scripts/deploy-category-logic-bundle.sh \
  "$staging_release_directory" "$inventory" orders_workers "$worker_container" docker
scripts/audit-category-logic-ansible.sh \
  "$inventory" orders_workers "$image" "$staging_version" "$revision" "$worker_container" docker
scripts/verify-live-gcp-category-logic-flow.sh "$image" "$staging_version" "$revision"

worker_a_after="$(ssh -F "$ssh_config" kestra-gcp-a \
  "docker container inspect ${worker_container}" | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"
worker_b_after="$(ssh -F "$ssh_config" kestra-gcp-b \
  "docker container inspect ${worker_container}" | jq -r '.[0] | [.Id, .State.StartedAt] | @tsv')"

if [[ "$worker_a_before" != "$worker_a_after" || "$worker_b_before" != "$worker_b_after" ]]; then
  echo "A Kestra worker restarted during the GCP category logic deployment." >&2
  exit 1
fi

printf 'GCP verification passed: version=%s revision=%s\n' "$staging_version" "$revision"
printf 'kestra-gcp-a worker=%s\n' "$worker_a_after"
printf 'kestra-gcp-b worker=%s\n' "$worker_b_after"
