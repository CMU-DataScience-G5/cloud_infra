# Triton Inference Server on the GPU pool. Loads models straight from the weights
# bucket and polls it, so publishing a new version directory rolls out new weights
# without a redeploy.

resource "kubernetes_service_account_v1" "triton" {
  metadata {
    name      = "triton"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.infra.gsa_emails.triton
    }
  }
}

resource "kubernetes_deployment_v1" "triton" {
  metadata {
    name      = "triton"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "triton" }
  }

  # GPU node may need to be created by the autoscaler and the image is large.
  wait_for_rollout = false

  spec {
    replicas = var.triton_replicas

    selector {
      match_labels = { app = "triton" }
    }

    strategy {
      # Only one GPU per node: don't try to surge a second pod onto it.
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "triton" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8002"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.triton.metadata[0].name

        node_selector = {
          "cloud.google.com/gke-accelerator" = local.infra.gpu_type
        }

        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "triton"
          image = var.triton_image

          args = [
            "tritonserver",
            "--model-repository=gs://${local.infra.weights_bucket}/model_repository",
            "--model-control-mode=poll",
            "--repository-poll-secs=60",
            "--strict-readiness=false",
            "--exit-on-error=false",
            "--log-verbose=0",
          ]

          port {
            name           = "http"
            container_port = 8000
          }
          port {
            name           = "grpc"
            container_port = 8001
          }
          port {
            name           = "metrics"
            container_port = 8002
          }

          resources {
            requests = { cpu = "4", memory = "16Gi", "nvidia.com/gpu" = "1" }
            limits   = { memory = "24Gi", "nvidia.com/gpu" = "1" }
          }

          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }

          # TensorRT engine cache (see trt_engine_cache_path in config.pbtxt).
          volume_mount {
            name       = "trt-cache"
            mount_path = "/trt_cache"
          }

          startup_probe {
            http_get {
              path = "/v2/health/live"
              port = 8000
            }
            period_seconds    = 10
            failure_threshold = 60
          }

          liveness_probe {
            http_get {
              path = "/v2/health/live"
              port = 8000
            }
            period_seconds = 15
          }

          readiness_probe {
            http_get {
              path = "/v2/health/ready"
              port = 8000
            }
            period_seconds = 10
          }
        }

        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "4Gi"
          }
        }

        # Survives container restarts on the same pod (not pod replacement), so a crash
        # doesn't force a multi-minute TensorRT rebuild.
        volume {
          name = "trt-cache"
          empty_dir {
            size_limit = "10Gi"
          }
        }
      }
    }
  }

  # Allow `kubectl rollout restart deploy/triton` (e.g. to re-read the model repository)
  # without Terraform reverting it on the next apply.
  lifecycle {
    ignore_changes = [spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"]]
  }
}

resource "kubernetes_service_v1" "triton" {
  metadata {
    name      = "triton"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    selector = { app = "triton" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
    port {
      name        = "grpc"
      port        = 8001
      target_port = 8001
    }
    port {
      name        = "metrics"
      port        = 8002
      target_port = 8002
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
