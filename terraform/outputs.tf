output "resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.rg.name
}

output "ai_services_id" {
  description = "Resource ID of the AI Services (Cognitive Account)."
  value       = azurerm_cognitive_account.ais.id
}

output "ai_services_endpoint" {
  description = "Base endpoint of the AI Services account."
  value       = azurerm_cognitive_account.ais.endpoint
}

output "project_id" {
  description = "Resource ID of the Foundry project."
  value       = azurerm_cognitive_account_project.proj.id
}

output "project_endpoint" {
  description = <<-EOT
    Project endpoint URL used in application config (PROJECT_ENDPOINT env var).
    Format: https://<subdomain>.services.ai.azure.com/api/projects/<project-name>
  EOT
  value = lookup(
    azurerm_cognitive_account_project.proj.endpoints,
    "AI Foundry API",
    "https://${var.custom_subdomain_name}.services.ai.azure.com/api/projects/proj-ed-af-quickstart"
  )
}

output "model_deployment_name" {
  description = "Name of the deployed GPT model — pass this as the model param in SDK calls."
  value       = azurerm_cognitive_deployment.deploy_gpt41mini.name
}

output "security_group_object_id" {
  description = "Object ID of the Entra security group for role assignment references."
  value       = azuread_group.sg_ai_users.object_id
}
