output "postgres_go_service" {
  description = "In-cluster hostname:port for the Go-stack Postgres instance."
  value       = "${helm_release.postgres_go.name}:5432"
}

output "postgres_django_service" {
  description = "In-cluster hostname:port for the Django-stack Postgres instance."
  value       = "${helm_release.postgres_django.name}:5432"
}

output "redis_go_service" {
  description = "In-cluster hostname:port for the Go-stack Redis instance."
  value       = "${helm_release.redis_go.name}:6379"
}

output "redis_django_service" {
  description = "In-cluster hostname:port for the Django-stack Redis instance."
  value       = "${helm_release.redis_django.name}:6379"
}
