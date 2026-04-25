output "grafana_nodeport" {
  description = "NodePort on which Grafana is reachable at http://localhost:<nodePort> (dev only)."
  value       = 30300
}

output "prometheus_service" {
  description = "In-cluster Prometheus service (for port-forwarding)."
  value       = "svc/kube-prometheus-stack-prometheus.${var.monitoring_namespace}"
}

output "loki_gateway" {
  description = "Loki gateway URL for Promtail push target."
  value       = "http://loki-gateway.${var.monitoring_namespace}.svc.cluster.local/loki/api/v1/push"
}
