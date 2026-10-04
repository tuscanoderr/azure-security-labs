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

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-avnm"
  location = var.location
}

# Scope bounds what the manager can govern; scope_accesses switch on each
# capability, least privilege for the manager itself.
resource "azurerm_network_manager" "avnm" {
  name                = "avnm-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  scope_accesses      = ["Connectivity", "SecurityAdmin"]

  scope {
    subscription_ids = [data.azurerm_subscription.current.id]
  }
}

resource "azurerm_network_manager_network_group" "prod" {
  name               = "ng-prod"
  network_manager_id = azurerm_network_manager.avnm.id
}

# VNets

locals {
  prod_vnets = {
    "vnet-prod-1" = "10.40"
    "vnet-prod-2" = "10.41"
    "vnet-prod-3" = "10.42"
  }
}

resource "azurerm_virtual_network" "prod" {
  for_each            = local.prod_vnets
  name                = each.key
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["${each.value}.0.0/16"]
}

resource "azurerm_subnet" "workload" {
  for_each             = local.prod_vnets
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.prod[each.key].name
  address_prefixes     = ["${each.value}.1.0/24"]
}

# Dynamic membership: any VNet named vnet-prod* joins ng-prod, including ones
# created later. This replaces the static members the CLI build started with.
resource "azurerm_policy_definition" "dyn_prod" {
  name         = "dyn-prod-vnets"
  display_name = "AVNM: add vnet-prod* to ng-prod"
  policy_type  = "Custom"
  mode         = "Microsoft.Network.Data"

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/virtualNetworks" },
        { field = "name", like = "vnet-prod*" }
      ]
    }
    then = {
      effect = "addToNetworkGroup"
      details = {
        networkGroupId = azurerm_network_manager_network_group.prod.id
      }
    }
  })
}

resource "azurerm_subscription_policy_assignment" "dyn_prod" {
  name                 = "assign-dyn-prod"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_definition.dyn_prod.id
}

# App team layer: an NSG that allows RDP from anywhere on vnet-prod-1.
resource "azurerm_network_security_group" "prod1" {
  name                = "nsg-prod-1"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "allow-rdp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "prod1" {
  subnet_id                 = azurerm_subnet.workload["vnet-prod-1"].id
  network_security_group_id = azurerm_network_security_group.prod1.id
}

# Governance layer: admin rules are evaluated before NSGs, so this Deny wins
# over allow-rdp on every VNet in the group.
resource "azurerm_network_manager_security_admin_configuration" "baseline" {
  name               = "cfg-security-baseline"
  network_manager_id = azurerm_network_manager.avnm.id
}

resource "azurerm_network_manager_admin_rule_collection" "baseline" {
  name                            = "rc-baseline"
  security_admin_configuration_id = azurerm_network_manager_security_admin_configuration.baseline.id
  network_group_ids               = [azurerm_network_manager_network_group.prod.id]
}

resource "azurerm_network_manager_admin_rule" "deny_rdp" {
  name                     = "deny-rdp-inbound"
  admin_rule_collection_id = azurerm_network_manager_admin_rule_collection.baseline.id
  action                   = "Deny"
  direction                = "Inbound"
  priority                 = 100
  protocol                 = "Tcp"
  destination_port_ranges  = ["3389"]

  source {
    address_prefix_type = "ServiceTag"
    address_prefix      = "Internet"
  }

  destination {
    address_prefix_type = "IPPrefix"
    address_prefix      = "*"
  }
}

resource "azurerm_network_manager_connectivity_configuration" "mesh" {
  name                  = "cfg-mesh"
  network_manager_id    = azurerm_network_manager.avnm.id
  connectivity_topology = "Mesh"

  applies_to_group {
    group_connectivity = "None"
    network_group_id   = azurerm_network_manager_network_group.prod.id
  }
}

# Configurations are inert until committed to a region.
resource "azurerm_network_manager_deployment" "security" {
  network_manager_id = azurerm_network_manager.avnm.id
  location           = azurerm_resource_group.lab.location
  scope_access       = "SecurityAdmin"
  configuration_ids  = [azurerm_network_manager_security_admin_configuration.baseline.id]

  depends_on = [azurerm_network_manager_admin_rule.deny_rdp]
}

resource "azurerm_network_manager_deployment" "connectivity" {
  network_manager_id = azurerm_network_manager.avnm.id
  location           = azurerm_resource_group.lab.location
  scope_access       = "Connectivity"
  configuration_ids  = [azurerm_network_manager_connectivity_configuration.mesh.id]
}

# Test VM: only provides a NIC whose effective security rules show the admin
# Deny and the NSG Allow side by side.
resource "azurerm_network_interface" "vm" {
  name                = "vm-testVMNic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.workload["vnet-prod-1"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "test" {
  name                            = "vm-test"
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
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  depends_on = [azurerm_subnet_network_security_group_association.prod1]
}

output "network_group" {
  value = azurerm_network_manager_network_group.prod.name
}

output "test_nic" {
  value = azurerm_network_interface.vm.name
}
