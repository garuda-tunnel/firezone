output "deployment_name" {
  description = "Deployment name."
  value       = var.name
}

output "service_url" {
  description = "Externally advertised Firezone URL, derived from server_fqdn."
  value       = "https://${var.server_fqdn}"
}
