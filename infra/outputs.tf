output "vm_public_ip" {
  value       = azurerm_public_ip.pip.ip_address
  description = "The public IP address of the deployed Linux VM."
}

output "ssh_private_key" {
  value       = tls_private_key.ssh_key.private_key_pem
  description = "The private SSH key to access the VM."
  sensitive   = true
}

output "couchbase_connection_string" {
  value       = couchbase-capella_cluster.demo.connection_string
  description = "Couchbase Capella cluster connection string."
}

output "couchbase_username" {
  value       = couchbase-capella_database_credential.demo_user.name
  description = "Auto-generated Couchbase database username."
}

output "couchbase_password" {
  value       = random_password.db_password.result
  description = "Auto-generated Couchbase database password."
  sensitive   = true
}
