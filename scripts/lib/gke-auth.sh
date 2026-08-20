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
