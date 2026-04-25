variable "environment" {
  type    = string
  default = "dev"
}

variable "namespace" {
  type    = string
  default = "hackonomics"
}

variable "release_name" {
  type    = string
  default = "hackonomics"
}

variable "kafka_cluster_id" {
  description = "Stable Kafka KRaft cluster ID. Must not change after first apply."
  type        = string
}
