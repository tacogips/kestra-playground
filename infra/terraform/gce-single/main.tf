provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
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

resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "Kestra single VM service account"
}

resource "terraform_data" "kestra_image" {
  triggers_replace = [var.kestra_image]
}

resource "google_project_iam_member" "artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_network" "main" {
  name                    = "${var.name_prefix}-network"
  auto_create_subnetworks = true
}

locals {
  secret_values = {
    postgres-db                = "kestra"
    postgres-user              = "kestra"
    postgres-password          = random_password.db.result
    batch-db                   = "ecommerce_ops"
    batch-db-user              = "kestra"
    batch-db-password          = random_password.db.result
    kestra-db-url              = "jdbc:postgresql://postgres:5432/kestra"
    kestra-db-username         = "kestra"
    kestra-db-password         = random_password.db.result
    kestra-basic-auth-username = var.kestra_basic_auth_username
    kestra-basic-auth-password = random_password.kestra_basic_auth.result
    batch-db-url               = "jdbc:postgresql://postgres:5432/ecommerce_ops"
    batch-db-username          = "kestra"
    batch-db-password          = random_password.db.result
  }
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = local.secret_values
  secret_id = "${var.name_prefix}-${each.key}"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "versions" {
  for_each = local.secret_values

  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value
}

resource "google_secret_manager_secret_iam_member" "vm_secret_reader" {
  for_each = google_secret_manager_secret.secrets

  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_compute_firewall" "kestra_http" {
  name    = "${var.name_prefix}-http"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = var.authorized_source_ranges
  target_tags   = ["kestra-single"]
}

resource "google_compute_firewall" "iap_ssh" {
  name    = "${var.name_prefix}-iap-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.iap_ssh_source_ranges
  target_tags   = ["kestra-single"]
}

resource "google_compute_firewall" "lb_health_check" {
  count = local.https_enabled ? 1 : 0

  name    = "${var.name_prefix}-lb-health-check"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["kestra-single"]
}

resource "google_compute_instance" "kestra" {
  name         = "${var.name_prefix}-single"
  machine_type = "e2-medium"
  zone         = var.zone
  tags         = ["kestra-single"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = google_compute_network.main.name
    access_config {}
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    artifact_registry_host = "${var.region}-docker.pkg.dev"
    kestra_image           = var.kestra_image
    project_id             = var.project_id
    name_prefix            = var.name_prefix
  })

  lifecycle {
    replace_triggered_by = [
      terraform_data.kestra_image,
    ]
  }

  depends_on = [
    google_project_iam_member.artifact_registry_reader,
    google_secret_manager_secret_iam_member.vm_secret_reader,
  ]
}

resource "google_compute_instance_group" "kestra" {
  count = local.https_enabled ? 1 : 0

  name      = "${var.name_prefix}-single"
  zone      = var.zone
  instances = [google_compute_instance.kestra.self_link]

  named_port {
    name = "http"
    port = 8080
  }
}

resource "google_compute_global_address" "https" {
  count = local.https_enabled ? 1 : 0

  name = "${var.name_prefix}-https"
}

resource "google_compute_health_check" "https" {
  count = local.https_enabled ? 1 : 0

  name = "${var.name_prefix}-https"

  http_health_check {
    port         = 8080
    request_path = "/ui/"
  }
}

resource "google_compute_backend_service" "https" {
  count = local.https_enabled ? 1 : 0

  name          = "${var.name_prefix}-https"
  protocol      = "HTTP"
  port_name     = "http"
  timeout_sec   = 30
  health_checks = [google_compute_health_check.https[0].id]
  security_policy = (
    var.cloud_armor_security_policy_self_link != "" ? var.cloud_armor_security_policy_self_link : null
  )

  backend {
    group = google_compute_instance_group.kestra[0].self_link
  }
}

resource "google_compute_managed_ssl_certificate" "https" {
  count = local.https_enabled ? 1 : 0

  name = "${var.name_prefix}-https"

  managed {
    domains = [local.hostname]
  }
}

resource "google_compute_url_map" "https" {
  count = local.https_enabled ? 1 : 0

  name            = "${var.name_prefix}-https"
  default_service = google_compute_backend_service.https[0].id
}

resource "google_compute_target_https_proxy" "https" {
  count = local.https_enabled ? 1 : 0

  name             = "${var.name_prefix}-https"
  url_map          = google_compute_url_map.https[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.https[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count = local.https_enabled ? 1 : 0

  name       = "${var.name_prefix}-https"
  target     = google_compute_target_https_proxy.https[0].id
  port_range = "443"
  ip_address = google_compute_global_address.https[0].address
}

resource "google_compute_url_map" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  name = "${var.name_prefix}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  name    = "${var.name_prefix}-http-redirect"
  url_map = google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  count = local.https_enabled ? 1 : 0

  name       = "${var.name_prefix}-http-redirect"
  target     = google_compute_target_http_proxy.http_redirect[0].id
  port_range = "80"
  ip_address = google_compute_global_address.https[0].address
}

resource "google_dns_managed_zone" "domain" {
  count = local.google_dns_enabled && var.create_dns_zone ? 1 : 0

  name        = local.dns_zone_name
  dns_name    = "${local.domain_name}."
  description = "Managed zone for Kestra playground ${var.environment_name}"
}

data "google_dns_managed_zone" "domain" {
  count = local.google_dns_enabled && !var.create_dns_zone ? 1 : 0

  name = local.dns_zone_name
}

resource "google_dns_record_set" "https" {
  count = local.google_dns_enabled ? 1 : 0

  name         = local.fqdn
  managed_zone = var.create_dns_zone ? google_dns_managed_zone.domain[0].name : data.google_dns_managed_zone.domain[0].name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.https[0].address]
}

resource "cloudflare_dns_record" "https" {
  count = local.cloudflare_dns_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.hostname
  type    = "A"
  content = google_compute_global_address.https[0].address
  ttl     = 1
  proxied = var.cloudflare_dns_proxied
  comment = "Kestra ${var.environment_name} HTTPS load balancer managed by Terraform"
}

output "kestra_url" {
  value = "http://${google_compute_instance.kestra.network_interface[0].access_config[0].nat_ip}:8080"
}

output "kestra_https_url" {
  value = local.https_enabled ? "https://${local.hostname}" : null
}

output "https_ip_address" {
  value = local.https_enabled ? google_compute_global_address.https[0].address : null
}

output "dns_name_servers" {
  value = local.google_dns_enabled && var.create_dns_zone ? google_dns_managed_zone.domain[0].name_servers : []
}

output "kestra_image" {
  value = var.kestra_image
}
