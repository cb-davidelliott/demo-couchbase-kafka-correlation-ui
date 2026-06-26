resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Allow SSH
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow Redpanda Console
  security_rule {
    name                       = "RedpandaConsole"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow Demo UI
  security_rule {
    name                       = "DemoUI"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Port 9092 (Kafka/Redpanda) is intentionally NOT opened here.
  # All Kafka producers and consumers run on the VM itself. Use SSH port forwarding
  # if local Kafka tooling is needed: ssh -i <key.pem> -L 9092:localhost:9092 azureuser@<VM_IP>

  # Port 8083 (Kafka Connect REST) is intentionally NOT opened here.
  # The connector setup script runs on the VM itself and reaches localhost:8083.
  # Use SSH port forwarding to access the REST API for debugging:
  #   ssh -i <key.pem> -L 8083:localhost:8083 azureuser@<VM_IP>
}

resource "azurerm_network_interface" "nic" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# SSH Key generation for VM access (reproducible/automated, no manual SSH key setup)
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    admin_username                           = var.admin_username
    github_repo_url                          = var.github_repo_url
    couchbase_conn_str                       = "couchbases://${couchbase-capella_cluster.demo.connection_string}"
    couchbase_seed_nodes                     = couchbase-capella_cluster.demo.connection_string
    couchbase_username                       = couchbase-capella_database_credential.demo_user.name
    couchbase_password                       = random_password.db_password.result
    couchbase_bucket                         = var.couchbase_bucket
    couchbase_scope                          = var.couchbase_scope
    demo_preferred_incident_id               = var.demo_preferred_incident_id
    generator_profile                        = var.generator_profile
    generator_interval_seconds               = var.generator_interval_seconds
    generator_events_per_batch               = var.generator_events_per_batch
    generator_enable_otel_calls              = var.generator_enable_otel_calls
    generator_new_customer_probability       = var.generator_new_customer_probability
    generator_ticket_probability             = var.generator_ticket_probability
    generator_enable_metrics                 = var.generator_enable_metrics
    generator_enable_incident_updates        = var.generator_enable_incident_updates
    generator_unique_metric_docs             = var.generator_unique_metric_docs
    generator_log_every_n_events             = var.generator_log_every_n_events
    generator_flush_every_n_events           = var.generator_flush_every_n_events
    generator_incident_update_every_n_events = var.generator_incident_update_every_n_events
    generator_producer_linger_ms             = var.generator_producer_linger_ms
    generator_producer_batch_num_messages    = var.generator_producer_batch_num_messages
    generator_producer_queue_max_messages    = var.generator_producer_queue_max_messages
    generator_producer_compression           = var.generator_producer_compression
    generator_enterprise_account_count       = var.generator_enterprise_account_count
    generator_scenario                       = var.generator_scenario
    generator_incident_id                    = var.generator_incident_id
    generator_random_seed                    = var.generator_random_seed
    generator_max_active_customers           = var.generator_max_active_customers
  }))
}
