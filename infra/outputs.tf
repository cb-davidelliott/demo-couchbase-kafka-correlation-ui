output "vm_public_ip" {
  value       = azurerm_public_ip.pip.ip_address
  description = "The public IP address of the deployed Linux VM."
}

output "ssh_private_key" {
  value       = tls_private_key.ssh_key.private_key_pem
  description = "The private SSH key to access the VM if needed."
  sensitive   = true
}
