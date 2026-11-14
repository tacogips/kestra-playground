variable "project_id" {
  type        = string
  description = "GCP project ID that GitHub Actions can deploy to."
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

variable "github_release_tag_prefixes" {
  type        = list(string)
  description = <<-EOT
    Release tag prefixes allowed to impersonate the deploy service account.
    .github/workflows/deploy-batch-groups.yml deploys a batch group when a tag
    with one of these prefixes is pushed, and the OIDC token for a tag push
    carries refs/tags/<tag> rather than the branch ref, so the tags need their own
    entries in the provider attribute condition.
  EOT
  default     = ["EC-", "AFFILIATE-"]
}
