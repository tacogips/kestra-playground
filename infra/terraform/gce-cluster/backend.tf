terraform {
  backend "gcs" {
    prefix = "gce-cluster"
  }
}
