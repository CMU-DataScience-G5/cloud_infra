terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.20, < 8.0"
    }
  }

  # State lives in a GCS bucket created by scripts/bootstrap.sh.
  # Run: terraform init -backend-config="bucket=<STATE_BUCKET>"
  backend "gcs" {
    prefix = "ctseg/infra"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
