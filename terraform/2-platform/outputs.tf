output "gateway_url" {
  value = var.domain == "" ? "http://${local.infra.gateway_ip}" : "https://${var.domain}"
}

output "api_key" {
  description = "Client API key (send as X-API-Key). Read with: terraform output -raw api_key"
  value       = random_password.api_key.result
  sensitive   = true
}

output "monitoring_urls" {
  description = "Public Grafana and Kibana (HTTPS; the certificate can take 15-60 min after first apply)."
  value       = { for k, h in local.ui_hosts : k => "https://${h}" }
}

output "monitoring_admin_user" {
  value = var.monitoring_admin_user
}

output "monitoring_admin_password" {
  description = "Shared admin password for Grafana and Kibana. Read with: terraform output -raw monitoring_admin_password"
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "access_commands" {
  value = {
    grafana       = "kubectl -n ${local.infra.monitoring_namespace} port-forward svc/kps-grafana 3000:80   # http://localhost:3000"
    prometheus    = "kubectl -n ${local.infra.monitoring_namespace} port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090"
    kibana        = "kubectl -n logging port-forward svc/kibana-kb-http 5601:5601   # http://localhost:5601"
    kibana_passwd = "kubectl -n logging get secret elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}'   # user: elastic"
    triton        = "kubectl -n ${local.infra.app_namespace} port-forward svc/triton 8000:8000"
  }
}
