# =============================================================================
# modules/ingress — Traefik v3 ingress controller
# =============================================================================
# Deploys Traefik from the upstream Helm repo into kube-system.
# Waits for IngressRoute and Middleware CRDs to be established so that
# subsequent modules can create Traefik resources without a race condition.
#
# Values file: argocd/values/traefik-<environment>.yaml
# This is the SAME values file used by the ArgoCD Application, so Terraform
# and ArgoCD stay in sync without duplicating values.
# =============================================================================

# Map logical environment names to the values file suffix convention:
#   dev  → traefik-k3s-dev.yaml  (matches existing argocd/values/ filenames)
#   prod → traefik-prod.yaml
locals {
  values_suffix = var.environment == "dev" ? "k3s-dev" : var.environment
}

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "30.1.0"
  namespace        = "kube-system"
  create_namespace = false # kube-system always exists in k3s/k3d

  values = [
    file("${path.root}/../argocd/values/traefik-${local.values_suffix}.yaml")
  ]

  wait    = true
  timeout = 300
}

# Wait for Traefik's CRDs to reach the Established condition.
# Other modules (especially infra sub-charts that render IngressRoutes) must not
# start until these CRDs exist, otherwise the Kubernetes API rejects the apply.
resource "null_resource" "traefik_crd_ready" {
  depends_on = [helm_release.traefik]

  triggers = {
    traefik_version = helm_release.traefik.version
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait \
        --for=condition=established \
        --timeout=60s \
        crd/ingressroutes.traefik.io \
        crd/middlewares.traefik.io \
        crd/tlsstores.traefik.io
    EOT
  }
}
