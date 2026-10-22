# Gateway: authentication (API key), routing, load balancing (GKE Ingress -> external HTTP(S) LB).

resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "gateway" {
  metadata {
    name      = "gateway-api-keys"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    # Comma-separated list; add more keys here to onboard more clients.
    API_KEYS = random_password.api_key.result
  }
}

resource "kubernetes_deployment_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "gateway" }
  }

  spec {
    replicas = var.gateway_replicas

    selector {
      match_labels = { app = "gateway" }
    }

    template {
      metadata {
        labels = { app = "gateway" }
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
        node_selector                    = { pool = "system" }

        container {
          name  = "gateway"
          image = var.gateway_image

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "CONTROLLER_URL"
            value = "http://controller.${kubernetes_namespace_v1.app.metadata[0].name}.svc.cluster.local:8080"
          }
          env {
            name  = "MAX_UPLOAD_MB"
            value = tostring(var.max_upload_mb)
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.gateway.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { memory = "3Gi" }
          }

          # GKE Ingress derives the load balancer health check from this probe.
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

resource "kubernetes_horizontal_pod_autoscaler_v2" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    min_replicas = var.gateway_replicas
    max_replicas = max(var.gateway_replicas, 6)

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.gateway.metadata[0].name
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

# BackendConfig: long timeout for large uploads + 3D inference.
resource "kubernetes_manifest" "gateway_backendconfig" {
  manifest = {
    apiVersion = "cloud.google.com/v1"
    kind       = "BackendConfig"
    metadata = {
      name      = "gateway"
      namespace = kubernetes_namespace_v1.app.metadata[0].name
    }
    spec = {
      timeoutSec = 900
      connectionDraining = {
        drainingTimeoutSec = 60
      }
      healthCheck = {
        type        = "HTTP"
        requestPath = "/healthz"
        port        = 8080
      }
    }
  }
}

resource "kubernetes_service_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "cloud.google.com/neg"            = jsonencode({ ingress = true })
      "cloud.google.com/backend-config" = jsonencode({ default = "gateway" })
    }
  }

  spec {
    type     = "ClusterIP"
    selector = { app = "gateway" }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }

  depends_on = [kubernetes_manifest.gateway_backendconfig]

  # GKE manages these on its own (auto-NEG for VPC-native clusters).
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["cloud.google.com/neg"],
      metadata[0].annotations["cloud.google.com/neg-status"],
    ]
  }
}

resource "kubernetes_manifest" "gateway_cert" {
  count = var.domain == "" ? 0 : 1

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "ManagedCertificate"
    metadata = {
      name      = "gateway"
      namespace = kubernetes_namespace_v1.app.metadata[0].name
    }
    spec = {
      domains = [var.domain]
    }
  }
}

resource "kubernetes_ingress_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = merge(
      {
        "kubernetes.io/ingress.class"                 = "gce"
        "kubernetes.io/ingress.global-static-ip-name" = local.infra.gateway_ip_name
      },
      var.domain == "" ? {} : {
        "networking.gke.io/managed-certificates" = "gateway"
      }
    )
  }

  # Allowlist: only the public API reaches the gateway. Everything else (notably the
  # unauthenticated /metrics that Prometheus scrapes in-cluster) falls through to GKE's
  # default backend, which answers 404.
  spec {
    rule {
      http {
        path {
          path      = "/v1/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.gateway.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
        path {
          path      = "/healthz"
          path_type = "Exact"
          backend {
            service {
              name = kubernetes_service_v1.gateway.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.gateway_cert]
}

resource "kubernetes_pod_disruption_budget_v1" "gateway" {
  metadata {
    name      = "gateway"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    min_available = 1
    selector {
      match_labels = { app = "gateway" }
    }
  }
}
