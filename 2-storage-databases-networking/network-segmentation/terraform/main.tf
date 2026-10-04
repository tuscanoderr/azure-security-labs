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

# IP flow verify and effective rules need a running VM behind nic-data. Set to
# false once the checks are done; everything else in this lab is free.
variable "create_test_vm" {
  type    = bool
  default = true
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-net"
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-ai-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_subnet" "data" {
  name                 = "snet-data"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.2.0/24"]
}

resource "azurerm_application_security_group" "web" {
  name                = "asg-web"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_application_security_group" "data" {
  name                = "asg-data"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

# Rules target ASGs, not IPs, so scaling out means adding NICs to a group.
# Priority 200 outranks AllowVnetInBound (65000); without it the NSG changes nothing.
resource "azurerm_network_security_group" "data" {
  name                = "nsg-data"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                                       = "Allow-Web-To-Data-443"
    priority                                   = 100
    direction                                  = "Inbound"
    access                                     = "Allow"
    protocol                                   = "Tcp"
    source_port_range                          = "*"
    destination_port_range                     = "443"
    source_application_security_group_ids      = [azurerm_application_security_group.web.id]
    destination_application_security_group_ids = [azurerm_application_security_group.data.id]
  }

  security_rule {
    name                                       = "Deny-Web-To-Data-All"
    priority                                   = 200
    direction                                  = "Inbound"
    access                                     = "Deny"
    protocol                                   = "*"
    source_port_range                          = "*"
    destination_port_range                     = "*"
    source_application_security_group_ids      = [azurerm_application_security_group.web.id]
    destination_application_security_group_ids = [azurerm_application_security_group.data.id]
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}

resource "azurerm_network_interface" "web" {
  name                = "nic-web"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.4"
  }
}

resource "azurerm_network_interface" "data" {
  name                = "nic-data"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.data.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.2.4"
  }
}

resource "azurerm_network_interface_application_security_group_association" "web" {
  network_interface_id          = azurerm_network_interface.web.id
  application_security_group_id = azurerm_application_security_group.web.id
}

resource "azurerm_network_interface_application_security_group_association" "data" {
  network_interface_id          = azurerm_network_interface.data.id
  application_security_group_id = azurerm_application_security_group.data.id
}

resource "tls_private_key" "ssh" {
  count     = var.create_test_vm ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "data" {
  count                           = var.create_test_vm ? 1 : 0
  name                            = "vm-data"
  location                        = azurerm_resource_group.lab.location
  resource_group_name             = azurerm_resource_group.lab.name
  size                            = var.vm_size
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.data.id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh[0].public_key_openssh
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

  depends_on = [azurerm_network_interface_application_security_group_association.data]
}

output "nic_web_ip" {
  value = azurerm_network_interface.web.private_ip_address
}

output "nic_data_ip" {
  value = azurerm_network_interface.data.private_ip_address
}

output "test_vm" {
  value = var.create_test_vm ? azurerm_linux_virtual_machine.data[0].name : "not created"
}
