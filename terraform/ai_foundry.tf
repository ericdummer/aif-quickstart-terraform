# Azure AI Services account — the Foundry resource (new portal experience)
#
# Note: azurerm_cognitive_account with kind=AIServices is the recommended
# Terraform resource for new Foundry projects. The legacy azurerm_ai_foundry
# (hub-based) is not used here.
resource "azurerm_cognitive_account" "ais" {
  name                = "ais-ed-af-quickstart"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "AIServices"
  sku_name            = "S0"

  # Required for project creation within this account
  project_management_enabled = true

  # Required for Entra ID (AAD) token auth and agent endpoints
  custom_subdomain_name = var.custom_subdomain_name

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Foundry project scoped under the AI Services account
resource "azurerm_cognitive_account_project" "proj" {
  name                 = "proj-ed-af-quickstart"
  cognitive_account_id = azurerm_cognitive_account.ais.id
  location             = azurerm_resource_group.rg.location
  display_name         = "AF Quickstart Project"
  description          = "Azure AI Foundry quickstart project (ed)"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}
