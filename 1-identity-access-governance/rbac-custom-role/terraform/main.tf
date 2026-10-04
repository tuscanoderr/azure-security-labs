terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
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

# Object ID of the user who should operate the VMs (the standard user in the
# original lab). Left empty, the role is assigned to whoever runs Terraform.
variable "operator_object_id" {
  type    = string
  default = ""
}

data "azurerm_client_config" "current" {}

# The original build used the shared lab-az-pim group. A dedicated group keeps
# this lab independent of the others.
resource "azurerm_resource_group" "lab" {
  name     = "lab-az-rbac"
  location = var.location
}

# Same permissions as vmoperator.json: power operations and read, nothing that
# creates, changes or deletes. Assignable only inside this resource group.
resource "azurerm_role_definition" "vm_operator" {
  name        = "Lab VM Operator"
  scope       = azurerm_resource_group.lab.id
  description = "Least-privilege: start/stop/restart VMs and read resources only."

  permissions {
    actions = [
      "Microsoft.Compute/virtualMachines/start/action",
      "Microsoft.Compute/virtualMachines/restart/action",
      "Microsoft.Compute/virtualMachines/deallocate/action",
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.lab.id]
}

resource "azurerm_role_assignment" "operator" {
  scope              = azurerm_resource_group.lab.id
  role_definition_id = azurerm_role_definition.vm_operator.role_definition_resource_id
  principal_id       = var.operator_object_id != "" ? var.operator_object_id : data.azurerm_client_config.current.object_id
}

output "role_name" {
  value = azurerm_role_definition.vm_operator.name
}

output "assignment_scope" {
  value = azurerm_resource_group.lab.name
}
