output "kafka_bootstrap_servers" {
  description = "In-cluster Kafka bootstrap server address."
  value       = "${helm_release.kafka.name}:9092"
}

output "kafka_release_name" {
  value = helm_release.kafka.name
}
