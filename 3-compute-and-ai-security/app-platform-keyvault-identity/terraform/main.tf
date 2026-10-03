# App platform secrets lab: infrastructure as code
# One Key Vault, two consumers. An App Service web app reads a secret through a Key Vault
# reference with its system assigned identity, and a Container App pulls its image from a
# private registry and reads the same secret with a user assigned identity. No secret value
# or registry password is stored in either app.
#
# Run from PowerShell on the lab PC (Azure CLI signed in):
#   $env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
#   terraform init
#   terraform plan -out tfplan
#   terraform apply tfplan

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Lab vault: purge on destroy so the name can be reused.
      purge_soft_delete_on_destroy = true
    }
  }
  # Providers were registered by hand, so Terraform does not try to register them.
  resource_provider_registrations = "none"
}

# ---------- Inputs ----------

variable "location" {
  type    = string
  default = "centralindia"
}

variable "resource_group_name" {
  type    = string
  default = "lab-az-appsec"
}

variable "webapp_secret_access" {
  description = "Set to false to remove the web app's Key Vault role and prove the reference then fails."
  type        = bool
  default     = true
}

# ---------- Lookups and helpers ----------

data "azurerm_client_config" "current" {}

# Short suffix for globally unique names (vault, registry, web app).
resource "random_string" "sfx" {
  length  = 5
  upper   = false
  special = false
}

# The demo secret value. It exists only in the vault and in local Terraform state.
resource "random_password" "db" {
  length  = 24
  special = false
}

locals {
  sfx = random_string.sfx.result
}

# ---------- Shared resources ----------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
}

# Vault uses Azure RBAC for data plane access, not access policies.
resource "azurerm_key_vault" "kv" {
  name                       = "kv-appsec-${local.sfx}"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
}

# The person running Terraform needs a data plane role to write the secret.
resource "azurerm_role_assignment" "me_secrets_officer" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Data plane role assignments take a short while to apply.
resource "time_sleep" "officer_propagation" {
  depends_on      = [azurerm_role_assignment.me_secrets_officer]
  create_duration = "60s"
}

resource "azurerm_key_vault_secret" "db" {
  name         = "app-db-password"
  value        = random_password.db.result
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [time_sleep.officer_propagation]
}

# ---------- Consumer 1: App Service with a system assigned identity ----------

resource "azurerm_service_plan" "plan" {
  name                = "asp-appsec"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "web" {
  name                = "app-appsec-${local.sfx}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  service_plan_id     = azurerm_service_plan.plan.id
  https_only          = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version = "1.2"
    ftps_state          = "Disabled"

    application_stack {
      node_version = "20-lts"
    }
  }

  # A pointer to the secret, not the secret. Versionless so rotation is picked up.
  app_settings = {
    DB_PASSWORD = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db.versionless_id})"
  }
}

# Least privilege: read this one secret, scoped to the secret rather than the whole vault.
resource "azurerm_role_assignment" "web_secret_user" {
  count                = var.webapp_secret_access ? 1 : 0
  scope                = azurerm_key_vault_secret.db.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.web.identity[0].principal_id
}

# ---------- Consumer 2: Container App with a user assigned identity ----------

# Private registry, shared admin account never enabled.
resource "azurerm_container_registry" "acr" {
  name                = "acrappsec${local.sfx}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Basic"
  admin_enabled       = false
}

# Copy a public sample image into the private registry through Entra identity.
resource "terraform_data" "import_image" {
  triggers_replace = [azurerm_container_registry.acr.id]

  provisioner "local-exec" {
    command = "az acr import --name ${azurerm_container_registry.acr.name} --source mcr.microsoft.com/k8se/quickstart:latest --image lab/quickstart:v1"
  }
}

# User assigned, because the identity must exist and hold AcrPull before the app pulls its first image.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-appsec-containerapp"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_role_assignment" "app_secret_user" {
  scope                = azurerm_key_vault_secret.db.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "time_sleep" "app_role_propagation" {
  depends_on      = [azurerm_role_assignment.app_acr_pull, azurerm_role_assignment.app_secret_user]
  create_duration = "60s"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-appsec"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_app_environment" "env" {
  name                       = "cae-appsec"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  # Azure adds this profile on create, so it is declared to keep plans clean.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "app" {
  name                         = "ca-appsec"
  resource_group_name          = azurerm_resource_group.lab.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Image pull with the managed identity. No username or password.
  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  # Secret is a reference to Key Vault, resolved with the same identity.
  secret {
    name                = "db-password"
    identity            = azurerm_user_assigned_identity.app.id
    key_vault_secret_id = azurerm_key_vault_secret.db.versionless_id
  }

  template {
    container {
      name   = "quickstart"
      image  = "${azurerm_container_registry.acr.login_server}/lab/quickstart:v1"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "DB_PASSWORD"
        secret_name = "db-password"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 80

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [time_sleep.app_role_propagation, terraform_data.import_image]
}

# ---------- Outputs ----------

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "web_app_name" {
  value = azurerm_linux_web_app.web.name
}

output "acr_name" {
  value = azurerm_container_registry.acr.name
}

output "container_app_url" {
  value = "https://${azurerm_container_app.app.ingress[0].fqdn}"
}
