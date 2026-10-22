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
