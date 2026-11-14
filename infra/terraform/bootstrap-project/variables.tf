variable "project_id" {
  type        = string
  description = "Globally unique ID for the new GCP project."
}

variable "project_name" {
  type        = string
  description = "Display name for the new GCP project."
  default     = "Kestra Playground Dev"
}

variable "billing_account" {
  type        = string
  description = "Billing account ID to attach to the new project."
}

variable "org_id" {
  type        = string
  description = "GCP organization ID. Leave empty when folder_id is used."
  default     = ""
}

variable "folder_id" {
  type        = string
  description = "GCP folder ID. Leave empty when org_id is used."
  default     = ""
}
