provider "google" {
  project = var.project_id
  region  = var.region
}

provider "cloudflare" {}

locals {
  https_enabled          = var.domain_name != ""
  domain_name            = trimsuffix(var.domain_name, ".")
  subdomain              = var.subdomain != "" ? var.subdomain : var.environment_name
  hostname               = local.https_enabled ? "${local.subdomain}.${local.domain_name}" : ""
  fqdn                   = local.https_enabled ? "${local.hostname}." : ""
  dns_zone_name          = var.dns_zone_name != "" ? var.dns_zone_name : "${var.name_prefix}-${replace(local.domain_name, ".", "-")}"
  google_dns_enabled     = local.https_enabled && var.dns_provider == "google"
  cloudflare_dns_enabled = local.https_enabled && var.dns_provider == "cloudflare"
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
  name     = "kestra"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_database" "batch" {
  name     = "ecommerce_ops"
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

output "cloud_sql_instance" {
  value = google_sql_database_instance.postgres.connection_name
}

output "gcs_bucket" {
  value = google_storage_bucket.storage.name
}

output "gcp_service_account" {
  value = google_service_account.kestra.email
}

output "kubernetes_secret_values" {
  sensitive = true
  value = {
    KESTRA_DB_URL              = "jdbc:postgresql://127.0.0.1:5432/kestra"
    KESTRA_DB_USERNAME         = google_sql_user.kestra.name
    KESTRA_DB_PASSWORD         = random_password.db.result
    KESTRA_GCS_BUCKET          = google_storage_bucket.storage.name
    KESTRA_BASIC_AUTH_USERNAME = var.kestra_basic_auth_username
    KESTRA_BASIC_AUTH_PASSWORD = random_password.kestra_basic_auth.result
    ENV_BATCH_DB_URL           = "jdbc:postgresql://127.0.0.1:5432/ecommerce_ops"
    ENV_BATCH_DB_USERNAME      = google_sql_user.kestra.name
    ENV_BATCH_DB_PASSWORD      = random_password.db.result
    CLOUD_SQL_INSTANCE         = google_sql_database_instance.postgres.connection_name
    GCP_SERVICE_ACCOUNT        = google_service_account.kestra.email
  }
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

output "dns_name_servers" {
  value = local.google_dns_enabled && var.create_dns_zone ? google_dns_managed_zone.domain[0].name_servers : []
}
