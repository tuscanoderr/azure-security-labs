terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

variable "location" {
  type    = string
  default = "centralindia"
}

resource "random_string" "sfx" {
  length  = 5
  upper   = false
  special = false
}

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-dfc"
  location = var.location
}

# Workload protection plans. Destroying these returns each plan to the Free tier.
# Defender CSPM (CloudPosture) is already on for this subscription and is left unmanaged.
resource "azurerm_security_center_subscription_pricing" "storage" {
  tier          = "Standard"
  resource_type = "StorageAccounts"
  subplan       = "DefenderForStorageV2"

  extension {
    name = "OnUploadMalwareScanning"
    # Azure fills in the last two with these defaults; declaring them keeps plans clean.
    additional_extension_properties = {
      CapGBPerMonthPerStorageAccount = "10"
      AutomatedResponse              = "None"
      BlobScanResultsOptions         = "BlobIndexTags"
    }
  }

  extension {
    name = "SensitiveDataDiscovery"
  }
}

resource "azurerm_security_center_subscription_pricing" "keyvault" {
  tier          = "Standard"
  resource_type = "KeyVaults"
  subplan       = "PerKeyVault"
}

resource "azurerm_security_center_subscription_pricing" "arm" {
  tier          = "Standard"
  resource_type = "Arm"
  subplan       = "PerSubscription"
}

# Regulatory compliance: assign CIS Microsoft Azure Foundations Benchmark v2.0.0 at subscription scope.
resource "azurerm_subscription_policy_assignment" "cis" {
  name                 = "lab-dfc-cis-v2"
  display_name         = "CIS Microsoft Azure Foundations Benchmark v2.0.0"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/06f19060-9e68-4070-92ca-f15cc126059e"
}

# Deliberately weak resources so Defender has something to assess.
resource "azurerm_storage_account" "weak" {
  name                            = "stdfcweak${random_string.sfx.result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = true
}

resource "azurerm_key_vault" "weak" {
  name                       = "kv-dfc-${random_string.sfx.result}"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

# Continuous export: alerts and recommendations land in Log Analytics, ready for Sentinel.
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-dfc"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# The portal adds this solution when export is set up there. Created as code it must be
# declared, or the SecurityAlert and SecurityRecommendation tables never appear.
resource "azurerm_log_analytics_solution" "security_free" {
  solution_name         = "SecurityCenterFree"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/SecurityCenterFree"
  }
}

resource "azurerm_security_center_automation" "export" {
  name                = "export-dfc-to-law"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  scopes              = [data.azurerm_subscription.current.id]

  action {
    type        = "loganalytics"
    resource_id = azurerm_log_analytics_workspace.law.id
  }

  source {
    event_source = "Alerts"
  }

  source {
    event_source = "Assessments"
  }
}

output "storage_account" {
  value = azurerm_storage_account.weak.name
}

output "key_vault" {
  value = azurerm_key_vault.weak.name
}

output "workspace" {
  value = azurerm_log_analytics_workspace.law.name
}
