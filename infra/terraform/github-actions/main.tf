provider "google" {
  project = var.project_id
}

locals {
  terraform_state_bucket = "${var.project_id}-tofu-state"

  deploy_roles = toset([
    "roles/cloudsql.admin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
  ])
}

resource "google_artifact_registry_repository" "kestra" {
  location      = var.region
  repository_id = var.artifact_registry_repository_id
  description   = "Kestra playground runtime images."
  format        = "DOCKER"
}

resource "google_artifact_registry_repository_iam_member" "github_actions_writer" {
  location   = google_artifact_registry_repository.kestra.location
  repository = google_artifact_registry_repository.kestra.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_storage_bucket" "terraform_state" {
  name                        = local.terraform_state_bucket
  location                    = "asia-northeast1"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "github-actions-deployer"
  display_name = "GitHub Actions Kestra deployer"
}

resource "google_iam_workload_identity_pool" "github_actions" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC identity pool for GitHub Actions deployments."
}

resource "google_iam_workload_identity_pool_provider" "github_actions" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"
  description                        = "GitHub Actions OIDC provider for ${var.github_repository}."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.workflow"   = "assertion.workflow"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.ref == '${var.github_ref}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_actions_workload_identity" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}

resource "google_project_iam_member" "github_actions_deploy" {
  for_each = local.deploy_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github_actions.name
}

output "service_account_email" {
  value = google_service_account.github_actions.email
}

output "artifact_registry_repository" {
  value = "${google_artifact_registry_repository.kestra.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.kestra.repository_id}"
}
