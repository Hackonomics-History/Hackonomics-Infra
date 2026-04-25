variable "environment" {
  description = "Deployment environment. Controls which values-*.yaml files are loaded."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be 'dev' or 'prod'."
  }
}

variable "cluster_name" {
  description = "k3d cluster name (used in kube_context default)."
  type        = string
  default     = "hackonomics-dev"
}

variable "namespace" {
  description = "Primary application namespace where stateful workloads run."
  type        = string
  default     = "hackonomics"
}

variable "monitoring_namespace" {
  description = "Namespace for the monitoring stack (Prometheus, Grafana, Loki)."
  type        = string
  default     = "monitoring"
}

variable "release_name" {
  description = "Helm release name prefix. Sub-chart releases are named <release_name>-<component>."
  type        = string
  default     = "hackonomics"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file used by the helm and kubernetes providers."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context within the kubeconfig to use for all operations."
  type        = string
  default     = "k3d-hackonomics-dev"
}

variable "kafka_cluster_id" {
  description = <<-EOT
    Stable Kafka KRaft cluster ID. Must remain constant across pod restarts.
    Generate once with:  kafka-storage random-uuid
    Commit the result to environments/dev.tfvars — it is NOT a secret.
  EOT
  type        = string
  default     = "MkU3OEVBNTcwNTJENDM2Qg"
}

variable "hydra_enabled" {
  description = "Deploy Ory Hydra alongside Kratos. Disabled until Kratos consent flow is wired up."
  type        = bool
  default     = false
}
