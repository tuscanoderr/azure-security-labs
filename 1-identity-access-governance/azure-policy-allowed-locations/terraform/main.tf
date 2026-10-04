terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  # The probe NSGs are created with az, outside state. This lets destroy remove
  # the group with them still in it.
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  resource_provider_registrations = "none"
}

variable "location" {
  type    = string
  default = "eastus"
}

# Audit first to see what would break, then rerun with -var effect=Deny.
variable "effect" {
  type    = string
  default = "Audit"

  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.effect)
    error_message = "effect must be Audit, Deny or Disabled."
  }
}

variable "allowed_locations" {
  type    = list(string)
  default = ["eastus"]
}

# The original build used the shared lab-az-pim group. A dedicated group keeps
# this lab independent of the others.
resource "azurerm_resource_group" "lab" {
  name     = "lab-az-policy"
  location = var.location
}

# Built in "Allowed locations". The effect is a parameter of the definition,
# which is what makes the Audit to Deny flip a parameter change.
data "azurerm_policy_definition" "allowed_locations" {
  name = "e56962a6-4747-49cd-b67b-bf8b01975c4c"
}

resource "azurerm_resource_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations-eastus"
  display_name         = "Allowed locations - East US only (lab)"
  description          = "Restrict resources in this resource group to East US. Audit first, then Deny."
  resource_group_id    = azurerm_resource_group.lab.id
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  enforce              = true

  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
    effect                 = { value = var.effect }
  })

  non_compliance_message {
    content = "This resource group only permits resources in East US (lab governance guardrail). Redeploy to eastus. Blocked by policy: Allowed locations - East US only (lab)."
  }
}

output "assignment" {
  value = azurerm_resource_group_policy_assignment.allowed_locations.name
}

output "effect" {
  value = var.effect
}

output "probe_commands" {
  value = [
    "az network nsg create -g ${azurerm_resource_group.lab.name} -n nsg-policy-test -l westus",
    "az network nsg create -g ${azurerm_resource_group.lab.name} -n nsg-allow-test -l eastus",
  ]
}
