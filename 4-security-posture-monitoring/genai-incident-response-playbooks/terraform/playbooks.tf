# Playbooks are Logic Apps deployed from ARM templates so the workflow definition is versioned
# with the lab. Each action is named after the GenAI-IRF playbook step it implements.
resource "azurerm_resource_group_template_deployment" "pb_a1" {
  name                = "pb-a1-jailbreak"
  resource_group_name = azurerm_resource_group.lab.name
  deployment_mode     = "Incremental"
  template_content    = file("${path.module}/playbooks/a1-jailbreak.json")
  parameters_content = jsonencode({
    workflowName = { value = "pb-genai-irf-a1-jailbreak" }
    location     = { value = azurerm_resource_group.lab.location }
  })
}

resource "azurerm_resource_group_template_deployment" "pb_a6" {
  name                = "pb-a6-cost-drain"
  resource_group_name = azurerm_resource_group.lab.name
  deployment_mode     = "Incremental"
  template_content    = file("${path.module}/playbooks/a6-cost-drain.json")
  parameters_content = jsonencode({
    workflowName   = { value = "pb-genai-irf-a6-cost-drain" }
    location       = { value = azurerm_resource_group.lab.location }
    aoaiId         = { value = azurerm_cognitive_account.aoai.id }
    deploymentName = { value = azurerm_cognitive_deployment.chat.name }
  })
}

locals {
  a1_principal = jsondecode(azurerm_resource_group_template_deployment.pb_a1.output_content).principalId.value
  a1_id        = jsondecode(azurerm_resource_group_template_deployment.pb_a1.output_content).workflowId.value
  a6_principal = jsondecode(azurerm_resource_group_template_deployment.pb_a6.output_content).principalId.value
  a6_id        = jsondecode(azurerm_resource_group_template_deployment.pb_a6.output_content).workflowId.value
}

# Playbook identities: least privilege for the actions each one takes
resource "azurerm_role_assignment" "a1_responder" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Microsoft Sentinel Responder"
  principal_id         = local.a1_principal
}

resource "azurerm_role_assignment" "a6_responder" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Microsoft Sentinel Responder"
  principal_id         = local.a6_principal
}

resource "azurerm_role_assignment" "a6_aoai" {
  scope                = azurerm_cognitive_account.aoai.id
  role_definition_name = "Cognitive Services Contributor"
  principal_id         = local.a6_principal
}

# Graph application permissions for A1 containment (disable account, revoke sessions)
data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

resource "azuread_app_role_assignment" "a1_graph" {
  for_each            = toset(["User.EnableDisableAccount.All", "User.RevokeSessions.All"])
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids[each.value]
  principal_object_id = local.a1_principal
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Sentinel runs playbooks as the Azure Security Insights service principal
data "azuread_service_principal" "security_insights" {
  client_id = "98785600-1bb7-4fb9-b9fa-19afe2c8a360"
}

resource "azurerm_role_assignment" "sentinel_automation" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Microsoft Sentinel Automation Contributor"
  principal_id         = data.azuread_service_principal.security_insights.object_id
}

# Automation rules: machine steps run in the playbook, human owned steps and decision gates
# from the paper become incident tasks so the analyst works the same checklist.
resource "azurerm_sentinel_automation_rule" "a1" {
  name                       = "6f0e6a1c-0a11-4a1e-9a01-000000000a01"
  display_name               = "GenAI-IRF A1: jailbreak response"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.lab.workspace_id
  order                      = 1
  triggers_on                = "Incidents"
  triggers_when              = "Created"

  condition_json = jsonencode([{
    conditionType = "Property"
    conditionProperties = {
      propertyName   = "IncidentRelatedAnalyticRuleIds"
      operator       = "Contains"
      propertyValues = [azurerm_sentinel_alert_rule_ms_security_incident.a1_jailbreak.id]
    }
  }])

  action_incident_task {
    order       = 1
    title       = "D3 Formally declare incident and activate IR team"
    description = "IR Team Lead. NIST AI 600-1 GV-2.1-002."
  }
  action_incident_task {
    order       = 2
    title       = "D9 Assess reporting obligations"
    description = "Legal and Compliance: UK GDPR, EU AI Act. NIST AI 600-1 MG-4.3-003."
  }
  action_incident_task {
    order       = 3
    title       = "C3 Preserve volatile evidence"
    description = "Forensic Lead: export alert prompt evidence and RequestResponse logs, record SHA-256 in chain of custody."
  }
  action_incident_task {
    order       = 4
    title       = "C4 Approve emergency filter"
    description = "IR Team Lead and Product Owner approve the hotfix content filter or blocklist."
  }
  action_playbook {
    order        = 5
    logic_app_id = local.a1_id
  }

  depends_on = [azurerm_role_assignment.sentinel_automation, azurerm_role_assignment.a1_responder]
}

resource "azurerm_sentinel_automation_rule" "a6" {
  name                       = "6f0e6a1c-0a11-4a1e-9a01-000000000a06"
  display_name               = "GenAI-IRF A6: cost drain response"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.lab.workspace_id
  order                      = 2
  triggers_on                = "Incidents"
  triggers_when              = "Created"

  condition_json = jsonencode([{
    conditionType = "Property"
    conditionProperties = {
      propertyName   = "IncidentRelatedAnalyticRuleIds"
      operator       = "Contains"
      propertyValues = [azurerm_sentinel_alert_rule_scheduled.a6_flood.id]
    }
  }])

  action_incident_task {
    order       = 1
    title       = "D6 Determine blast radius"
    description = "Forensic Lead: which keys, apps and spend were affected."
  }
  action_incident_task {
    order       = 2
    title       = "C4 Request emergency cost freeze with Finance"
    description = "Confirm the automated capacity cap and raise a budget alert."
  }
  action_playbook {
    order        = 3
    logic_app_id = local.a6_id
  }

  depends_on = [azurerm_role_assignment.sentinel_automation, azurerm_role_assignment.a6_responder, azurerm_role_assignment.a6_aoai]
}
