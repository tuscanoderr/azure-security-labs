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

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

# West US, as in the original build: East US had no SQL capacity on the lab
# subscription.
variable "location" {
  type    = string
  default = "westus"
}

# Display name shown for the Entra admin on the server, for example the admin's
# UPN. Only the object ID decides who the admin is.
variable "entra_admin_login" {
  type = string
}

# Leave null to make whoever runs Terraform the Entra admin.
variable "entra_admin_object_id" {
  type    = string
  default = null
}

# Public IP of the machine that will run the T-SQL steps in the portal Query
# editor. Leave null to add no firewall rule.
variable "client_ip" {
  type    = string
  default = null
}

data "azurerm_client_config" "current" {}

# SQL server names are globally unique DNS names, so each build gets a fresh
# suffix.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# Kept outside the lab-az-pim group, where the East US only location policy
# blocked the West US deploy.
resource "azurerm_resource_group" "lab" {
  name     = "lab-az-sql"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "sql" {
  name                = "law-lab-sql"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# Entra only: no SQL login or password exists on the server at all.
resource "azurerm_mssql_server" "sql" {
  name                          = "sqlsrv-lab-${random_string.suffix.result}"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = coalesce(var.entra_admin_object_id, data.azurerm_client_config.current.object_id)
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

# The public endpoint stays on for the Query editor, but with no rules it
# admits nobody. This opens it to one address only.
resource "azurerm_mssql_firewall_rule" "client" {
  count            = var.client_ip == null ? 0 : 1
  name             = "allow-client-ip"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = var.client_ip
  end_ip_address   = var.client_ip
}

# The portal free offer cannot be requested through azurerm, so this is a
# small serverless database that pauses after an hour idle. It bills for
# compute while running and for storage always.
resource "azurerm_mssql_database" "lab" {
  name                        = "free-sql-db-5310054"
  server_id                   = azurerm_mssql_server.sql.id
  sku_name                    = "GP_S_Gen5_1"
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
  max_size_gb                 = 32
  storage_account_type        = "Local"

  # On by default. Stated so a change shows up in plan.
  transparent_data_encryption_enabled = true
}

# No key vault key, so the TDE protector is the service managed key.
resource "azurerm_mssql_server_transparent_data_encryption" "sql" {
  server_id = azurerm_mssql_server.sql.id
}

# Server audit events reach Log Analytics through a diagnostic setting on the
# master database. Needs Microsoft.Insights registered on the subscription.
resource "azurerm_monitor_diagnostic_setting" "sql_audit" {
  name                       = "audit-to-law"
  target_resource_id         = "${azurerm_mssql_server.sql.id}/databases/master"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.sql.id

  enabled_log {
    category = "SQLSecurityAuditEvents"
  }
}

# Server scope, so every database on the server is audited.
resource "azurerm_mssql_server_extended_auditing_policy" "sql" {
  server_id              = azurerm_mssql_server.sql.id
  enabled                = true
  log_monitoring_enabled = true

  depends_on = [azurerm_monitor_diagnostic_setting.sql_audit]
}

output "sql_server" {
  value = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "database" {
  value = azurerm_mssql_database.lab.name
}

output "log_analytics_workspace" {
  value = azurerm_log_analytics_workspace.sql.name
}
