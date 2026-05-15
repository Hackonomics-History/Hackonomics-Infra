output "kratos_db_password" {
  description = "Auto-generated Kratos internal DB password. Stored in terraform.tfstate."
  value       = random_password.kratos_db.result
  sensitive   = true
}

output "hydra_db_password" {
  description = "Auto-generated Hydra internal DB password. Stored in terraform.tfstate."
  value       = random_password.hydra_db.result
  sensitive   = true
}

output "grafana_url" {
  description = "Grafana UI — NodePort exposed on the host machine (dev only)."
  value       = "http://localhost:30300"
}

output "kratos_public_endpoint" {
  description = "Kratos public API endpoint (in-cluster)."
  value       = module.identity.kratos_public_endpoint
}
