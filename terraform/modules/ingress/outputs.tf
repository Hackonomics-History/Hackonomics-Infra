output "traefik_release_name" {
  description = "Name of the Traefik Helm release."
  value       = helm_release.traefik.name
}

output "traefik_version" {
  description = "Deployed Traefik chart version."
  value       = helm_release.traefik.version
}

output "crd_ready" {
  description = "Sentinel: true once Traefik CRDs are established. Use as depends_on target."
  value       = null_resource.traefik_crd_ready.id != "" ? true : false
}
