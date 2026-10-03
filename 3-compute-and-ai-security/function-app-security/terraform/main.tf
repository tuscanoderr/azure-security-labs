# Function App security lab: infrastructure as code
# A Linux function app whose host storage is reached with its managed identity instead of an
# account key, on a storage account with shared key access disabled. Basic publishing
# credentials are off, the HTTP function requires a function key, and Application Insights
# carries the live log stream for the real time test.
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
  features {}
  # Providers were registered by hand, so Terraform does not try to register them.
  resource_provider_registrations = "none"
  # Shared key is disabled on the storage account, so Terraform talks to storage with Entra ID too.
  storage_use_azuread = true
}

# ---------- Inputs ----------

variable "location" {
  type    = string
  default = "centralindia"
}

variable "resource_group_name" {
  type    = string
  default = "lab-az-func"
}

# ---------- Helpers ----------

resource "random_string" "sfx" {
  length  = 5
  upper   = false
  special = false
}

locals {
  sfx = random_string.sfx.result
}

# ---------- Resources ----------

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
}

# Host storage with no usable account key: shared key auth off, no public blobs, TLS 1.2.
resource "azurerm_storage_account" "host" {
  name                            = "stfunc${local.sfx}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-func"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# Telemetry for the live log stream and invocation history.
resource "azurerm_application_insights" "ai" {
  name                = "appi-func"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
}

# Dedicated plan: identity based host storage needs no Azure Files content share here.
resource "azurerm_service_plan" "plan" {
  name                = "asp-func"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_function_app" "func" {
  name                = "func-sec-${local.sfx}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  service_plan_id     = azurerm_service_plan.plan.id
  https_only          = true

  # AzureWebJobsStorage becomes AzureWebJobsStorage__accountName: no key anywhere in settings.
  storage_account_name          = azurerm_storage_account.host.name
  storage_uses_managed_identity = true

  # Deployment only through Entra ID, never with a shared publishing username and password.
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  site_config {
    minimum_tls_version                    = "1.2"
    ftps_state                             = "Disabled"
    application_insights_connection_string = azurerm_application_insights.ai.connection_string

    application_stack {
      node_version = "20"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME = "node"
    # The Azure CLI zip deploy sets this; declaring it keeps plans clean.
    SCM_DO_BUILD_DURING_DEPLOYMENT = "false"
  }
}

# The roles the Functions host needs on its storage, granted to the app's own identity.
resource "azurerm_role_assignment" "func_storage" {
  for_each = toset([
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ])
  scope                = azurerm_storage_account.host.id
  role_definition_name = each.value
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
}

resource "time_sleep" "role_propagation" {
  depends_on      = [azurerm_role_assignment.func_storage]
  create_duration = "60s"
}

# Package and deploy the function with the Azure CLI, which authenticates with Entra ID.
resource "terraform_data" "deploy_code" {
  triggers_replace = [
    azurerm_linux_function_app.func.id,
    filesha256("${path.module}/../function-code/HttpHello/index.js"),
    filesha256("${path.module}/../function-code/HttpHello/function.json"),
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    # tar.exe writes forward slash paths, which the Linux host can extract. Compress-Archive does not.
    command = "tar.exe -a -c -f '${path.module}/function.zip' -C '${path.module}/../function-code' host.json HttpHello; az functionapp deployment source config-zip -g ${azurerm_resource_group.lab.name} -n ${azurerm_linux_function_app.func.name} --src '${path.module}/function.zip' -o none"
  }

  depends_on = [time_sleep.role_propagation]
}

# ---------- Outputs ----------

output "function_app_name" {
  value = azurerm_linux_function_app.func.name
}

output "storage_account_name" {
  value = azurerm_storage_account.host.name
}

output "function_url" {
  value = "https://${azurerm_linux_function_app.func.default_hostname}/api/HttpHello"
}
