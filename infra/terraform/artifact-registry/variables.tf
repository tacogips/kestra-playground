variable "project_id" {
  type        = string
  description = "GCP project that hosts the Artifact Registry repository."
}

variable "region" {
  type        = string
  description = "Artifact Registry location."
  default     = "asia-northeast1"
}

variable "repository_id" {
  type        = string
  description = "Repository ID of the private Python package registry."
  default     = "python-batch-libs"
}

variable "reader_members" {
  type        = list(string)
  description = "IAM members granted artifactregistry.reader (batch workers, SSH targets)."
  default     = []
}

variable "writer_members" {
  type        = list(string)
  description = "IAM members granted artifactregistry.writer (publishers, CI)."
  default     = []
}
