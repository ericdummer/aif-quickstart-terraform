# Microsoft Entra security group for AI Foundry project access
resource "azuread_group" "sg_ai_users" {
  display_name     = "sg-ed-af-quickstart-ai-users"
  description      = "AI Foundry af-quickstart project users — Azure AI User role"
  security_enabled = true
  mail_enabled     = false

  members = var.security_group_members
}

# Lookup the built-in "Azure AI User" role definition
data "azurerm_role_definition" "azure_ai_user" {
  name  = "Azure AI User"
  scope = "/subscriptions/${var.subscription_id}"
}

# Assign Azure AI User role to the security group, scoped to the project
# (least-privilege: members can use deployed models and agents in this project only)
resource "azurerm_role_assignment" "sg_ai_users_project" {
  scope              = azurerm_cognitive_account_project.proj.id
  role_definition_id = data.azurerm_role_definition.azure_ai_user.id
  principal_id       = azuread_group.sg_ai_users.object_id
  principal_type     = "Group"
}
