output "deployment_name" {
  description = "Deployment name."
  value       = var.name
}

output "service_url" {
  description = "Externally advertised Firezone URL, derived from server_fqdn."
  value       = "https://${var.server_fqdn}"
}

output "wireguard_public_key" {
  description = "WireGuard server public key derived from wireguard_private_key; this is what client configs embed."
  value       = wireguard_asymmetric_key.server.public_key
}
