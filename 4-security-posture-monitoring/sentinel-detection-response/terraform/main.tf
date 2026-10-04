terraform {
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

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-sentinel"
  location = var.location
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-sentinel"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "sentinel" {
  workspace_id = azurerm_log_analytics_workspace.law.id
}

# Subscription Activity Log into the workspace. This is what the Azure Activity
# connector configures behind the scenes, and it fills the AzureActivity table.
resource "azurerm_monitor_diagnostic_setting" "activity" {
  name                       = "activity-to-law-sentinel"
  target_resource_id         = data.azurerm_subscription.current.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log { category = "Administrative" }
  enabled_log { category = "Security" }
  enabled_log { category = "Policy" }
  enabled_log { category = "Alert" }
}

# Target for the test role assignment that trips the rule.
resource "azurerm_user_assigned_identity" "test" {
  name                = "id-sentinel-test"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

resource "azurerm_sentinel_alert_rule_scheduled" "role_assignment" {
  name                       = "role-assignment-created"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.sentinel.workspace_id
  display_name               = "Lab: Azure role assignment created"
  description                = "A new Azure RBAC role assignment succeeded. Attackers grant themselves or a planted identity a role to keep access or escalate privilege."
  severity                   = "Medium"
  tactics                    = ["PrivilegeEscalation", "Persistence"]
  techniques                 = ["T1098"]

  query = <<-KQL
    AzureActivity
    | where OperationNameValue =~ "MICROSOFT.AUTHORIZATION/ROLEASSIGNMENTS/WRITE"
    | where ActivityStatusValue =~ "Success"
    | extend Scope = tostring(parse_json(Properties).resource)
    | project TimeGenerated, Caller, CallerIpAddress, ResourceGroup, Scope, _ResourceId
  KQL

  query_frequency      = "PT5M"
  query_period         = "PT15M"
  trigger_operator     = "GreaterThan"
  trigger_threshold    = 0
  suppression_enabled  = true
  suppression_duration = "PT1H"

  event_grouping {
    aggregation_method = "AlertPerResult"
  }

  entity_mapping {
    entity_type = "Account"
    field_mapping {
      identifier  = "FullName"
      column_name = "Caller"
    }
  }

  entity_mapping {
    entity_type = "IP"
    field_mapping {
      identifier  = "Address"
      column_name = "CallerIpAddress"
    }
  }

  entity_mapping {
    entity_type = "AzureResource"
    field_mapping {
      identifier  = "ResourceId"
      column_name = "_ResourceId"
    }
  }

  incident {
    create_incident_enabled = true
    grouping {
      enabled = false
    }
  }
}

resource "random_uuid" "automation" {}

# Triage on arrival: raise severity, tag, and move to Active for incidents from this rule only.
resource "azurerm_sentinel_automation_rule" "triage" {
  name                       = random_uuid.automation.result
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.sentinel.workspace_id
  display_name               = "Lab: escalate role assignment incidents"
  order                      = 1
  triggers_on                = "Incidents"
  triggers_when              = "Created"

  condition_json = jsonencode([
    {
      conditionType = "Property"
      conditionProperties = {
        propertyName   = "IncidentRelatedAnalyticRuleIds"
        operator       = "Contains"
        propertyValues = [azurerm_sentinel_alert_rule_scheduled.role_assignment.id]
      }
    }
  ])

  action_incident {
    order    = 1
    severity = "High"
    status   = "Active"
    labels   = ["privilege-change", "lab-sentinel"]
  }
}

output "workspace" {
  value = azurerm_log_analytics_workspace.law.name
}

output "analytics_rule" {
  value = azurerm_sentinel_alert_rule_scheduled.role_assignment.display_name
}

output "test_identity_principal_id" {
  value = azurerm_user_assigned_identity.test.principal_id
}
