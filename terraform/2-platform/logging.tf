# EFK: Elasticsearch + Kibana via the ECK operator, Fluentd DaemonSet shipping
# all container logs. (GKE also keeps sending logs to Cloud Logging.)

resource "helm_release" "eck_operator" {
  name       = "eck-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  version    = "3.5.0"
  namespace  = kubernetes_namespace_v1.elastic_system.metadata[0].name

  values = [yamlencode({
    nodeSelector = { pool = "system" }
  })]
}

resource "helm_release" "eck_stack" {
  name       = "eck-stack"
  repository = "https://helm.elastic.co"
  chart      = "eck-stack"
  version    = "0.20.0"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [
    file("${path.module}/values/eck-stack.yaml"),
    # Public Kibana (ui.tf): load-balancer wiring, public URL and the shared admin login.
    yamlencode({
      "eck-elasticsearch" = {
        auth = { fileRealm = [{ secretName = kubernetes_secret_v1.kibana_admin.metadata[0].name }] }
      }
      "eck-kibana" = {
        config = { "server.publicBaseUrl" = "https://${local.ui_hosts["kibana"]}" }
        http = {
          service = {
            metadata = {
              annotations = {
                "cloud.google.com/neg"            = jsonencode({ ingress = true })
                "cloud.google.com/backend-config" = jsonencode({ default = "kibana-ui" })
              }
            }
          }
        }
      }
    }),
  ]

  depends_on = [helm_release.eck_operator]
}

resource "helm_release" "fluentd" {
  name       = "fluentd"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluentd"
  version    = "0.6.0"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  # Pods wait for the ECK-generated password secret, so don't block on readiness.
  wait = false

  values = [file("${path.module}/values/fluentd.yaml")]

  depends_on = [helm_release.eck_stack]
}

# Kibana keeps data views in Elasticsearch, so a fresh Elasticsearch volume starts with
# none and Discover shows nothing. This one-shot Job creates the k8s-logs-* data view
# (idempotent: override = true) and makes it the default.
resource "kubernetes_job_v1" "kibana_data_view" {
  metadata {
    name      = "kibana-data-view"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }

  spec {
    backoff_limit = 10

    template {
      metadata {}

      spec {
        restart_policy = "OnFailure"
        node_selector  = { pool = "system" }

        container {
          name    = "create"
          image   = "curlimages/curl:8.11.1"
          command = ["/bin/sh", "-ec"]
          args = [<<-EOT
            KB=http://kibana-kb-http.logging.svc:5601
            AUTH="elastic:$ES_PASSWORD"
            until curl -sf -o /dev/null -u "$AUTH" "$KB/api/status"; do echo "waiting for Kibana"; sleep 10; done
            curl -sf -u "$AUTH" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
              -X POST "$KB/api/data_views/data_view" \
              -d '{"data_view":{"id":"k8s-logs","title":"k8s-logs-*","name":"Kubernetes logs","timeFieldName":"@timestamp"},"override":true}'
            curl -sf -u "$AUTH" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
              -X POST "$KB/api/data_views/default" -d '{"data_view_id":"k8s-logs","force":true}'
            EOT
          ]

          env {
            name = "ES_PASSWORD"
            value_from {
              secret_key_ref {
                # Created by the ECK operator once Elasticsearch exists; the kubelet
                # retries until it does.
                name = "elasticsearch-es-elastic-user"
                key  = "elastic"
              }
            }
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "20m"
  }

  depends_on = [helm_release.eck_stack]
}
