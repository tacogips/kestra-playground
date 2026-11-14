terraform {
  backend "gcs" {
    prefix = "gke-dev"
  }
}
