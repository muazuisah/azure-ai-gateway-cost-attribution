variable "name_prefix" {
  description = "Prefix for the resources this example creates. Keep it distinct from anything already in the target resource group."
  type        = string
  default     = "aigw"
}

variable "environment_name" {
  description = "Environment label, stamped onto every ledger record."
  type        = string
  default     = "prod"
}

variable "resource_group_name" {
  description = "Existing resource group to create the reporting artefacts in."
  type        = string
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------------------------------
# Existing infrastructure
# ---------------------------------------------------------------------------------------------------

variable "existing_api_management_id" {
  description = "Resource ID of the API Management instance to publish the gateway API onto. Any tier except Consumption; the token-limit policies are unavailable there."
  type        = string
}

variable "application_insights_id" {
  description = "Resource ID of the Application Insights instance that receives the chargeback ledger."
  type        = string
}

variable "application_insights_instrumentation_key" {
  description = "Instrumentation key for that Application Insights instance."
  type        = string
  sensitive   = true
}

variable "foundry_backends" {
  description = <<-EOT
    Existing Foundry endpoints, keyed by a short backend name.

    inference_url is the host with no path and no trailing slash, for example
    https://contoso-aif-eastus.openai.azure.com. List the deployments each endpoint hosts so that the
    gateway can check pool parity at plan time rather than leaving you to discover it as intermittent
    404s in production.
  EOT
  type = map(object({
    inference_url = string
    deployments   = optional(list(string), [])
    description   = optional(string)
  }))
}

variable "foundry_account_ids" {
  description = "Foundry account IDs to grant the gateway identity Cognitive Services User on. Leave empty when the grants already exist or are managed by a platform team."
  type        = map(string)
  default     = {}
}

variable "foundry_resource_group_id" {
  description = "Resource group whose actual Azure spend the budget watches - the one holding the Foundry accounts. Required when enable_budget is true."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------------------------------
# Catalogue and tiers
# ---------------------------------------------------------------------------------------------------

variable "model_routes" {
  description = "Client-facing aliases mapped onto physical deployments and an ordered set of backends."
  type = map(object({
    deployment       = string
    backend_priority = map(number)
    backend_weight   = optional(map(number), {})
    description      = optional(string)
  }))
}

variable "products" {
  description = "Commercial tiers, each with its own token ceiling. The product is the governance boundary; put the limits here rather than on the API so that one noisy consumer cannot starve another."
  type = map(object({
    display_name           = optional(string)
    description            = optional(string)
    published              = optional(bool, true)
    approval_required      = optional(bool, false)
    subscription_required  = optional(bool, true)
    subscriptions_limit    = optional(number)
    tokens_per_minute      = optional(number)
    token_quota            = optional(number)
    token_quota_period     = optional(string, "Monthly")
    allowed_models         = optional(list(string), [])
    estimate_prompt_tokens = optional(bool, true)
  }))
}

variable "subscriptions" {
  description = "Consuming applications. The subscription display name is the chargeback identity."
  type = map(object({
    product_key  = string
    display_name = optional(string)
    state        = optional(string, "active")
    cost_centre  = optional(string)
    owner        = optional(string)
  }))
  default = {}
}

# ---------------------------------------------------------------------------------------------------
# Chargeback
# ---------------------------------------------------------------------------------------------------

variable "pricing_map" {
  description = <<-EOT
    Rates per million tokens, keyed by model alias, produced by scripts/generate_pricing_map.py.

    These are published list rates. They know nothing about your enterprise agreement discount, your
    reservations, or provisioned throughput amortisation - which is exactly why the workbook allocates
    real Cost Management spend by share of tokens rather than reporting this number as the bill.
  EOT
  type        = any
}

variable "consumers" {
  description = "Finance metadata per consuming application, keyed to match the subscription names."
  type = map(object({
    cost_centre        = string
    owner              = optional(string)
    business_unit      = optional(string)
    monthly_budget_usd = optional(number)
    alert_email        = optional(string)
  }))
  default = {}
}

variable "alert_emails" {
  description = "Addresses that receive cost and data-quality alerts."
  type        = list(string)
  default     = []
}

variable "enable_budget" {
  description = "Create a Cost Management budget over the Foundry resource group."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly budget over actual Azure spend."
  type        = number
  default     = 5000
}

variable "budget_thresholds_percent" {
  description = "Budget notification thresholds. Values above 100 become forecast notifications, which are the ones that arrive while there is still time to act."
  type        = list(number)
  default     = [50, 80, 100]
}

variable "daily_spend_threshold_usd" {
  description = "Per-product estimated daily spend that raises an alert."
  type        = number
  default     = 250
}

variable "token_rate_alert_threshold" {
  description = "Total tokens in five minutes that raises a near-real-time metric alert. Set to null to disable."
  type        = number
  default     = 2000000
}

variable "unmeasured_usage_threshold_percent" {
  description = "Percentage of successful requests returning no usage block that raises an alert. Usually streaming clients that have not set stream_options.include_usage; their spend is real and invisible."
  type        = number
  default     = 5
}

variable "enable_cache_economics_alert" {
  description = "Alert when a model's cache writes cost more than its cache hits save. Writing to a prompt cache is billed at a premium, so a workload whose prompts vary too much to hit the cache pays extra for a cache it never reads."
  type        = bool
  default     = true
}

variable "cache_write_premium_usd_per_million" {
  description = "Assumed extra cost per million tokens of writing to the prompt cache rather than sending the same tokens as plain input. Used only to judge whether caching pays for itself, not for billing."
  type        = number
  default     = 0.25
}

variable "enable_eventhub_audit" {
  description = "Stream every request out unsampled for audit-grade chargeback."
  type        = bool
  default     = false
}
