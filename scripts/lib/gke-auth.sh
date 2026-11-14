#!/usr/bin/env bash
# Shared helper for scripts that talk to GKE with kubectl.
#
# kubectl authenticates to GKE through the gke-gcloud-auth-plugin client-go
# credential plugin. It ships as a gcloud component rather than with kubectl, so
# a fresh machine or CI runner has gcloud and kubectl but no plugin, and every
# kubectl call fails with "no Auth Provider found for name gcp" or
# "credential plugin ... not installed" only after the deploy is already halfway
# through.

ensure_gke_auth_plugin() {
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    return 0
  fi

  echo "Installing the gke-gcloud-auth-plugin gcloud component for kubectl."
  if ! gcloud components install gke-gcloud-auth-plugin --quiet; then
    echo "Failed to install gke-gcloud-auth-plugin; kubectl cannot authenticate to GKE." >&2
    return 1
  fi

  if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    echo "gke-gcloud-auth-plugin is still not on PATH after installation." >&2
    return 1
  fi
}

ensure_gcloud_account() {
  # google-github-actions/auth only writes an ADC credentials file. The gcloud
  # CLI keeps its own account list, and gke-gcloud-auth-plugin mints tokens by
  # shelling out to gcloud, so on a runner with no activated account it fails
  # with "failure while executing gcloud ... Please run gcloud auth login".
  if gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
    return 0
  fi

  if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    echo "No active gcloud account and no GOOGLE_APPLICATION_CREDENTIALS to activate one from." >&2
    return 1
  fi

  echo "Activating gcloud with the workload identity credentials file."
  gcloud auth login --cred-file="${GOOGLE_APPLICATION_CREDENTIALS}" --quiet
}

# Everything kubectl needs to reach a GKE cluster: the credential plugin binary
# and a gcloud account it can mint tokens with.
ensure_gke_kubectl_auth() {
  ensure_gcloud_account || return 1
  ensure_gke_auth_plugin || return 1
}
