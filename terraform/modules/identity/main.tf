# =============================================================================
# modules/identity — Ory Kratos + Ory Hydra
# =============================================================================
# Kratos manages user identities and self-service flows.
# Hydra is optional (disabled until the consent/login integration is wired).
#
# The DSN is injected as a sensitive set value so it never appears in plan
# output or state in plaintext (stored encrypted in terraform.tfstate).
#
# Cookie and cipher secrets are NOT set here — they come from the pre-created
# K8s Secret `hackonomics-kratos-env` (provisioned by setup-secrets.sh).
# Kratos expands them at runtime via ${KRATOS_COOKIE_SECRET} in the ConfigMap.
# =============================================================================

locals {
  charts_path      = "${path.root}/../helm/hackonomics-infra/charts"
  postgres_go_host = "${var.release_name}-postgres-go"
}

resource "helm_release" "kratos" {
  name      = "${var.release_name}-kratos"
  chart     = "${local.charts_path}/kratos"
  namespace = var.namespace

  # DSN injected as a sensitive value — not echoed in plan output.
  set_sensitive {
    name = "dsn"
    value = join("", [
      "postgres://kratos:${var.kratos_db_password}",
      "@${local.postgres_go_host}:5432/kratos",
      "?sslmode=disable&max_conns=20&max_idle_conns=4",
    ])
  }

  # K8s Secret containing KRATOS_COOKIE_SECRET, KRATOS_CIPHER_SECRET, and
  # OIDC client credentials — provisioned by setup-secrets.sh.
  set {
    name  = "existingSecret"
    value = "hackonomics-kratos-env"
  }

  wait    = true
  timeout = 300
}

resource "helm_release" "hydra" {
  count = var.hydra_enabled ? 1 : 0

  name      = "${var.release_name}-hydra"
  chart     = "${local.charts_path}/hydra"
  namespace = var.namespace

  set_sensitive {
    name = "dsn"
    value = join("", [
      "postgres://hydra:${var.hydra_db_password}",
      "@${local.postgres_go_host}:5432/hydra",
      "?sslmode=disable&max_conns=10&max_idle_conns=2",
    ])
  }

  set {
    name  = "existingSecret"
    value = "hackonomics-hydra-env"
  }

  # Hydra consent/login flows call into Kratos — Kratos must be ready first.
  depends_on = [helm_release.kratos]

  wait    = true
  timeout = 300
}
