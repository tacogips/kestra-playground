terraform {
  backend "gcs" {
    bucket = "kestra-playground-260625-tofu-state"
    prefix = "github-actions"
  }
}
