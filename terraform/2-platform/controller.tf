# Main Process / Controller: task orchestration, data coordination (GCS), Triton client.

resource "kubernetes_service_account_v1" "controller" {
  metadata {
    name      = "controller"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.infra.gsa_emails.controller
    }
  }
}

resource "kubernetes_deployment_v1" "controller" {
  metadata {
    name      = "controller"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "controller" }
  }

  spec {
    replicas = var.controller_replicas

    selector {
      match_labels = { app = "controller" }
    }

    template {
      metadata {
        labels = { app = "controller" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/metrics"
          # Requests run for minutes; never let the cluster autoscaler drain this pod mid-request.
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
        }
      }

      spec {
        # On shutdown (rollout, upgrade), let in-flight segmentation requests finish.
        termination_grace_period_seconds = 900
        service_account_name             = kubernetes_service_account_v1.controller.metadata[0].name
        node_selector                    = { pool = "system" }

        container {
          name  = "controller"
          image = var.controller_image

          port {
            name           = "http"
            container_port = 8080
          }

          dynamic "env" {
            for_each = {
              DATA_BUCKET   = local.infra.data_bucket
              TRITON_URL    = "triton.${kubernetes_namespace_v1.app.metadata[0].name}.svc.cluster.local:8001"
              TASKS_JSON    = jsonencode(var.tasks)
              DEFAULT_TASK  = var.default_task
              TORCH_THREADS = "2"
            }
            content {
              name  = env.key
              value = env.value
            }
          }

          resources {
            # Resize/invert run on CPU; a 340^3 task keeps ~1 GB of logit + count maps.
            requests = { cpu = "2", memory = "4Gi" }
            limits   = { memory = "10Gi" }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }

          # Give the load balancer time to stop sending new requests before uvicorn gets
          # SIGTERM (uvicorn then waits for in-flight requests before exiting).
          lifecycle {
            pre_stop {
              exec {
                command = ["sleep", "15"]
              }
            }
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 20
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "controller" {
  metadata {
    name      = "controller"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    selector = { app = "controller" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }

  # GKE manages these on its own (auto-NEG for VPC-native clusters).
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["cloud.google.com/neg"],
      metadata[0].annotations["cloud.google.com/neg-status"],
    ]
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "controller" {
  metadata {
    name      = "controller"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    min_replicas = var.controller_replicas
    max_replicas = max(var.controller_replicas, 6)

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.controller.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "controller" {
  metadata {
    name      = "controller"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = { app = "controller" }
    }
  }
}
