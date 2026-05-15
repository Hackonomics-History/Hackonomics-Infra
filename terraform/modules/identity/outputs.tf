output "kratos_public_endpoint" {
  description = "In-cluster Kratos public API endpoint."
  value       = "http://${helm_release.kratos.name}:4433"
}

output "kratos_admin_endpoint" {
  description = "In-cluster Kratos admin API endpoint."
  value       = "http://${helm_release.kratos.name}:4434"
}

output "hydra_public_endpoint" {
  description = "In-cluster Hydra public OAuth2 endpoint (null when hydra_enabled=false)."
  value       = var.hydra_enabled ? "http://${helm_release.hydra[0].name}:4444" : null
}
