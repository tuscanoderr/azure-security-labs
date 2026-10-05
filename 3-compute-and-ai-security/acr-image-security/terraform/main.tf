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
  }
}

# Microsoft.ContainerRegistry must already be registered on the subscription.
# The README covers the one time az provider register step.
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

# The original build ran in centralindia.
variable "location" {
  type    = string
  default = "centralindia"
}

# Registry names are global DNS names (<name>.azurecr.io), so each build gets a
# fresh suffix. acrlockd3r7 in the evidence is the original registry.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-acr"
  location = var.location
}

# Admin user off from creation, so the shared username and password never
# exist and every push and pull goes through Entra and RBAC.
# Basic does not offer anonymous pull, so that path is closed by the tier.
# Public network access stays on, as in the original build; restricting it is
# listed as an extension in the README.
resource "azurerm_container_registry" "acr" {
  name                          = "acrlock${random_string.suffix.result}"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  sku                           = "Basic"
  admin_enabled                 = false
  public_network_access_enabled = true
}

# Importing lab/sample:v1, locking it and the refused delete are data plane
# steps with no azurerm resource. They stay as CLI steps against this name.
output "registry_name" {
  value = azurerm_container_registry.acr.name
}

output "login_server" {
  value = azurerm_container_registry.acr.login_server
}
