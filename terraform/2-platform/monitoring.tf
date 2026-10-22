# Prometheus + Grafana (kube-prometheus-stack).
# Scrapes gateway/controller/Triton via pod annotations (HTTP throughput, inference
# latency, GPU utilization) and reads GCS bucket metrics from Cloud Monitoring.

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "91.9.0"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  timeout    = 900

  values = [
    templatefile("${path.module}/values/kube-prometheus-stack.yaml.tftpl", {
      grafana_admin_user     = var.monitoring_admin_user
      grafana_admin_password = random_password.grafana_admin.result
      grafana_host           = local.ui_hosts["grafana"]
      grafana_gsa            = local.infra.gsa_emails.grafana
      project_id             = local.infra.project_id
      app_namespace          = local.infra.app_namespace
      dashboard_json = indent(10, templatefile("${path.module}/dashboards/ctseg.json.tftpl", {
        project_id     = local.infra.project_id
        app_namespace  = local.infra.app_namespace
        data_bucket    = local.infra.data_bucket
        weights_bucket = local.infra.weights_bucket
      }))
    })
  ]
}
