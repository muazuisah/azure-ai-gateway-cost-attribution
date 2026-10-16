output "openai_base_url" {
  description = "Point any OpenAI-compatible client at this."
  value       = module.ai_gateway.openai_base_url
}

output "model_aliases" {
  description = "Aliases callers may put in the model field."
  value       = module.ai_gateway.model_aliases
}

output "demo_subscription_key" {
  description = "Subscription key for the demo application. Pass it in the api-key header."
  value       = module.ai_gateway.subscription_keys["demo-app"]
  sensitive   = true
}

output "smoke_test_command" {
  description = "Copy, paste, run."
  value       = <<-EOT
    python scripts/smoke_test.py \
      --base-url ${module.ai_gateway.openai_base_url} \
      --api-key "$(terraform output -raw demo_subscription_key)" \
      --model chat-small
  EOT
}

output "application_insights_id" {
  description = "Where the gateway's telemetry lands."
  value       = module.observability.application_insights_id
}

output "foundry_accounts" {
  description = "Foundry accounts behind the gateway."
  value       = module.foundry.account_ids
}

output "foundry_projects" {
  description = "Foundry projects created on the account, empty unless create_foundry_project = true. The project endpoint is what the Foundry SDK and portal expect, as distinct from the inference endpoint APIM uses."
  value       = module.foundry.projects
}
