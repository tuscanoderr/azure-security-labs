terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 4.55 is the first 4.x release with azurerm_cognitive_account_project.
      version = "~> 4.55"
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

variable "model_name" {
  type    = string
  default = "gpt-4.1-mini"
}

variable "model_version" {
  type    = string
  default = "2025-04-14"
}

# Thousands of tokens per minute. 1 is about 1,000 TPM, the Layer 1 limit.
variable "model_capacity" {
  type    = number
  default = 1
}

# APIM requires a publisher contact. Use a mailbox you own; nothing is sent
# to it during the lab.
variable "apim_publisher_email" {
  type    = string
  default = "lab-admin@example.com"
}

# The Foundry subdomain and the APIM gateway host name are global, so each
# build gets its own suffix (the original build used d3r7).
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

locals {
  suffix          = random_string.suffix.result
  foundry_name    = "foundry-lab-${local.suffix}"
  deployment_name = "chat-dep"
}

resource "azurerm_resource_group" "lab" {
  name     = "lab-az-foundry"
  location = var.location
}

# Foundry resource. Projects need project management, an identity and a
# custom subdomain on the account.
resource "azurerm_cognitive_account" "foundry" {
  name                       = local.foundry_name
  location                   = azurerm_resource_group.lab.location
  resource_group_name        = azurerm_resource_group.lab.name
  kind                       = "AIServices"
  sku_name                   = "S0"
  custom_subdomain_name      = local.foundry_name
  project_management_enabled = true

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account_project" "lab" {
  name                 = "${local.foundry_name}-project"
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  location             = azurerm_resource_group.lab.location

  identity {
    type = "SystemAssigned"
  }
}

# Custom guardrail gr-jailbreak-lab. Prompt Shields for direct jailbreaks and
# indirect injection on user input, the four harm categories both ways, and
# protected material on output. Spotlighting is set in the portal.
# The provider requires severity_threshold on every filter, including the
# ones where the service ignores it.
resource "azurerm_cognitive_account_rai_policy" "jailbreak" {
  name                 = "gr-jailbreak-lab"
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  base_policy_name     = "Microsoft.DefaultV2"

  content_filter {
    name               = "Jailbreak"
    filter_enabled     = true
    block_enabled      = true
    severity_threshold = "Medium"
    source             = "Prompt"
  }

  content_filter {
    name               = "Indirect Attack"
    filter_enabled     = true
    block_enabled      = true
    severity_threshold = "Medium"
    source             = "Prompt"
  }

  dynamic "content_filter" {
    for_each = setproduct(["Hate", "Sexual", "Violence", "Selfharm"], ["Prompt", "Completion"])
    content {
      name               = content_filter.value[0]
      filter_enabled     = true
      block_enabled      = true
      severity_threshold = "Medium"
      source             = content_filter.value[1]
    }
  }

  content_filter {
    name               = "Protected Material Text"
    filter_enabled     = true
    block_enabled      = true
    severity_threshold = "Medium"
    source             = "Completion"
  }

  content_filter {
    name               = "Protected Material Code"
    filter_enabled     = true
    block_enabled      = true
    severity_threshold = "Medium"
    source             = "Completion"
  }
}

# Layer 1 rate limit: the deployment's own TPM capacity.
resource "azurerm_cognitive_deployment" "chat" {
  name                 = local.deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  rai_policy_name      = azurerm_cognitive_account_rai_policy.jailbreak.name

  model {
    format  = "OpenAI"
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.model_capacity
  }
}

# AI Gateway. The Developer tier takes 30 to 45 minutes to create.
resource "azurerm_api_management" "gateway" {
  name                = "apim-foundry-${local.suffix}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  publisher_name      = "SC-500 lab"
  publisher_email     = var.apim_publisher_email
  sku_name            = "Developer_1"

  identity {
    type = "SystemAssigned"
  }
}

# The gateway calls the model with its own identity, so no model key sits in
# the gateway path.
resource "azurerm_role_assignment" "apim_openai_user" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.gateway.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Data plane role assignments take a minute or two to apply.
resource "time_sleep" "rbac" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.apim_openai_user]
}

resource "azurerm_api_management_backend" "foundry" {
  name                = "foundry-openai"
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.lab.name
  protocol            = "http"
  url                 = "${trimsuffix(azurerm_cognitive_account.foundry.endpoint, "/")}/openai"
}

# Callers present an APIM subscription key; the model key is never used.
resource "azurerm_api_management_api" "openai" {
  name                  = "foundry-openai"
  api_management_name   = azurerm_api_management.gateway.name
  resource_group_name   = azurerm_resource_group.lab.name
  revision              = "1"
  display_name          = "Foundry OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.lab.name
  display_name        = "Chat completions"
  method              = "POST"
  url_template        = "/deployments/{deployment-id}/chat/completions"

  template_parameter {
    name     = "deployment-id"
    type     = "string"
    required = true
  }
}

# Layer 2: 500 TPM (429 when exceeded) and 1,000 tokens per hour (403 when
# exceeded), one counter for the project's use of chat-dep.
resource "azurerm_api_management_api_policy" "token_limit" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = azurerm_resource_group.lab.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-backend-service backend-id="${azurerm_api_management_backend.foundry.name}" />
        <set-header name="api-key" exists-action="delete" />
        <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
        <llm-token-limit
          counter-key="${azurerm_cognitive_account_project.lab.name}-${local.deployment_name}"
          tokens-per-minute="500"
          token-quota="1000"
          token-quota-period="Hourly"
          estimate-prompt-tokens="false"
          remaining-tokens-header-name="x-remaining-tokens" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML

  depends_on = [time_sleep.rbac]
}

output "foundry_endpoint" {
  value = azurerm_cognitive_account.foundry.endpoint
}

output "project_name" {
  value = azurerm_cognitive_account_project.lab.name
}

output "apim_name" {
  value = azurerm_api_management.gateway.name
}

output "gateway_chat_url" {
  value = "${azurerm_api_management.gateway.gateway_url}/openai/deployments/${local.deployment_name}/chat/completions"
}
