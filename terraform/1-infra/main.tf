locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ]

  # Kubernetes namespaces / service accounts that get Workload Identity bindings.
  # Stage 2 (2-platform) creates the matching KSAs with these exact names.
  app_namespace        = "ctseg"
  monitoring_namespace = "monitoring"
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  service            = each.value
  disable_on_destroy = false
}

data "google_project" "this" {}
