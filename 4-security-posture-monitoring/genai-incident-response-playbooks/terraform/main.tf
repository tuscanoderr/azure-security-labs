data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-${var.prefix}"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "law-${var.prefix}-${random_string.suffix.result}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# The GenAI application under protection. Key auth stays on so the A6 cost drain scenario
# (stolen key) can be shown; A1 traffic carries user context for Defender for AI.
resource "azurerm_cognitive_account" "aoai" {
  name                  = "aoai-${var.prefix}-${random_string.suffix.result}"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "aoai-${var.prefix}-${random_string.suffix.result}"
  local_auth_enabled    = true

  identity {
    type = "SystemAssigned"
  }
}

# Annotate only policy: Prompt Shields still detects jailbreaks but does not block them.
# Used to show the "detected, not blocked" branch of the A1 severity decision gate.
resource "azurerm_cognitive_account_rai_policy" "annotate" {
  name                 = "lab-jailbreak-annotate"
  cognitive_account_id = azurerm_cognitive_account.aoai.id
  base_policy_name     = "Microsoft.DefaultV2"

  dynamic "content_filter" {
    for_each = ["Hate", "Sexual", "Violence", "SelfHarm"]
    content {
      name               = content_filter.value
      filter_enabled     = true
      block_enabled      = true
      severity_threshold = "Medium"
      source             = "Prompt"
    }
  }

  dynamic "content_filter" {
    for_each = ["Hate", "Sexual", "Violence", "SelfHarm"]
    content {
      name               = content_filter.value
      filter_enabled     = true
      block_enabled      = true
      severity_threshold = "Medium"
      source             = "Completion"
    }
  }

  content_filter {
    name               = "Jailbreak"
    filter_enabled     = true
    block_enabled      = false
    severity_threshold = "High"
    source             = "Prompt"
  }
}

# Production style deployment: default policy blocks jailbreaks (Prompt Shields)
resource "azurerm_cognitive_deployment" "chat" {
  name                 = "chat"
  cognitive_account_id = azurerm_cognitive_account.aoai.id
  rai_policy_name      = "Microsoft.DefaultV2"

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = 20
  }
}

resource "azurerm_cognitive_deployment" "chat_annotate" {
  name                 = "chat-annotate"
  cognitive_account_id = azurerm_cognitive_account.aoai.id
  rai_policy_name      = azurerm_cognitive_account_rai_policy.annotate.name

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }

  depends_on = [azurerm_cognitive_deployment.chat]
}

# P6 Logging and Monitoring: prompts, responses and metrics to the SOC workspace
resource "azurerm_monitor_diagnostic_setting" "aoai" {
  name                       = "to-${azurerm_log_analytics_workspace.lab.name}"
  target_resource_id         = azurerm_cognitive_account.aoai.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.lab.id

  enabled_log {
    category = "Audit"
  }
  enabled_log {
    category = "RequestResponse"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}

# Simulated end user of the GenAI app. Its object ID is sent as EndUserId so the Defender
# for AI alert names the account that the A1 playbook contains.
data "azuread_domains" "initial" {
  only_initial = true
}

resource "random_password" "test_user" {
  length  = 24
  special = true
}

resource "azuread_user" "genai_user" {
  user_principal_name = "lab-genai-user@${data.azuread_domains.initial.domains[0].domain_name}"
  display_name        = "Lab GenAI App User"
  password            = random_password.test_user.result
  account_enabled     = true
}
