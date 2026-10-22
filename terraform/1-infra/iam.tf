# One Google service account per workload, bound to a Kubernetes service account
# via Workload Identity. No JSON keys are created for in-cluster workloads.

locals {
  workloads = {
    controller = {
      namespace = local.app_namespace
      ksa       = "controller"
    }
    triton = {
      namespace = local.app_namespace
      ksa       = "triton"
    }
    grafana = {
      namespace = local.monitoring_namespace
      ksa       = "grafana"
    }
  }
}

resource "google_service_account" "workload" {
  for_each = local.workloads

  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "Workload Identity SA for ${each.key}"

  depends_on = [google_project_service.apis]
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = local.workloads

  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.namespace}/${each.value.ksa}]"

  # The workload pool only exists once the cluster does.
  depends_on = [google_container_cluster.this]
}

# Controller: read/write CT volumes and masks.
resource "google_storage_bucket_iam_member" "controller_data" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.workload["controller"].email}"
}

# Triton: read the model repository. objectViewer reads files; legacyBucketReader adds
# storage.buckets.get, which Triton's GCS filesystem checks before loading anything.
resource "google_storage_bucket_iam_member" "triton_weights" {
  for_each = toset(["roles/storage.objectViewer", "roles/storage.legacyBucketReader"])

  bucket = google_storage_bucket.weights.name
  role   = each.value
  member = "serviceAccount:${google_service_account.workload["triton"].email}"
}

# Grafana: query Cloud Monitoring (bucket size / object count).
resource "google_project_iam_member" "grafana_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.workload["grafana"].email}"
}

# Nodes pull images from Artifact Registry.
resource "google_artifact_registry_repository_iam_member" "nodes_pull" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes.email}"
}

# ---------------------------------------------------------------- Training pipeline

# Independent training pipeline: may only publish to the weights bucket.
# Use it via impersonation (gcloud --impersonate-service-account) or
# attach it to a Vertex AI / Compute training job.
resource "google_service_account" "trainer" {
  account_id   = "${var.name_prefix}-trainer"
  display_name = "Training pipeline (publishes trained weights)"

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "trainer_weights" {
  bucket = google_storage_bucket.weights.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.trainer.email}"
}

# ---------------------------------------------------------------- Cloud Build

resource "google_service_account" "build" {
  account_id   = "${var.name_prefix}-build"
  display_name = "Cloud Build image builder"

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "build_push" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/storage.objectViewer", # read uploaded build source
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.build.email}"
}
