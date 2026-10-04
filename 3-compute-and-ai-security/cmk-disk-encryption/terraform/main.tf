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
      version = "~> 0.12"
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
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "vm_size" {
  type    = string
  default = "Standard_D2als_v7"
}

data "azurerm_client_config" "current" {}

# Purge protected vault names stay reserved after destroy, so each build gets
# a fresh suffix.
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-cmk"
  location = var.location
}

# Azure refuses to back a Disk Encryption Set with a vault that allows
# permanent key deletion, so purge protection is required.
resource "azurerm_key_vault" "kv" {
  name                       = "kv-cmk-${random_string.suffix.result}"
  location                   = azurerm_resource_group.lab.location
  resource_group_name        = azurerm_resource_group.lab.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
}

# Owner is control plane only. Creating the key needs a data plane role.
resource "azurerm_role_assignment" "me_crypto_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac_me" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.me_crypto_officer]
}

resource "azurerm_key_vault_key" "cmk" {
  name         = "cmk-disk-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["wrapKey", "unwrapKey", "encrypt", "decrypt", "sign", "verify"]

  depends_on = [time_sleep.rbac_me]
}

resource "azurerm_disk_encryption_set" "des" {
  name                = "des-cmk"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  key_vault_key_id    = azurerm_key_vault_key.cmk.id
  encryption_type     = "EncryptionAtRestWithCustomerKey"

  identity {
    type = "SystemAssigned"
  }
}

# Wrap, unwrap and get on keys, nothing else. The encryption service can use
# the key but cannot manage or export it.
resource "azurerm_role_assignment" "des_crypto_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.des.identity[0].principal_id
}

resource "time_sleep" "rbac_des" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.des_crypto_user]
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-cmk"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.50.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.50.1.0/24"]
}

resource "azurerm_network_interface" "vm" {
  name                = "vm-cmkVMNic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# The CLI build created the disk first and attached it, because az vm create
# would not apply the set at creation. Here the OS disk is created with the
# set in the same call, so it is encrypted with the customer key from birth.
resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-cmk"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    name                   = "osdisk-cmk"
    caching                = "ReadWrite"
    storage_account_type   = "Standard_LRS"
    disk_encryption_set_id = azurerm_disk_encryption_set.des.id
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  depends_on = [time_sleep.rbac_des]
}

output "key_vault" {
  value = azurerm_key_vault.kv.name
}

output "disk_encryption_set" {
  value = azurerm_disk_encryption_set.des.name
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}
