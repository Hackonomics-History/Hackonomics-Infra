# Both providers share the same kubeconfig / context so all resources land in
# the same cluster. Override kubeconfig_path and kube_context in the relevant
# .tfvars file when pointing at a different cluster (e.g. prod).

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
