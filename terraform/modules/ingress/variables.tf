variable "environment" {
  type    = string
  default = "dev"
}

variable "monitoring_namespace" {
  description = "Monitoring namespace — used only to decide resource sizing."
  type        = string
  default     = "monitoring"
}
