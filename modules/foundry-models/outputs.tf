output "accounts" {
  description = "Created Foundry accounts, keyed by the logical account key. Feed this directly into the ai-gateway module's `foundry_backends` variable."
  value = {
    for key, account in azurerm_cognitive_account.this : key => {
      id       = account.id
      name     = account.name
      location = account.location

      # Control-plane endpoint as reported by ARM, e.g. https://<subdomain>.cognitiveservices.azure.com/
      endpoint = account.endpoint

      # Inference host for the Azure OpenAI v1 API surface. The v1 API is documented against the
      # openai.azure.com and services.ai.azure.com hostnames, so the gateway targets this host
      # explicitly rather than reusing `endpoint`.
      subdomain        = account.custom_subdomain_name
      inference_url    = "https://${account.custom_subdomain_name}.openai.azure.com"
      inference_v1_url = "https://${account.custom_subdomain_name}.openai.azure.com/openai/v1"

      principal_id = account.identity[0].principal_id
      deployments  = local.deployments_by_account[key]
    }
  }
}

output "account_ids" {
  description = "Map of account key to resource ID."
  value       = { for key, account in azurerm_cognitive_account.this : key => account.id }
}

output "endpoints" {
  description = "Map of account key to data-plane endpoint URL."
  value       = { for key, account in azurerm_cognitive_account.this : key => account.endpoint }
}

output "deployments_by_account" {
  description = "Deployment names hosted by each account. The ai-gateway module uses this to validate deployment-name parity across every backend in a pool."
  value       = local.deployments_by_account
}

output "deployment_ids" {
  description = "Map of '<account key>/<deployment name>' to the deployment resource ID."
  value       = { for key, deployment in azurerm_cognitive_deployment.this : key => deployment.id }
}

output "model_catalog" {
  description = "Flattened catalogue of every deployment created, useful for documentation and for seeding the cost-attribution pricing map."
  value = {
    for key, deployment in local.account_deployments :
    key => {
      account_key   = deployment.account_key
      deployment    = deployment.deployment_key
      model_name    = deployment.deployment.model_name
      model_format  = deployment.deployment.model_format
      model_version = deployment.deployment.model_version
      sku_name      = deployment.deployment.sku_name
      capacity      = deployment.deployment.capacity
    }
  }
}

output "projects" {
  description = "Created Foundry projects, keyed by the logical project key. `endpoint` is the project-scoped URL the Foundry SDK expects; `principal_id` is the identity to grant roles to on any resource the project connects to."
  value = {
    for key, project in azurerm_cognitive_account_project.this : key => {
      id           = project.id
      name         = project.name
      account_key  = var.projects[key].account_key
      endpoints    = project.endpoints
      principal_id = project.identity[0].principal_id
    }
  }
}

output "connections" {
  description = "Entra ID connections created on the Foundry accounts, keyed by connection name."
  value = {
    for key, conn in azurerm_cognitive_account_connection_entra_id.this : key => {
      id       = conn.id
      category = conn.category
      target   = conn.target
    }
  }
}
