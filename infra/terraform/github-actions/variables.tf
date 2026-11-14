variable "project_id" {
  type        = string
  description = "GCP project ID that GitHub Actions can deploy to."
  default     = "kestra-playground-260625"
}

variable "region" {
  type        = string
  description = "GCP region for deployment support resources."
  default     = "asia-northeast1"
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry Docker repository ID for Kestra playground images."
  default     = "kestra-playground"
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
