output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_location" {
  value = google_container_cluster.this.location
}

output "app_namespace" {
  value = local.app_namespace
}

output "monitoring_namespace" {
  value = local.monitoring_namespace
}

output "data_bucket" {
  value = google_storage_bucket.data.name
}

output "weights_bucket" {
  value = google_storage_bucket.weights.name
}

output "image_repo" {
  description = "Docker repository prefix for gateway/controller images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "gateway_ip_name" {
  value = google_compute_global_address.gateway.name
}

output "gateway_ip" {
  value = google_compute_global_address.gateway.address
}

output "ui_ips" {
  description = "Static IP name + address for each public monitoring UI."
  value = {
    for k, a in google_compute_global_address.ui : k => { name = a.name, address = a.address }
  }
}

output "gsa_emails" {
  value = {
    controller = google_service_account.workload["controller"].email
    triton     = google_service_account.workload["triton"].email
    grafana    = google_service_account.workload["grafana"].email
    trainer    = google_service_account.trainer.email
    build      = google_service_account.build.email
  }
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${google_container_cluster.this.location} --project ${var.project_id}"
}

output "gpu_type" {
  value = var.gpu_type
}
