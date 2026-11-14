provider "google" {}

resource "google_artifact_registry_repository" "python_batch_libs" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  description   = "Private Python registry for shared batch libraries (kestra-batch-common)."
  format        = "PYTHON"
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.reader_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.python_batch_libs.location
  repository = google_artifact_registry_repository.python_batch_libs.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = toset(var.writer_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.python_batch_libs.location
  repository = google_artifact_registry_repository.python_batch_libs.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

output "repository_name" {
  value = google_artifact_registry_repository.python_batch_libs.name
}

output "python_index_url" {
  description = "pip/uv simple index URL for installs."
  value       = "https://${var.region}-python.pkg.dev/${var.project_id}/${var.repository_id}/simple/"
}

output "python_upload_url" {
  description = "Upload endpoint for uv publish / twine."
  value       = "https://${var.region}-python.pkg.dev/${var.project_id}/${var.repository_id}/"
}
