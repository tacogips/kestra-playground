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
  description = "GCP zone used by the optional external GCE worker."
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

variable "external_gce_worker_enabled" {
  type        = bool
  description = "Create one external GCE Kestra worker attached to the GKE dev control plane. Worker-group routing requires Kestra Enterprise."
  default     = false
}

variable "external_gce_worker_group_key" {
  type        = string
  description = "Kestra Worker Group key used by the optional external GCE worker."
  default     = "gce-heavy"

  validation {
    condition     = trimspace(var.external_gce_worker_group_key) != ""
    error_message = "external_gce_worker_group_key must not be empty."
  }
}

variable "external_gce_worker_machine_type" {
  type        = string
  description = "Machine type for the optional external GCE worker."
  default     = "n1-standard-4"
}

variable "external_gce_worker_boot_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB for the optional external GCE worker."
  default     = 50
}

variable "external_gce_worker_threads" {
  type        = number
  description = "Kestra worker thread count for the optional external GCE worker."
  default     = 8
}

variable "external_gce_worker_gpu_type" {
  type        = string
  description = "Optional guest accelerator type for the external GCE worker, for example nvidia-tesla-t4. Leave empty for CPU-only."
  default     = ""
}

variable "external_gce_worker_gpu_count" {
  type        = number
  description = "Optional guest accelerator count for the external GCE worker."
  default     = 0

  validation {
    condition     = var.external_gce_worker_gpu_count >= 0
    error_message = "external_gce_worker_gpu_count must be zero or greater."
  }
}

variable "external_gce_worker_iap_ssh_source_ranges" {
  type        = list(string)
  description = "Source CIDR ranges allowed to SSH to the external GCE worker through IAP."
  default     = ["35.235.240.0/20"]
}
