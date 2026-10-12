terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  # The sample data is uploaded with Entra auth, not the account key.
  storage_use_azuread = true
}

# The Defender CSPM plan (CloudPosture) and its sensitive data discovery extension are
# enabled at subscription level outside this config, so destroying the lab leaves the
# plan as it was. Check it with: az security pricing show -n CloudPosture

variable "location" {
  type    = string
  default = "eastus"
}

# East US had no capacity for small VM sizes during the build, so the VM and its
# network can sit in a different region from the data and AI resources.
variable "vm_location" {
  type    = string
  default = "centralindia"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2as_v2"
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-posture"
  location = var.location
}

# ---------------------------------------------------------------------------
# DSPM target: a storage account with a publicly readable container holding
# synthetic customer records (test card numbers and made up SSNs).
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "data" {
  name                            = "stposture${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = true
  public_network_access_enabled   = true
  shared_access_key_enabled       = true
}

# Lets the signed in user write the sample blobs over Entra auth.
resource "azurerm_role_assignment" "me_blob" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac" {
  depends_on      = [azurerm_role_assignment.me_blob]
  create_duration = "90s"
}

resource "azurerm_storage_container" "exports" {
  name                  = "customer-exports"
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "blob"
  depends_on            = [time_sleep.rbac]
}

resource "azurerm_storage_blob" "customers" {
  name                 = "customers-2026-q3.csv"
  storage_container_id = azurerm_storage_container.exports.id
  type                 = "Block"
  content_type         = "text/csv"
  source               = "${path.module}/sample-data/customers-2026-q3.csv"
}

# ---------------------------------------------------------------------------
# AI-SPM target: a Foundry resource with a model deployment, left on key auth
# and an open public endpoint.
# ---------------------------------------------------------------------------
resource "azurerm_cognitive_account" "ai" {
  name                          = "foundry-posture-${random_string.suffix.result}"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  kind                          = "AIServices"
  sku_name                      = "S0"
  custom_subdomain_name         = "foundry-posture-${random_string.suffix.result}"
  local_auth_enabled            = true
  public_network_access_enabled = true
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = "chat-dep"
  cognitive_account_id = azurerm_cognitive_account.ai.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1-mini"
    version = "2025-04-14"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 1
  }
}

# ---------------------------------------------------------------------------
# CSPM attack path source: an internet exposed VM on an older Ubuntu image whose
# managed identity can read the sensitive container and call the model.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-posture"
  location            = var.vm_location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.50.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.50.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-web-posture"
  location            = var.vm_location
  resource_group_name = azurerm_resource_group.lab.name

  # Deliberately open to the internet so Defender treats the VM as exposed.
  # Login is key only, and the private key never leaves Terraform state.
  security_rule {
    name                       = "allow-ssh-internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-web-posture"
  location            = var.vm_location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-web-posture"
  location            = var.vm_location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-web-posture"
  location                        = var.vm_location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Ubuntu 20.04 is past standard support, so agentless scanning has
  # unpatched packages to report.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "vm_blob" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}

resource "azurerm_role_assignment" "vm_ai" {
  scope                = azurerm_cognitive_account.ai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_linux_virtual_machine.vm.identity[0].principal_id
}

output "storage_account" {
  value = azurerm_storage_account.data.name
}

output "foundry_account" {
  value = azurerm_cognitive_account.ai.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.vm.name
}
