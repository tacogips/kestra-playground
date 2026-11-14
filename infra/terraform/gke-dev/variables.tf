variable "project_id" {
  type        = string
  description = "Existing GCP project ID."
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "GCP region."
}

variable "zone" {
  type        = string
  default     = "asia-northeast1-a"
  description = "GCP zone used by the GCE controller worker."
}

variable "gke_autopilot_enabled" {
  type        = bool
  default     = true
  description = "Use GKE Autopilot for the cluster. Set false to create a GKE Standard cluster with autoscaled node pools."
}

variable "gke_standard_node_pools" {
  type = map(object({
    machine_type = string
    min_count    = number
    max_count    = number
    disk_size_gb = number
    labels       = map(string)
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = {
    small = {
      machine_type = "e2-standard-2"
      min_count    = 0
      max_count    = 3
      disk_size_gb = 30
      labels = {
        "kestra.tacogips.io/worker-group" = "gke-small"
      }
      taints = [
        {
          key    = "kestra.tacogips.io/worker-group"
          value  = "gke-small"
          effect = "NO_SCHEDULE"
        }
      ]
    }
    large = {
      machine_type = "e2-standard-8"
      min_count    = 0
      max_count    = 3
      disk_size_gb = 50
      labels = {
        "kestra.tacogips.io/worker-group" = "gke-large"
      }
      taints = [
        {
          key    = "kestra.tacogips.io/worker-group"
          value  = "gke-large"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }
  description = "Autoscaled GKE Standard node pools used for exact worker-class placement when gke_autopilot_enabled is false."
}

variable "controller_worker_enabled" {
  type        = bool
  default     = true
  description = "Create a GCE VM that runs Kestra worker against the GKE controller backend."
}

variable "controller_worker_machine_type" {
  type        = string
  default     = "e2-small"
  description = "Machine type for the GCE controller worker VM."
}

variable "controller_worker_threads" {
  type        = number
  default     = 4
  description = "Kestra worker thread count for the GCE controller worker VM."
}

variable "routed_workers" {
  type = map(object({
    worker_group_id = string
    machine_type    = string
    threads         = number
  }))
  default = {
    gce-a = {
      worker_group_id = "gce-a"
      machine_type    = "e2-small"
      threads         = 2
    }
    gce-b = {
      worker_group_id = "gce-b"
      machine_type    = "e2-small"
      threads         = 2
    }
  }
  description = "GCE worker VMs that attach to the GKE Kestra backend with static OSS worker group IDs."
}

variable "name_prefix" {
  type        = string
  default     = "kestra-dev"
  description = "Resource name prefix."
}

variable "kestra_basic_auth_username" {
  type        = string
  description = "Kestra Basic Auth username. Kestra OSS requires Basic Auth."
  default     = "admin@example.com"
}

variable "kestra_image" {
  type        = string
  description = "Container image used for the Kestra runtime."
  default     = "kestra/kestra:latest"
}

variable "sql_tier" {
  type        = string
  default     = "db-g1-small"
  description = "Small Cloud SQL tier with enough connection headroom for autoscaled Kestra services."
}

variable "domain_name" {
  type        = string
  description = "Parent DNS domain for HTTPS access, for example example.com. Leave empty to skip HTTPS/domain resources."
  default     = ""
}

variable "environment_name" {
  type        = string
  description = "Environment label used as the default subdomain when subdomain is empty."
  default     = "gke-dev"
}

variable "subdomain" {
  type        = string
  description = "Subdomain label for this environment. Defaults to environment_name."
  default     = ""
}

variable "create_dns_zone" {
  type        = bool
  description = "Create a Cloud DNS managed zone for domain_name when dns_provider is google. Set false to use an existing zone."
  default     = true
}

variable "dns_zone_name" {
  type        = string
  description = "Cloud DNS managed zone name. Required when create_dns_zone is false; optional name override when creating a zone."
  default     = ""
}

variable "dns_provider" {
  type        = string
  description = "DNS provider used for the environment hostname. Supported values: google, cloudflare, none."
  default     = "google"

  validation {
    condition     = contains(["google", "cloudflare", "none"], var.dns_provider)
    error_message = "dns_provider must be one of: google, cloudflare, none."
  }
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for domain_name when dns_provider is cloudflare."
  default     = ""
  sensitive   = true
}

variable "cloudflare_dns_proxied" {
  type        = bool
  description = "Whether Cloudflare should proxy the DNS record. Keep false for GKE-managed certificate validation."
  default     = false
}

variable "cloud_armor_security_policy_name" {
  type        = string
  description = "Optional Cloud Armor security policy name to attach through the GKE BackendConfig."
  default     = ""
}
