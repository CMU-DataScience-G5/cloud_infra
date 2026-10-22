resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = local.infra.app_namespace
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = local.infra.monitoring_namespace
  }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata {
    name = "logging"
  }
}

resource "kubernetes_namespace_v1" "elastic_system" {
  metadata {
    name = "elastic-system"
  }
}
