# GPT-4.1-mini model deployment on the AI Services account
resource "azurerm_cognitive_deployment" "deploy_gpt41mini" {
  name                 = "deploy-gpt41mini"
  cognitive_account_id = azurerm_cognitive_account.ais.id

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
