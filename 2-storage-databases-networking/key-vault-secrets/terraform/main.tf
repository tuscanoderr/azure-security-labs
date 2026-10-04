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

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

variable "location" {
  type    = string
  default = "eastus"
}

# The lab ends with public access off. Apply once with true so Terraform can
# write the objects, then rerun with -var public_network_access_enabled=false.
# After that, plans from outside the VNet cannot read the secret, key or cert.
variable "public_network_access_enabled" {
  type    = bool
  default = true
}

data "azurerm_client_config" "current" {}

# Purge protected vault names stay reserved after destroy, so each build gets
# a fresh suffix.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# The original build used the shared lab-az-pim group. A dedicated group keeps
# this lab independent of the others.
resource "azurerm_resource_group" "lab" {
  name     = "lab-az-kv"
  location = var.location
}

# RBAC, not access policies: a Contributor cannot grant themselves data access.
resource "azurerm_key_vault" "kv" {
  name                          = "kv-lab-${random_string.suffix.result}"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7
  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

# Owner grants nothing on the data plane under RBAC. Officer roles manage,
# User roles consume.
resource "azurerm_role_assignment" "me_admin" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Data plane role assignments take a minute or two to apply.
resource "time_sleep" "rbac" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.me_admin]
}

# The value lives in local state only, which .gitignore keeps out of the repo.
resource "random_password" "db" {
  length  = 24
  special = true
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.rbac]
}

resource "azurerm_key_vault_key" "lab" {
  name         = "lab-key"
  key_vault_id = azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]
  depends_on   = [time_sleep.rbac]
}

resource "azurerm_key_vault_certificate" "lab" {
  name         = "lab-cert"
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.rbac]

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_type   = "RSA"
      key_size   = 2048
      reuse_key  = false
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=lab-cert"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
    }
  }
}

# Stand in for an application: reads secret values and nothing else.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-lab-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_role_assignment" "app_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

output "key_vault" {
  value = azurerm_key_vault.kv.name
}

output "app_identity" {
  value = azurerm_user_assigned_identity.app.name
}

output "secret_version" {
  value = azurerm_key_vault_secret.db_password.version
}
