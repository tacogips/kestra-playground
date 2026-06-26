provider "google" {
  project = var.project_id
}

locals {
  block_list_enabled = length(var.blocked_source_ranges) > 0
}

resource "google_compute_security_policy" "kestra" {
  name        = "${var.name_prefix}-cloud-armor"
  description = "Shared Cloud Armor policy for Kestra playground HTTPS endpoints."

  dynamic "rule" {
    for_each = local.block_list_enabled ? [1] : []

    content {
      action      = "deny(403)"
      priority    = 1000
      description = "Deny explicitly blocked source ranges."
      preview     = var.preview

      match {
        versioned_expr = "SRC_IPS_V1"

        config {
          src_ip_ranges = var.blocked_source_ranges
        }
      }
    }
  }

  rule {
    action      = "throttle"
    priority    = 2000
    description = "Throttle high request rates per client IP."
    preview     = var.preview

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = var.rate_limit_requests_per_interval
        interval_sec = var.rate_limit_interval_sec
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default allow rule."

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

output "security_policy_name" {
  value = google_compute_security_policy.kestra.name
}

output "security_policy_self_link" {
  value = google_compute_security_policy.kestra.self_link
}
