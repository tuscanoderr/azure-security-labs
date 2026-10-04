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

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-fw"
  location = var.location
}

# Hub

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.30.0.0/16"]
}

resource "azurerm_subnet" "fw" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.30.0.0/26"]
}

# Basic tier requires a separate management subnet and public IP for
# Microsoft's out of band control traffic.
resource "azurerm_subnet" "fw_mgmt" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.30.0.64/26"]
}

resource "azurerm_public_ip" "fw_data" {
  name                = "pip-fw-data"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  allocation_method   = "Static"
}

resource "azurerm_public_ip" "fw_mgmt" {
  name                = "pip-fw-mgmt"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"
  allocation_method   = "Static"
}

resource "azurerm_firewall_policy" "fw" {
  name                = "fw-hub-policy"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Basic"
}

# Anything not matched here is denied by default.
resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.fw.id
  priority           = 200

  application_rule_collection {
    name     = "app-allow"
    priority = 100
    action   = "Allow"

    rule {
      name              = "allow-ubuntu"
      source_addresses  = ["10.31.1.0/24"]
      destination_fqdns = ["*.ubuntu.com"]

      protocols {
        type = "Http"
        port = 80
      }

      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # The VM has to resolve a name before an application rule can match it, and
  # DNS is UDP 53, which application rules do not carry.
  network_rule_collection {
    name     = "net-allow"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "allow-dns"
      protocols             = ["UDP"]
      source_addresses      = ["10.31.1.0/24"]
      destination_addresses = ["168.63.129.16"]
      destination_ports     = ["53"]
    }
  }
}

# Non zonal to match the public IPs.
resource "azurerm_firewall" "hub" {
  name                = "fw-hub"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Basic"
  firewall_policy_id  = azurerm_firewall_policy.fw.id

  ip_configuration {
    name                 = "fw-data-config"
    subnet_id            = azurerm_subnet.fw.id
    public_ip_address_id = azurerm_public_ip.fw_data.id
  }

  management_ip_configuration {
    name                 = "fw-mgmt-config"
    subnet_id            = azurerm_subnet.fw_mgmt.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt.id
  }
}

# Spoke

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-spoke"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.31.0.0/16"]
}

resource "azurerm_subnet" "workload" {
  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.31.1.0/24"]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "hub-to-spoke"
  resource_group_name       = azurerm_resource_group.lab.name
  virtual_network_name      = azurerm_virtual_network.hub.name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "spoke-to-hub"
  resource_group_name       = azurerm_resource_group.lab.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = azurerm_virtual_network.hub.id
  allow_forwarded_traffic   = true
}

# Bound to the spoke subnet only. On AzureFirewallSubnet this route would loop
# the firewall's own egress back to itself.
resource "azurerm_route_table" "spoke" {
  name                = "rt-spoke"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  route {
    name                   = "to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "workload" {
  subnet_id      = azurerm_subnet.workload.id
  route_table_id = azurerm_route_table.spoke.id
}

# Test VM: no public IP and no NSG, so any deny seen from it comes from the
# firewall. Driven through Run Command.
resource "azurerm_network_interface" "vm" {
  name                = "vm-spoke-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "spoke" {
  name                            = "vm-spoke"
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

  # Egress has to go through the firewall from the first boot.
  depends_on = [azurerm_subnet_route_table_association.workload]
}

output "firewall_private_ip" {
  value = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}
