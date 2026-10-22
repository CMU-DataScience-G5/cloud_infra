# Public HTTPS access to the Grafana and Kibana web UIs, each behind its own Google
# external load balancer with a Google-managed certificate. Hostnames use sslip.io
# (<name>.<ip-with-dashes>.sslip.io resolves to <ip>), so no domain purchase is needed.
# Both UIs keep their own login; one shared admin account works for both.
# Prometheus has no built-in auth and stays private; query it via Grafana -> Explore.

locals {
  ui = {
    grafana = {
      namespace   = kubernetes_namespace_v1.monitoring.metadata[0].name
      service     = "kps-grafana"
      port        = 80
      health_path = "/api/health"
      health_port = 3000
    }
    kibana = {
      namespace   = kubernetes_namespace_v1.logging.metadata[0].name
      service     = "kibana-kb-http"
      port        = 5601
      health_path = "/login"
      health_port = 5601
    }
  }

  ui_hosts = {
    for k, ip in local.infra.ui_ips : k => "${k}.${replace(ip.address, ".", "-")}.sslip.io"
  }
}

resource "kubernetes_manifest" "ui_backendconfig" {
  for_each = local.ui

  manifest = {
    apiVersion = "cloud.google.com/v1"
    kind       = "BackendConfig"
    metadata   = { name = "${each.key}-ui", namespace = each.value.namespace }
    spec = {
      timeoutSec = 300
      healthCheck = {
        type        = "HTTP"
        requestPath = each.value.health_path
        port        = each.value.health_port
      }
    }
  }
}

resource "kubernetes_manifest" "ui_cert" {
  for_each = local.ui

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "ManagedCertificate"
    metadata   = { name = "${each.key}-ui", namespace = each.value.namespace }
    spec       = { domains = [local.ui_hosts[each.key]] }
  }
}

# Redirect plain HTTP to HTTPS so passwords are never sent unencrypted.
resource "kubernetes_manifest" "ui_https_redirect" {
  for_each = local.ui

  manifest = {
    apiVersion = "networking.gke.io/v1beta1"
    kind       = "FrontendConfig"
    metadata   = { name = "${each.key}-ui", namespace = each.value.namespace }
    spec = {
      redirectToHttps = { enabled = true, responseCodeName = "MOVED_PERMANENTLY_DEFAULT" }
    }
  }
}

resource "kubernetes_ingress_v1" "ui" {
  for_each = local.ui

  metadata {
    name      = "${each.key}-ui"
    namespace = each.value.namespace
    annotations = {
      "kubernetes.io/ingress.class"                 = "gce"
      "kubernetes.io/ingress.global-static-ip-name" = local.infra.ui_ips[each.key].name
      "networking.gke.io/managed-certificates"      = kubernetes_manifest.ui_cert[each.key].manifest.metadata.name
      "networking.gke.io/v1beta1.FrontendConfig"    = kubernetes_manifest.ui_https_redirect[each.key].manifest.metadata.name
    }
  }

  spec {
    default_backend {
      service {
        name = each.value.service
        port {
          number = each.value.port
        }
      }
    }
  }

  depends_on = [
    kubernetes_manifest.ui_backendconfig,
    helm_release.kube_prometheus_stack,
    helm_release.eck_stack,
  ]
}

# Kibana login "admin" with the same password as Grafana's admin, via the Elasticsearch
# file realm (ECK reads kubernetes.io/basic-auth secrets listed in spec.auth.fileRealm).
resource "kubernetes_secret_v1" "kibana_admin" {
  metadata {
    name      = "monitoring-admin"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = var.monitoring_admin_user
    password = random_password.grafana_admin.result
    roles    = "superuser"
  }
}
