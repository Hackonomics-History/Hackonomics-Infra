variable "environment" {
  type    = string
  default = "dev"
}

variable "monitoring_namespace" {
  type    = string
  default = "monitoring"
}

variable "namespace" {
  description = "App namespace — used for the Loki X-Scope-OrgID tenant label."
  type        = string
  default     = "hackonomics"
}

variable "release_name" {
  description = "Release name used as the Loki tenant ID."
  type        = string
  default     = "hackonomics"
}
