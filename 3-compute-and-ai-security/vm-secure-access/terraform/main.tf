terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

# Defender for Servers is a subscription wide setting, not part of the
# resource group. Set this to false if the subscription already runs Plan 2
# for other workloads, because destroy returns the plan to Free.
variable "manage_defender_for_servers" {
  type    = bool
  default = true
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-vmsec2"
  location = var.location
}

# Defender for Servers Plan 2 is the prerequisite for Just in Time access.
resource "azurerm_security_center_subscription_pricing" "servers" {
  count         = var.manage_defender_for_servers ? 1 : 0
  tier          = "Standard"
  resource_type = "VirtualMachines"
  subplan       = "P2"
}

# Network, named the way az vm create names it

resource "azurerm_virtual_network" "vnet" {
  name                = "vm-secure2VNET"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                 = "vm-secure2Subnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

# Bastion only deploys into a subnet with exactly this name, /26 or larger.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/26"]
}

# No custom rules, the equivalent of --nsg-rule NONE. Nothing from the
# internet can reach the VM, and Just in Time later adds its own deny and
# temporary allow rules for port 22 here.
resource "azurerm_network_security_group" "vm" {
  name                = "vm-secure2NSG"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

# No public IP on the NIC. The only way in is through Bastion.
resource "azurerm_network_interface" "vm" {
  name                = "vm-secure2VMNic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfigvm-secure2"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

# az vm create attaches its NSG to the NIC, not the subnet.
resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Trusted Launch (secure boot and vTPM) is what az vm create applies by
# default to a Gen2 Ubuntu image, so it is set explicitly here.
resource "azurerm_linux_virtual_machine" "vm" {
  name                            = "vm-secure2"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
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

  # The NSG has to be on the NIC before the VM is reachable at all.
  depends_on = [azurerm_network_interface_security_group_association.vm]
}

# Bastion

# Basic and Standard Bastion both need a Standard, static public IP. This IP
# belongs to Bastion, never to the VM.
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion-vmsec2"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  allocation_method   = "Static"
}

# Basic is enough for a browser session to a VM in the same VNet.
resource "azurerm_bastion_host" "bastion" {
  name                = "bastion-vmsec2"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Basic"

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# Backup and Multi User Authorization

# Soft delete is off so terraform destroy can remove the backup data and the
# vault in one run. With it on, the deleted backup items are kept for 14 days
# and the vault cannot be deleted until they expire. In production soft delete
# stays on, and Multi User Authorization guards any attempt to turn it off.
resource "azurerm_recovery_services_vault" "rsv" {
  name                = "rsv-vmsec2"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  soft_delete_enabled = false
}

# Trusted Launch VMs can only be protected by an Enhanced (V2) policy.
resource "azurerm_backup_policy_vm" "daily" {
  name                = "bkpol-vmsec2-daily"
  resource_group_name = azurerm_resource_group.lab.name
  recovery_vault_name = azurerm_recovery_services_vault.rsv.name
  policy_type         = "V2"
  timezone            = "UTC"

  backup {
    frequency = "Daily"
    time      = "23:00"
  }

  retention_daily {
    count = 7
  }
}

resource "azurerm_backup_protected_vm" "vm" {
  resource_group_name = azurerm_resource_group.lab.name
  recovery_vault_name = azurerm_recovery_services_vault.rsv.name
  source_vm_id        = azurerm_linux_virtual_machine.vm.id
  backup_policy_id    = azurerm_backup_policy_vm.daily.id
}

# Same subscription for the lab. In production the guard lives in a
# subscription or tenant owned by a different team, which is what makes the
# second authorization real.
resource "azurerm_data_protection_resource_guard" "guard" {
  name                = "rg-guard-vmsec2"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

# Linking the guard to the vault is what turns Multi User Authorization on.
# It depends on the protected VM so that on destroy the guard is unlinked
# first. Otherwise stopping protection and deleting the backup data would be
# a guarded operation and the destroy would stall.
resource "azurerm_recovery_services_vault_resource_guard_association" "mua" {
  vault_id          = azurerm_recovery_services_vault.rsv.id
  resource_guard_id = azurerm_data_protection_resource_guard.guard.id

  depends_on = [azurerm_backup_protected_vm.vm]
}

output "vm_id" {
  description = "Goes into jitpolicy.json for the Just in Time step."
  value       = azurerm_linux_virtual_machine.vm.id
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}

# Needed for the Bastion SSH session. Read it with
# terraform output -raw ssh_private_key and keep it out of the repository.
output "ssh_private_key" {
  value     = tls_private_key.ssh.private_key_openssh
  sensitive = true
}
