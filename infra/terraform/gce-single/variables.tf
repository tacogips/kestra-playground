variable "project_id" {
  type        = string
  description = "Existing GCP project ID created by the bootstrap root."
}

variable "region" {
  type        = string
  description = "GCP region."
  default     = "asia-northeast1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the single VM."
  default     = "asia-northeast1-a"
}

variable "name_prefix" {
  type        = string
  description = "Resource name prefix."
  default     = "kestra-dev"
}

variable "kestra_basic_auth_username" {
  type        = string
  description = "Kestra Basic Auth username. Kestra OSS requires Basic Auth."
  default     = "admin@kestra.local"
}

variable "authorized_source_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to reach Kestra HTTP."
  default     = ["0.0.0.0/0"]
}

variable "iap_ssh_source_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to reach SSH for IAP TCP forwarding."
  default     = ["35.235.240.0/20"]
}

variable "domain_name" {
  type        = string
  description = "Parent DNS domain for HTTPS access, for example example.com. Leave empty to skip HTTPS/domain resources."
  default     = ""
}

variable "environment_name" {
  type        = string
  description = "Environment label used as the default subdomain when subdomain is empty."
  default     = "dev"
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
  description = "Whether Cloudflare should proxy the DNS record. Keep false for Google-managed certificate validation."
  default     = false
}
