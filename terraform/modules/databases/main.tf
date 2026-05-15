# =============================================================================
# modules/databases — Postgres (Go + Django) and Redis (Go + Django)
# =============================================================================
# Manages four Helm releases using the local sub-charts from
# helm/hackonomics-infra/charts/. Credentials are read from pre-created
# K8s Secrets (hackonomics-postgres-go, etc.) via existingSecret — Terraform
# never touches the secret values directly.
#
# PRE-REQUISITE: Run `bash scripts/setup-secrets.sh` before `terraform apply`
# so that the K8s Secrets exist when Helm tries to reference them.
# =============================================================================

locals {
  charts_path = "${path.root}/../helm/hackonomics-infra/charts"
}

resource "helm_release" "postgres_go" {
  name      = "${var.release_name}-postgres-go"
  chart     = "${local.charts_path}/postgres-go"
  namespace = var.namespace

  set {
    name  = "existingSecret"
    value = "hackonomics-postgres-go"
  }

  wait    = true
  timeout = 300
}

resource "helm_release" "postgres_django" {
  name      = "${var.release_name}-postgres-django"
  chart     = "${local.charts_path}/postgres-django"
  namespace = var.namespace

  set {
    name  = "existingSecret"
    value = "hackonomics-postgres-django"
  }

  wait    = true
  timeout = 300
}

resource "helm_release" "redis_go" {
  name      = "${var.release_name}-redis-go"
  chart     = "${local.charts_path}/redis-go"
  namespace = var.namespace

  set {
    name  = "existingSecret"
    value = "hackonomics-redis-go"
  }

  wait    = true
  timeout = 180
}

resource "helm_release" "redis_django" {
  name      = "${var.release_name}-redis-django"
  chart     = "${local.charts_path}/redis-django"
  namespace = var.namespace

  set {
    name  = "existingSecret"
    value = "hackonomics-redis-django"
  }

  wait    = true
  timeout = 180
}
