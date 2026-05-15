variable "environment" {
  type    = string
  default = "dev"
}

variable "namespace" {
  type    = string
  default = "hackonomics"
}

variable "release_name" {
  description = "Helm release name prefix. Releases are named <release_name>-<component>."
  type        = string
  default     = "hackonomics"
}
