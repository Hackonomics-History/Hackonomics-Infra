# =============================================================================
# modules/messaging — Kafka (KRaft, single-node)
# =============================================================================
# kafka_cluster_id MUST be stable across applies.  The first `terraform apply`
# generates it (or reads it from environments/dev.tfvars); never taint or
# destroy this resource without also wiping the PVC, otherwise Kafka will
# refuse to start with a mismatched cluster ID.
# =============================================================================

resource "helm_release" "kafka" {
  name      = "${var.release_name}-kafka"
  chart     = "${path.root}/../helm/hackonomics-infra/charts/kafka"
  namespace = var.namespace

  set {
    name  = "clusterId"
    value = var.kafka_cluster_id
  }

  # advertisedHost must match the K8s Service name so in-cluster producers and
  # consumers can resolve the broker address.
  set {
    name  = "advertisedHost"
    value = "${var.release_name}-kafka"
  }

  wait    = true
  timeout = 420
}
