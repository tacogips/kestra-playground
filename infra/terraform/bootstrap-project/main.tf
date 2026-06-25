provider "google" {}

locals {
  services = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project" "this" {
  project_id      = var.project_id
  name            = var.project_name
  billing_account = var.billing_account
  org_id          = var.folder_id == "" ? var.org_id : null
  folder_id       = var.folder_id == "" ? null : var.folder_id
}

resource "google_project_service" "required" {
  for_each = local.services

  project            = google_project.this.project_id
  service            = each.value
  disable_on_destroy = false
}

output "project_id" {
  value = google_project.this.project_id
}
