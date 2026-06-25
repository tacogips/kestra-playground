terraform {
  backend "gcs" {
    bucket = "example-project-id-tofu-state"
    prefix = "gke-dev"
  }
}
