provider "google" {
  project = var.project_id
  region  = var.region
}

provider "cloudflare" {}

data "google_project" "current" {
  project_id = var.project_id
}

locals {
  https_enabled          = var.domain_name != ""
  domain_name            = trimsuffix(var.domain_name, ".")
  subdomain              = var.subdomain != "" ? var.subdomain : var.environment_name
  hostname               = local.https_enabled ? "${local.subdomain}.${local.domain_name}" : ""
  fqdn                   = local.https_enabled ? "${local.hostname}." : ""
  dns_zone_name          = var.dns_zone_name != "" ? var.dns_zone_name : "${var.name_prefix}-${replace(local.domain_name, ".", "-")}"
  google_dns_enabled     = local.https_enabled && var.dns_provider == "google"
  cloudflare_dns_enabled = local.https_enabled && var.dns_provider == "cloudflare"
  kestra_url             = local.https_enabled ? "https://${local.hostname}" : "http://localhost:8080/"
  kestra_database_name   = "kestra"
  batch_database_name    = "ecommerce_ops"

  kestra_basic_auth_secret_values = {
    kestra-basic-auth-username = var.kestra_basic_auth_username
    kestra-basic-auth-password = random_password.kestra_basic_auth.result
  }

  gke_runtime_secret_values = {
    kestra-db-url      = "jdbc:postgresql://127.0.0.1:5432/${local.kestra_database_name}"
    kestra-db-username = google_sql_user.kestra.name
    kestra-db-password = random_password.db.result
    batch-db-url       = "jdbc:postgresql://127.0.0.1:5432/${local.batch_database_name}"
    batch-db-username  = google_sql_user.kestra.name
    batch-db-password  = random_password.db.result
    cloud-sql-instance = google_sql_database_instance.postgres.connection_name
    kestra-gcs-bucket  = google_storage_bucket.storage.name
  }

}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "random_password" "kestra_basic_auth" {
  length  = 32
  special = false
}

resource "random_id" "bucket" {
  byte_length = 4
}

resource "google_service_account" "kestra" {
  account_id   = "${var.name_prefix}-gke"
  display_name = "Kestra GKE workload identity service account"
}

resource "google_secret_manager_secret" "kestra_basic_auth" {
  for_each  = local.kestra_basic_auth_secret_values
  secret_id = "${var.name_prefix}-gke-${each.key}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "kestra_basic_auth" {
  for_each = local.kestra_basic_auth_secret_values

  secret      = google_secret_manager_secret.kestra_basic_auth[each.key].id
  secret_data = each.value
}

resource "google_secret_manager_secret_iam_member" "kestra_basic_auth_reader" {
  for_each = google_secret_manager_secret.kestra_basic_auth

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.kestra.email}"
}

resource "google_secret_manager_secret" "gke_runtime" {
  for_each = local.gke_runtime_secret_values

  secret_id = "${var.name_prefix}-gke-${each.key}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "gke_runtime" {
  for_each = local.gke_runtime_secret_values

  secret      = google_secret_manager_secret.gke_runtime[each.key].id
  secret_data = each.value
}

resource "google_secret_manager_secret_iam_member" "gke_runtime_reader" {
  for_each = google_secret_manager_secret.gke_runtime

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.kestra.email}"
}

resource "google_container_cluster" "kestra" {
  name             = var.name_prefix
  location         = var.region
  enable_autopilot = true

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = false
}

resource "google_storage_bucket" "storage" {
  name                        = "${var.project_id}-${var.name_prefix}-storage-${random_id.bucket.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_storage_bucket_iam_member" "storage" {
  bucket = google_storage_bucket.storage.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.kestra.email}"
}

resource "google_sql_database_instance" "postgres" {
  name             = "${var.name_prefix}-postgres"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier              = var.sql_tier
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_HDD"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled = true
    }
  }

  deletion_protection = false
}

resource "google_sql_database" "kestra" {
  name     = local.kestra_database_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_database" "batch" {
  name     = local.batch_database_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "kestra" {
  name     = "kestra"
  instance = google_sql_database_instance.postgres.name
  password = random_password.db.result
}

resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.kestra.email}"
}

resource "google_project_iam_member" "artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.kestra.email}"
}

resource "google_project_iam_member" "gke_node_artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.kestra.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[kestra-dev/kestra]"

  depends_on = [
    google_container_cluster.kestra,
  ]
}

resource "google_compute_global_address" "ingress" {
  count = local.https_enabled ? 1 : 0

  name = "${var.name_prefix}-ingress"
}

resource "google_dns_managed_zone" "domain" {
  count = local.google_dns_enabled && var.create_dns_zone ? 1 : 0

  name        = local.dns_zone_name
  dns_name    = "${local.domain_name}."
  description = "Managed zone for Kestra GKE playground ${var.environment_name}"
}

data "google_dns_managed_zone" "domain" {
  count = local.google_dns_enabled && !var.create_dns_zone ? 1 : 0

  name = local.dns_zone_name
}

resource "google_dns_record_set" "ingress" {
  count = local.google_dns_enabled ? 1 : 0

  name         = local.fqdn
  managed_zone = var.create_dns_zone ? google_dns_managed_zone.domain[0].name : data.google_dns_managed_zone.domain[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ingress[0].address]
}

resource "cloudflare_dns_record" "ingress" {
  count = local.cloudflare_dns_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.hostname
  type    = "A"
  content = google_compute_global_address.ingress[0].address
  ttl     = 1
  proxied = var.cloudflare_dns_proxied
  comment = "Kestra ${var.environment_name} GKE ingress managed by Terraform"
}

output "cluster_name" {
  value = google_container_cluster.kestra.name
}

output "project_id" {
  value = var.project_id
}

output "cloud_sql_instance" {
  value = google_sql_database_instance.postgres.connection_name
}

output "gcs_bucket" {
  value = google_storage_bucket.storage.name
}

output "gcp_service_account" {
  value = google_service_account.kestra.email
}

output "kubernetes_secret_ids" {
  value = {
    CLOUD_SQL_INSTANCE                 = google_secret_manager_secret.gke_runtime["cloud-sql-instance"].secret_id
    ENV_BATCH_DB_PASSWORD              = google_secret_manager_secret.gke_runtime["batch-db-password"].secret_id
    ENV_BATCH_DB_URL                   = google_secret_manager_secret.gke_runtime["batch-db-url"].secret_id
    ENV_BATCH_DB_USERNAME              = google_secret_manager_secret.gke_runtime["batch-db-username"].secret_id
    KESTRA_BASIC_AUTH_PASSWORD         = google_secret_manager_secret.kestra_basic_auth["kestra-basic-auth-password"].secret_id
    KESTRA_BASIC_AUTH_USERNAME         = google_secret_manager_secret.kestra_basic_auth["kestra-basic-auth-username"].secret_id
    KESTRA_DB_PASSWORD                 = google_secret_manager_secret.gke_runtime["kestra-db-password"].secret_id
    KESTRA_DB_URL                      = google_secret_manager_secret.gke_runtime["kestra-db-url"].secret_id
    KESTRA_DB_USERNAME                 = google_secret_manager_secret.gke_runtime["kestra-db-username"].secret_id
    KESTRA_GCS_BUCKET                  = google_secret_manager_secret.gke_runtime["kestra-gcs-bucket"].secret_id
    KESTRA_SERVER_BASIC__AUTH_PASSWORD = google_secret_manager_secret.kestra_basic_auth["kestra-basic-auth-password"].secret_id
    KESTRA_SERVER_BASIC__AUTH_USERNAME = google_secret_manager_secret.kestra_basic_auth["kestra-basic-auth-username"].secret_id
  }
}

output "kestra_image" {
  value = var.kestra_image
}

output "kestra_https_url" {
  value = local.https_enabled ? "https://${local.hostname}" : null
}

output "ingress_static_ip_name" {
  value = local.https_enabled ? google_compute_global_address.ingress[0].name : null
}

output "ingress_static_ip_address" {
  value = local.https_enabled ? google_compute_global_address.ingress[0].address : null
}

output "cloud_armor_security_policy_name" {
  value = var.cloud_armor_security_policy_name
}

output "dns_name_servers" {
  value = local.google_dns_enabled && var.create_dns_zone ? google_dns_managed_zone.domain[0].name_servers : []
}
