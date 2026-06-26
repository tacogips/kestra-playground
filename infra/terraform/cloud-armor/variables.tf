variable "project_id" {
  type        = string
  description = "Existing GCP project ID."
}

variable "name_prefix" {
  type        = string
  description = "Resource name prefix."
  default     = "kestra-dev"
}

variable "rate_limit_requests_per_interval" {
  type        = number
  description = "Per-client request count that triggers Cloud Armor throttling."
  default     = 300
}

variable "rate_limit_interval_sec" {
  type        = number
  description = "Cloud Armor rate limit interval in seconds."
  default     = 60
}

variable "blocked_source_ranges" {
  type        = list(string)
  description = "Optional source IP CIDR ranges to deny before rate limiting."
  default     = []
}

variable "preview" {
  type        = bool
  description = "Evaluate Cloud Armor rules in preview mode without enforcement."
  default     = false
}
