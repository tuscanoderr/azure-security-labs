resource "azurerm_sentinel_log_analytics_workspace_onboarding" "lab" {
  workspace_id = azurerm_log_analytics_workspace.lab.id
}

# Defender for Cloud alerts (including Defender for AI) into the workspace
resource "azurerm_sentinel_data_connector_azure_security_center" "mdc" {
  name                       = "defender-for-cloud"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.lab.workspace_id
  subscription_id            = data.azurerm_subscription.current.subscription_id
}

# A1 detection: turn Prompt Shields jailbreak alerts into incidents
resource "azurerm_sentinel_alert_rule_ms_security_incident" "a1_jailbreak" {
  name                       = "genai-irf-a1-jailbreak"
  display_name               = "GenAI-IRF A1: jailbreak on Azure OpenAI deployment"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.lab.workspace_id
  product_filter             = "Azure Security Center"
  severity_filter            = ["High", "Medium", "Low", "Informational"]
  display_name_filter        = ["Jailbreak"]
}

# A6 detection: token spend spike on the model (LLM10 Unbounded Consumption). Platform metrics
# are complete; RequestResponse logs are best effort, so they only enrich the caller IP.
resource "azurerm_sentinel_alert_rule_scheduled" "a6_flood" {
  name                       = "genai-irf-a6-cost-drain"
  display_name               = "GenAI-IRF A6: token flood against Azure OpenAI"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.lab.workspace_id
  severity                   = "Medium"
  query_frequency            = "PT5M"
  query_period               = "PT15M"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 0
  tactics                    = ["Impact"]
  description                = "More than ${var.token_threshold} generated tokens in 15 minutes on one Azure OpenAI account. Maps to MITRE ATLAS AML.T0034 Cost Harvesting and AML.T0029 Denial of AI Service."

  query = <<-KQL
    AzureMetrics
    | where TimeGenerated > ago(15m)
    | where ResourceProvider == "MICROSOFT.COGNITIVESERVICES" and MetricName == "GeneratedTokens"
    | summarize GeneratedTokens = sum(Total), Requests = count() by ResourceId = tolower(_ResourceId)
    | where GeneratedTokens > ${var.token_threshold}
    | join kind=leftouter (
        AzureDiagnostics
        | where TimeGenerated > ago(30m) and Category == "RequestResponse"
        | summarize Calls = count() by CallerIPAddress, ResourceId = tolower(_ResourceId)
        | summarize arg_max(Calls, CallerIPAddress) by ResourceId
      ) on ResourceId
    | project ResourceId, GeneratedTokens, CallerIPAddress
  KQL

  custom_details = {
    GeneratedTokens = "GeneratedTokens"
  }

  entity_mapping {
    entity_type = "IP"
    field_mapping {
      identifier  = "Address"
      column_name = "CallerIPAddress"
    }
  }

  entity_mapping {
    entity_type = "AzureResource"
    field_mapping {
      identifier  = "ResourceId"
      column_name = "ResourceId"
    }
  }

  incident {
    create_incident_enabled = true
    grouping {
      enabled                = true
      lookback_duration      = "PT1H"
      entity_matching_method = "AllEntities"
    }
  }
}
