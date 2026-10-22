# Data Storage: uploaded CT volumes (ct/<job_id>/) and segmentation masks (masks/<job_id>/).
resource "google_storage_bucket" "data" {
  name                        = "${var.project_id}-${var.name_prefix}-data"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy_buckets

  dynamic "lifecycle_rule" {
    for_each = var.data_retention_days > 0 ? [1] : []
    content {
      condition {
        age = var.data_retention_days
      }
      action {
        type = "Delete"
      }
    }
  }

  depends_on = [google_project_service.apis]
}

# Trained Weights: Triton model repository (model_repository/<model>/<version>/...).
# Versioned so a bad publish can be rolled back.
resource "google_storage_bucket" "weights" {
  name                        = "${var.project_id}-${var.name_prefix}-weights"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy_buckets

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository" "images" {
  repository_id = "${var.name_prefix}-images"
  location      = var.region
  format        = "DOCKER"
  description   = "Gateway and controller images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  depends_on = [google_project_service.apis]
}
