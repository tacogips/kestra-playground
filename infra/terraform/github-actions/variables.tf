variable "project_id" {
  type        = string
  description = "GCP project ID that GitHub Actions can deploy to."
  default     = "kestra-playground-260625"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to impersonate the deploy service account."
  default     = "tacogips/kestra-playground"
}

variable "github_ref" {
  type        = string
  description = "Git ref allowed to impersonate the deploy service account."
  default     = "refs/heads/main"
}
