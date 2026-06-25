terraform {
  backend "gcs" {
    bucket = "example-project-id-tofu-state"
    prefix = "gce-single"
  }
}
