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
  }
}

# With shared key disabled, Terraform itself has to use Entra for the data
# plane, the same as every other caller.
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

variable "location" {
  type    = string
  default = "eastus"
}

# The finale of the lab. Set to true to see the insecure default, where the
# access key path works with no data role at all.
variable "shared_key_enabled" {
  type    = bool
  default = false
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# The original build used the shared lab-az-pim group. A dedicated group keeps
# this lab independent of the others.
resource "azurerm_resource_group" "lab" {
  name     = "lab-az-blob"
  location = var.location
}

resource "azurerm_storage_account" "st" {
  name                            = "stlab${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = var.shared_key_enabled
}

# Owner is control plane only. Reading or writing blobs through Entra needs a
# data role, scoped here to the account.
resource "azurerm_role_assignment" "me_blob_contributor" {
  scope                = azurerm_storage_account.st.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.me_blob_contributor]
}

resource "azurerm_storage_container" "data" {
  name                  = "lab-data"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "test" {
  name                   = "test.txt"
  storage_account_name   = azurerm_storage_account.st.name
  storage_container_name = azurerm_storage_container.data.name
  type                   = "Block"
  source_content         = "test"
  depends_on             = [time_sleep.rbac]
}

output "storage_account" {
  value = azurerm_storage_account.st.name
}

output "blob_url" {
  value = azurerm_storage_blob.test.url
}
