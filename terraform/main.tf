# =============================================================================
# main.tf — Root Terraform module for Hackonomics-Infra
# =============================================================================
# Replaces setup-infra.sh with declarative IaC.
#
# Deployment order (mirrors the sync-wave order in ArgoCD):
#   -1  ingress    — Traefik + CRD wait (IngressRoutes depend on these CRDs)
#    0  monitoring — kube-prometheus-stack, Loki (independent of app workloads)
#    0  databases  — Postgres (Go + Django), Redis (Go + Django)
#    0  messaging  — Kafka (KRaft, single-node dev)
#    1  identity   — Kratos (depends on postgres-go), Hydra (optional)
#
# Prerequisites before running `terraform apply`:
#   1. k3d cluster running:  k3d cluster create hackonomics-dev ...
#   2. K8s Secrets provisioned: bash scripts/setup-secrets.sh
#   3. kubeconfig pointing at the cluster: kubectl config use-context k3d-hackonomics-dev
#
# Usage:
#   terraform init
#   terraform apply -var-file=environments/dev.tfvars
# =============================================================================

# ── Internal generated passwords ─────────────────────────────────────────────
# random_password generates once and persists the value in terraform.tfstate.
# Stable across subsequent applies unless the resource is tainted or destroyed.
# terraform.tfstate is gitignored and must be treated as a secret.

resource "random_password" "kratos_db" {
  length  = 32
  special = false
}

resource "random_password" "hydra_db" {
  length  = 32
  special = false
}

# ── Namespaces ────────────────────────────────────────────────────────────────
# Created once here so all modules can assume they exist.
# ignore_changes on annotations/labels lets ArgoCD or cluster operators add
# their own metadata without Terraform reverting it on the next apply.

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
}

# ── Wave -1: Ingress (Traefik) ────────────────────────────────────────────────
# Must complete before other modules because IngressRoute CRDs must be
# established before any IngressRoute resources are created.

module "ingress" {
  source = "./modules/ingress"

  environment          = var.environment
  monitoring_namespace = var.monitoring_namespace
}

# ── Wave 0: Monitoring stack ──────────────────────────────────────────────────
# Independent of app workloads; runs in parallel with databases and messaging.

module "monitoring" {
  source = "./modules/monitoring"

  environment          = var.environment
  monitoring_namespace = var.monitoring_namespace
  namespace            = var.namespace
  release_name         = var.release_name

  depends_on = [
    kubernetes_namespace.monitoring,
    module.ingress,
  ]
}

# ── Wave 0: Databases ─────────────────────────────────────────────────────────
# K8s Secrets (hackonomics-postgres-go, etc.) must exist BEFORE this runs.
# Run `bash scripts/setup-secrets.sh` first, or use the CI provision-secrets job.

module "databases" {
  source = "./modules/databases"

  environment  = var.environment
  namespace    = var.namespace
  release_name = var.release_name

  depends_on = [
    kubernetes_namespace.app,
    module.ingress,
  ]
}

# ── Wave 0: Messaging ─────────────────────────────────────────────────────────
# Kafka KRaft (single-node). kafka_cluster_id must be stable across restarts.

module "messaging" {
  source = "./modules/messaging"

  environment      = var.environment
  namespace        = var.namespace
  release_name     = var.release_name
  kafka_cluster_id = var.kafka_cluster_id

  depends_on = [
    kubernetes_namespace.app,
    module.ingress,
  ]
}

# ── Wave 1: Identity ──────────────────────────────────────────────────────────
# Kratos needs the postgres-go StatefulSet to be Ready before running migrations.

module "identity" {
  source = "./modules/identity"

  environment        = var.environment
  namespace          = var.namespace
  release_name       = var.release_name
  kratos_db_password = random_password.kratos_db.result
  hydra_db_password  = random_password.hydra_db.result
  hydra_enabled      = var.hydra_enabled

  depends_on = [module.databases]
}
