variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure AD tenant ID."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, prod)."
  type        = string
  default     = "dev"
}

variable "custom_subdomain_name" {
  description = <<-EOT
    Globally unique custom subdomain for the AI Services account.
    Used for Entra ID (AAD) token auth and the project endpoint URL.
    Format: lowercase letters, numbers, hyphens. No spaces.
  EOT
  type    = string
  default = "ais-ed-af-quickstart"
}

variable "model_name" {
  description = "Name of the OpenAI model to deploy."
  type        = string
  default     = "gpt-4.1-mini"
}

variable "model_version" {
  description = "Version of the OpenAI model to deploy."
  type        = string
  default     = "2025-04-14"
}

variable "model_capacity" {
  description = "Tokens-per-minute capacity in thousands (e.g. 10 = 10k TPM)."
  type        = number
  default     = 10
}

variable "security_group_members" {
  description = <<-EOT
    List of Azure AD object IDs (users or service principals) to add as
    members of the AI Users security group. Keep these in secrets/<env>.tfvars.
  EOT
  type      = list(string)
  sensitive = true
  default   = []
}
