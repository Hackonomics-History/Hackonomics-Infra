# =============================================================================
# modules/monitoring — kube-prometheus-stack + Loki + Grafana datasource
# =============================================================================
# Both charts are pulled from their upstream Helm repos; values live in
# argocd/values/ so ArgoCD Applications and Terraform share a single source
# of truth for chart configuration.
#
# Resource sizing is tuned for a 3-agent Mac k3d cluster (≈12 GiB RAM).
# Adjust argocd/values/kube-prometheus-stack-<env>.yaml for prod sizing.
# =============================================================================

# Map logical environment names to the values file suffix convention:
#   dev  → kube-prometheus-stack-k3s-dev.yaml
#   prod → kube-prometheus-stack-prod.yaml
locals {
  values_suffix = var.environment == "dev" ? "k3s-dev" : var.environment
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.1.3"
  namespace        = var.monitoring_namespace
  create_namespace = true

  values = [
    file("${path.root}/../argocd/values/kube-prometheus-stack-${local.values_suffix}.yaml")
  ]

  wait    = true
  timeout = 600
}

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.7.4"
  namespace        = var.monitoring_namespace
  create_namespace = true

  values = [
    file("${path.root}/../argocd/values/loki-${local.values_suffix}.yaml")
  ]

  wait    = true
  timeout = 600
}

# Wire Loki as a Grafana datasource using ConfigMap-based provisioning.
# The sidecar in kube-prometheus-stack watches for ConfigMaps with label
# grafana_datasource=1 and automatically loads them as datasources.
resource "kubernetes_config_map" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-loki-datasource"
    namespace = var.monitoring_namespace
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki.yaml" = <<-YAML
      apiVersion: 1
      datasources:
        - name: Loki
          type: loki
          access: proxy
          url: http://loki-gateway.${var.monitoring_namespace}.svc.cluster.local
          isDefault: false
          jsonData:
            httpHeaderName1: X-Scope-OrgID
          secureJsonData:
            httpHeaderValue1: ${var.release_name}
    YAML
  }

  depends_on = [helm_release.kube_prometheus_stack, helm_release.loki]
}
