# Defender for AI services: Prompt Shields signals become security alerts with prompt evidence.
# Subscription scope; set back to Free at cleanup (terraform destroy does this).
resource "azurerm_security_center_subscription_pricing" "ai" {
  tier          = "Standard"
  resource_type = "AI"

  extension {
    name = "AIPromptEvidence"
  }
}
