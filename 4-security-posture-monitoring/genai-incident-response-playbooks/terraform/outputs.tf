output "aoai_endpoint" {
  value = azurerm_cognitive_account.aoai.endpoint
}

output "aoai_name" {
  value = azurerm_cognitive_account.aoai.name
}

output "test_user_object_id" {
  value = azuread_user.genai_user.object_id
}

output "workspace_name" {
  value = azurerm_log_analytics_workspace.lab.name
}
