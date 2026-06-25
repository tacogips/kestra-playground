variable "project_id" {
  type        = string
  description = "Existing GCP project ID."
}

variable "region" {
  type        = string
  default     = "asia-northeast1"
  description = "GCP region."
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
