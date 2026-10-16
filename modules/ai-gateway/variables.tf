# ---------------------------------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Resource group that holds the gateway resources."
  type        = string
}

variable "location" {
  description = "Azure region for the gateway."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to generated resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 characters, lowercase alphanumeric or hyphen."
  }
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

variable "environment_name" {
  description = "Environment label stamped onto telemetry and response headers, for example dev, test or prod."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------------------------------
# API Management instance
# ---------------------------------------------------------------------------------------------------

variable "existing_api_management_id" {
  description = "Resource ID of an existing API Management instance to configure instead of creating one. Brownfield engagements almost always set this."
  type        = string
  default     = null
}

variable "apim_sku_name" {
  description = <<-EOT
    API Management SKU in "<tier>_<capacity>" form.

    StandardV2_1 is the default: it supports every AI gateway policy used here, supports VNet
    integration, and costs a fraction of Premium. Move to PremiumV2 when you need multi-region gateway
    presence, workspaces, or availability zones. Developer_1 is for labs only and carries no SLA.
  EOT
  type        = string
  default     = "StandardV2_1"

  validation {
    condition     = can(regex("^(Developer|Basic|Standard|Premium|BasicV2|StandardV2|PremiumV2|Consumption)_[0-9]+$", var.apim_sku_name))
    error_message = "apim_sku_name must look like StandardV2_1, PremiumV2_2, Developer_1, and so on."
  }

  validation {
    condition     = !startswith(var.apim_sku_name, "Consumption")
    error_message = "The Consumption tier does not support the llm-token-limit policy and is not supported by this accelerator."
  }
}

variable "publisher_name" {
  description = "Publisher name shown in the developer portal. Required when creating an API Management instance."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "Publisher email for API Management notifications. Required when creating an API Management instance."
  type        = string
  default     = null

  validation {
    condition     = var.publisher_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", coalesce(var.publisher_email, "x@y.z")))
    error_message = "publisher_email must be a valid email address."
  }
}

variable "virtual_network_type" {
  description = "API Management virtual network mode: None, External, or Internal."
  type        = string
  default     = "None"

  validation {
    condition     = contains(["None", "External", "Internal"], var.virtual_network_type)
    error_message = "virtual_network_type must be None, External, or Internal."
  }
}

variable "virtual_network_subnet_id" {
  description = "Subnet resource ID for API Management network integration. Required when virtual_network_type is not None."
  type        = string
  default     = null
}

variable "public_network_access_enabled" {
  description = "Whether the API Management gateway accepts traffic from the public internet."
  type        = bool
  default     = true
}

variable "disable_legacy_tls" {
  description = <<-EOT
    Turn off SSL 3.0, TLS 1.0 and TLS 1.1 on both the client and the backend side.

    Only applied on the classic tiers (Developer, Basic, Standard, Premium), which are the only ones
    that expose the setting. The v2 tiers reject legacy protocols by default and have no equivalent
    knob, so leaving this at true is correct on every SKU.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------------------------------
# Foundry backends and routing
# ---------------------------------------------------------------------------------------------------

variable "foundry_backends" {
  description = <<-EOT
    Foundry endpoints the gateway may route to, keyed by a short backend name. Feed the `accounts`
    output of the foundry-models module straight in, or hand-assemble it for pre-existing accounts.

    * inference_url - Base URL of the Foundry inference host, without a trailing slash, for example
                      https://contoso-aif-eastus.openai.azure.com
    * deployments   - Deployment names this endpoint hosts. Used to validate pool parity at plan time.
  EOT

  type = map(object({
    inference_url = string
    deployments   = optional(list(string), [])
    description   = optional(string)
  }))

  validation {
    condition     = length(var.foundry_backends) > 0
    error_message = "At least one Foundry backend must be supplied."
  }

  validation {
    condition = alltrue([
      for k, v in var.foundry_backends : can(regex("^https://[^/]+$", v.inference_url))
    ])
    error_message = "Each inference_url must be an https URL with no path and no trailing slash, for example https://contoso-aif-eastus.openai.azure.com."
  }
}

variable "foundry_account_ids" {
  description = <<-EOT
    Resource IDs of the Foundry accounts the gateway must be able to call, keyed by the same backend
    name used in foundry_backends. The module grants its managed identity Cognitive Services User on
    each one. Pass an empty map when role assignments are managed elsewhere, for example by a platform
    team that owns the Foundry subscription.
  EOT
  type        = map(string)
  default     = {}
}

variable "model_routes" {
  description = <<-EOT
    The gateway's public model catalogue: client-facing aliases mapped onto a physical deployment and
    an ordered set of backends.

    * deployment       - Physical deployment name, which must exist on every backend listed below.
    * backend_priority - Backend key to priority group (1 is highest). All members of a group are used
                         before any lower-priority group is touched, and a lower group is only reached
                         once every higher member's circuit breaker has tripped. Put reserved (PTU)
                         capacity in group 1 and pay-as-you-go in group 2 to get automatic spillover.
    * backend_weight   - Optional backend key to relative weight within its priority group.
    * description      - Shown in the developer portal and the /models discovery response.

    Example:
      gpt-chat = {
        deployment       = "gpt-4o"
        backend_priority = { eastus-ptu = 1, eastus-std = 2, westeurope-std = 3 }
        backend_weight   = { eastus-std = 70, westeurope-std = 30 }
      }
  EOT

  type = map(object({
    deployment       = string
    backend_priority = map(number)
    backend_weight   = optional(map(number), {})
    description      = optional(string)
  }))

  validation {
    condition     = length(var.model_routes) > 0
    error_message = "At least one model route must be defined; a gateway with no catalogue serves nothing."
  }

  validation {
    condition = alltrue([
      for alias, route in var.model_routes : length(route.backend_priority) > 0
    ])
    error_message = "Every model route must list at least one backend in backend_priority."
  }

  validation {
    condition = alltrue(flatten([
      for alias, route in var.model_routes : [
        for backend_key, priority in route.backend_priority : priority >= 0 && priority <= 100
      ]
    ]))
    error_message = "Backend priorities must be between 0 and 100."
  }

  validation {
    condition = alltrue(flatten([
      for alias, route in var.model_routes : [
        for backend_key, weight in route.backend_weight : weight >= 0 && weight <= 100
      ]
    ]))
    error_message = "Backend weights must be between 0 and 100."
  }

  validation {
    condition = alltrue([
      for alias, route in var.model_routes : length(route.backend_priority) <= 30
    ])
    error_message = "An API Management backend pool holds at most 30 backends."
  }

  validation {
    condition     = alltrue([for alias, _ in var.model_routes : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", alias))])
    error_message = "Model aliases must be 1-64 characters of letters, digits, dot, underscore or hyphen."
  }
}

variable "enforce_deployment_parity" {
  description = <<-EOT
    Fail the plan when a model route references a backend that does not host the route's deployment.

    A backend pool treats its members as interchangeable, so a missing deployment on one member turns
    into intermittent 404s that only appear once load balancing happens to select that member. Leave
    this on unless you are supplying backends whose deployment lists you cannot enumerate.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------------------------------
# Circuit breakers
# ---------------------------------------------------------------------------------------------------

variable "circuit_breaker" {
  description = <<-EOT
    Circuit breaker applied to every Foundry backend. API Management currently supports one rule per
    backend, so throttling and server errors share a single rule.

    accept_retry_after matters more than it looks: a throttled Foundry deployment can return a
    Retry-After measured in hours, and honouring it is what stops the gateway from hammering a backend
    that has told it to go away.
  EOT

  type = object({
    enabled            = optional(bool, true)
    name               = optional(string, "foundry-breaker")
    failure_count      = optional(number, 5)
    interval           = optional(string, "PT1M")
    trip_duration      = optional(string, "PT1M")
    accept_retry_after = optional(bool, true)
    status_code_min    = optional(number, 429)
    status_code_max    = optional(number, 599)
  })

  default = {}

  validation {
    condition     = var.circuit_breaker.failure_count >= 1 && var.circuit_breaker.failure_count <= 10000
    error_message = "circuit_breaker.failure_count must be between 1 and 10000."
  }

  validation {
    condition     = can(regex("^P(T?[0-9]+[DHMS])+$", var.circuit_breaker.interval)) && can(regex("^P(T?[0-9]+[DHMS])+$", var.circuit_breaker.trip_duration))
    error_message = "circuit_breaker.interval and trip_duration must be ISO 8601 durations, for example PT1M or PT1H."
  }

  validation {
    condition     = var.circuit_breaker.status_code_min >= 200 && var.circuit_breaker.status_code_max <= 599 && var.circuit_breaker.status_code_min <= var.circuit_breaker.status_code_max
    error_message = "circuit_breaker status codes must satisfy 200 <= min <= max <= 599."
  }
}

# ---------------------------------------------------------------------------------------------------
# Products, subscriptions and token governance
# ---------------------------------------------------------------------------------------------------

variable "products" {
  description = <<-EOT
    Commercial tiers published by the gateway. Each product carries its own token rate limit and
    period quota, enforced per subscribing application.

    * tokens_per_minute   - Rate ceiling. Breaching it returns 429 with Retry-After. Null disables.
    * token_quota         - Tokens allowed per token_quota_period. Breaching it returns 403. Null disables.
    * token_quota_period  - Hourly, Daily, Weekly, Monthly or Yearly.
    * allowed_models      - Aliases this tier may call. Empty means every alias in model_routes.
    * approval_required   - Whether a subscription request needs administrator approval.
  EOT

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

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.products :
      v.tokens_per_minute != null || v.token_quota != null
    ])
    error_message = "Every product must set tokens_per_minute, token_quota, or both. The llm-token-limit policy requires at least one."
  }

  validation {
    condition = alltrue([
      for k, v in var.products :
      contains(["Hourly", "Daily", "Weekly", "Monthly", "Yearly"], v.token_quota_period)
    ])
    error_message = "token_quota_period must be Hourly, Daily, Weekly, Monthly, or Yearly."
  }

  validation {
    condition     = alltrue([for k, v in var.products : can(regex("^[a-z0-9][a-z0-9-]{1,78}$", k))])
    error_message = "Product keys must be 2-79 characters, lowercase alphanumeric or hyphen."
  }
}

variable "subscriptions" {
  description = <<-EOT
    Consuming applications. Each becomes an API Management subscription, and the map key becomes the
    subscription's id verbatim - which is what the gateway stamps onto every ledger record as the
    chargeback identity. Name these after real applications rather than after people.

    The key is therefore a published identifier, not an internal label. It must be a valid API
    Management subscription id (letters, digits and hyphens, starting with a letter or digit), and
    renaming one re-keys that consumer's history: reports split at the rename rather than following it.

    In subscription_key mode this key is what you use in the cost-attribution module's `consumers`
    register. In entra_id mode the ledger records the Entra claim instead, so the register is keyed by
    the application id there - see that module's documentation.
  EOT

  type = map(object({
    product_key  = string
    display_name = optional(string)
    state        = optional(string, "active")
    cost_centre  = optional(string)
    owner        = optional(string)
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.subscriptions : contains(["active", "suspended", "submitted", "rejected", "cancelled", "expired"], v.state)
    ])
    error_message = "Subscription state must be one of active, suspended, submitted, rejected, cancelled, expired."
  }

  validation {
    condition = alltrue([
      for k, v in var.subscriptions : can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,79}$", k))
    ])
    error_message = "Subscription keys become API Management subscription ids verbatim, so each must be 1-80 characters of letters, digits or hyphens and must start with a letter or digit."
  }
}

# ---------------------------------------------------------------------------------------------------
# API surface
# ---------------------------------------------------------------------------------------------------

variable "api_path" {
  description = "Path segment the API is published under. The default makes the gateway a drop-in replacement for a Foundry endpoint, so an OpenAI SDK only needs its base_url changed."
  type        = string
  default     = "openai/v1"
}

variable "enable_responses_api" {
  description = "Publish POST /responses in addition to chat completions and embeddings."
  type        = bool
  default     = true
}

variable "forward_timeout_seconds" {
  description = "Backend forward timeout. Reasoning models on long prompts routinely exceed 60 seconds, so the default is generous; APIM's own hard ceiling still applies."
  type        = number
  default     = 240

  validation {
    condition     = var.forward_timeout_seconds >= 10 && var.forward_timeout_seconds <= 300
    error_message = "forward_timeout_seconds must be between 10 and 300."
  }
}

variable "buffer_response" {
  description = "Whether to buffer backend responses. Must be false for token-by-token streaming to reach the client; when false, usage is captured from the final streamed chunk."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------------------------------

variable "application_insights_id" {
  description = "Application Insights resource ID used by the API Management logger."
  type        = string
}

variable "application_insights_instrumentation_key" {
  description = "Application Insights instrumentation key used by the API Management logger."
  type        = string
  sensitive   = true
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID for API Management diagnostic settings. Required when enable_diagnostics is true, and ignored otherwise."
  type        = string
  default     = null
}

variable "enable_diagnostics" {
  description = <<-EOT
    Whether to create the API Management diagnostic setting that sends GatewayLogs and all metrics to
    log_analytics_workspace_id.

    GatewayLogs is the per-request record - which operation, which backend, which subscription, the
    response code and the latency. The token metrics the policy emits are aggregates and cannot answer
    "what happened to that one request at 14:07"; this log can.

    This is a separate flag rather than being inferred from log_analytics_workspace_id because the
    workspace is normally created in the same apply as the gateway, which makes its id unknown at plan
    time. Terraform cannot resolve a count from an unknown value and refuses to plan. A literal bool is
    always known, so the configuration stays plannable in a single pass.
  EOT
  type        = bool
  default     = false
}

variable "diagnostic_sampling_percentage" {
  description = <<-EOT
    Percentage of LLM API requests logged to Application Insights.

    Leave this at 100 when cost attribution is enabled. Sampling drops whole requests, and every
    dropped request is a chargeback row that never existed and spend that is never attributed. If
    telemetry cost is a problem, shorten retention instead of sampling.
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.diagnostic_sampling_percentage > 0 && var.diagnostic_sampling_percentage <= 100
    error_message = "diagnostic_sampling_percentage must be greater than 0 and at most 100."
  }
}

variable "metric_namespace" {
  description = "Azure Monitor custom metric namespace for llm-emit-token-metric."
  type        = string
  default     = "aigateway"
}

variable "log_request_and_response_bodies" {
  description = <<-EOT
    Log prompt and completion payloads to Application Insights.

    Off by default and deliberately so. Prompts routinely contain personal or confidential data, and
    turning this on makes your telemetry store a copy of it. Enable only with a documented legal basis,
    a matching retention policy, and access controls on the workspace.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------
# Content safety
# ---------------------------------------------------------------------------------------------------

variable "enable_content_safety" {
  description = "Apply llm-content-safety to generative operations."
  type        = bool
  default     = false
}

variable "content_safety_endpoint" {
  description = "Azure AI Content Safety endpoint URL. Required when enable_content_safety is true."
  type        = string
  default     = null

  validation {
    # Prompts are sent to this endpoint in full, so a plaintext URL here would put the very content
    # being screened on the wire. Mirrors the constraint foundry_backends places on inference_url.
    condition     = var.content_safety_endpoint == null || can(regex("^https://", var.content_safety_endpoint))
    error_message = "content_safety_endpoint must be an https URL."
  }
}

variable "content_safety_shield_prompt" {
  description = "Enable Prompt Shield jailbreak and indirect-attack detection on inbound prompts."
  type        = bool
  default     = true
}

variable "content_safety_max_characters" {
  description = <<-EOT
    Longest prompt, in characters, that will be submitted for content safety screening. Requests
    above this are refused with 413 and an error naming the limit.

    Azure AI Content Safety accepts at most 10,000 characters per call. Beyond that the screening
    call fails, and API Management reports that failure as "Request failed content safety check" -
    indistinguishable from a genuine moderation block, for a prompt that was never actually assessed.
    Checking the length first turns that into an accurate error.

    The default matches the service limit, so lower it only to refuse long prompts sooner. Raising it
    does not raise the service's own limit and simply restores the misleading failure.
  EOT
  type        = number
  default     = 10000

  validation {
    condition     = var.content_safety_max_characters > 0 && var.content_safety_max_characters <= 10000
    error_message = "content_safety_max_characters must be between 1 and 10000, the maximum Azure AI Content Safety accepts in a single call."
  }
}

variable "content_safety_thresholds" {
  description = "Severity threshold per harm category on the EightSeverityLevels scale. Lower is stricter; content at or above the threshold is blocked."
  type = object({
    hate      = optional(number, 4)
    self_harm = optional(number, 4)
    sexual    = optional(number, 4)
    violence  = optional(number, 4)
  })
  default = {}

  validation {
    condition = alltrue([
      var.content_safety_thresholds.hate >= 0 && var.content_safety_thresholds.hate <= 7,
      var.content_safety_thresholds.self_harm >= 0 && var.content_safety_thresholds.self_harm <= 7,
      var.content_safety_thresholds.sexual >= 0 && var.content_safety_thresholds.sexual <= 7,
      var.content_safety_thresholds.violence >= 0 && var.content_safety_thresholds.violence <= 7,
    ])
    error_message = "Content safety thresholds must be between 0 and 7 on the EightSeverityLevels scale."
  }
}

# ---------------------------------------------------------------------------------------------------
# Semantic cache
# ---------------------------------------------------------------------------------------------------

variable "enable_semantic_cache" {
  description = "Enable llm-semantic-cache-lookup and llm-semantic-cache-store. Requires an external RediSearch-compatible cache. Off by default on both cost and correctness grounds: it only pays back on repetitive prompts, and it matches on meaning, so prompts that differ only by a record id are the same question to it. Enable it per route, on traffic whose answers do not depend on an identifier in the text. See docs/cost-attribution.md."
  type        = bool
  default     = false
}

variable "semantic_cache_redis_connection_string" {
  description = "Connection string for the RediSearch-compatible cache. Required when enable_semantic_cache is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "semantic_cache_embeddings_deployment" {
  description = "Embedding deployment name used to vectorise prompts for similarity lookup. Must exist on the backend named by semantic_cache_embeddings_backend."
  type        = string
  default     = "text-embedding-3-small"
}

variable "semantic_cache_embeddings_backend" {
  description = "Key from foundry_backends whose endpoint serves the embedding model for cache lookups. Defaults to the first backend."
  type        = string
  default     = null
}

variable "semantic_cache_settings" {
  description = <<-EOT
    Cache tuning.

    * score_threshold  - Maximum vector distance for a hit. Lower is stricter. No value makes the
                         cache safe for prompts distinguished by an identifier: measured on this
                         gateway at 0.05, "status of order number 88213" was served the cached
                         answer naming order 10007. Tune this for paraphrase tolerance on broadly
                         worded traffic, not as a correctness control.
    * duration_seconds - Time to live for a cached completion.
    * max_temperature  - Requests above this temperature bypass the cache, so callers who asked for
                         variety still get it.
    * share_across_consumers
                       - false (default) adds caller identity to the cache key, so a near-match can
                         never serve one consumer a response generated for another. Set true only
                         for genuinely common knowledge, where no answer is specific to the caller
                         who asked for it; it raises the hit rate and accepts cross-consumer reuse.
  EOT
  type = object({
    score_threshold        = optional(number, 0.05)
    duration_seconds       = optional(number, 3600)
    max_message_count      = optional(number, 10)
    max_temperature        = optional(number, 0.3)
    share_across_consumers = optional(bool, false)
  })
  default = {}

  validation {
    condition     = var.semantic_cache_settings.score_threshold > 0 && var.semantic_cache_settings.score_threshold < 1
    error_message = "semantic_cache_settings.score_threshold must be between 0 and 1."
  }
}

# ---------------------------------------------------------------------------------------------------
# Cost attribution hand-off
# ---------------------------------------------------------------------------------------------------

variable "enable_cost_attribution" {
  description = "Emit the per-request chargeback ledger and estimated cost. The cost-attribution module supplies the pricing map and builds the reporting on top."
  type        = bool
  default     = false
}

variable "pricing_effective_date" {
  description = "Date the rate table became current, as YYYY-MM-DD, recorded in the ledger alongside every priced request so a chargeback number can be traced back to the rates that produced it. Leave null to use the newest effectiveDate carried by the pricing_map entries, which is what scripts/generate_pricing_map.py writes. Set it explicitly only when you maintain rates by hand."
  type        = string
  default     = null

  validation {
    condition     = var.pricing_effective_date == null || can(formatdate("YYYY-MM-DD", "${var.pricing_effective_date}T00:00:00Z"))
    error_message = "pricing_effective_date must be a YYYY-MM-DD date."
  }
}

variable "pricing_map" {
  description = <<-EOT
    Rates keyed by model alias, per `unit` tokens. Generate it with scripts/generate_pricing_map.py
    rather than typing rates by hand.

      { "gpt-chat": { "unit": 1000000, "input": 2.5, "cachedInput": 0.25,
                      "output": 10.0, "effectiveDate": "2026-01-01" } }

    An alias absent from this map yields an estimated cost of -1, which the workbook surfaces as
    "unpriced" instead of silently reporting zero spend.

    context tiers
    -------------
    Some models are priced by input length rather than at one flat rate. GPT-5.5 is the current
    example: above 272,000 prompt tokens its input rate doubles and its output rate rises by half.
    Express that with an optional contextTiers array, where the base entry carries the lowest band
    and each tier overrides it above a threshold:

      { "gpt-5-5": {
          "unit": 1000000,
          "input": 5.0, "cachedInput": 0.5, "output": 30.0,
          "contextTiers": [
            { "name": "long", "minPromptTokens": 272001,
              "input": 10.0, "cachedInput": 1.0, "output": 45.0 }
          ],
          "effectiveDate": "2026-10-04" } }

    Two things about this pricing are counter-intuitive and both are implemented as Azure bills them,
    not as they are often assumed:

      * The threshold is measured on TOTAL prompt tokens, cached ones included. Caching changes what
        a token costs, not whether the model had to carry it.
      * It is not marginal. Crossing the threshold reprices the WHOLE request at the higher rate -
        there is no cheap first tranche.

    Omitting contextTiers for a tiered model is not a validation error, because a flat rate is a
    reasonable approximation for a workload that never approaches the threshold. It does mean long
    requests are under-costed, so the ledger records which tier priced each request and the
    cost-attribution module can alert on it.
  EOT
  type        = any
  default     = {}

  validation {
    condition = alltrue([
      for alias, entry in var.pricing_map :
      alltrue([
        for tier in try(entry.contextTiers, []) :
        try(tier.minPromptTokens, null) != null && try(tier.input, null) != null
      ])
    ])
    error_message = "Every pricing_map contextTiers entry must set minPromptTokens and input. A tier without a threshold can never be selected, and one without its own input rate would silently price a long-context request at the base rate."
  }
}

variable "backend_auth_resource" {
  description = "Entra ID resource identifier the gateway requests a managed-identity token for. Both https://cognitiveservices.azure.com and https://ai.azure.com are accepted by Foundry."
  type        = string
  default     = "https://cognitiveservices.azure.com"
}

# ---------------------------------------------------------------------------------------------------
# Caller authentication
# ---------------------------------------------------------------------------------------------------

variable "caller_authentication" {
  description = <<-EOT
    How callers prove who they are to the gateway.

    This matters more than it first appears. The gateway's cost ledger is only as trustworthy as the
    identity it attributes spend to, and a subscription key is a bearer secret: it gets copied into a
    second app, shared across two teams, or pasted into a notebook, and from that moment the
    chargeback report is quietly wrong with nothing to indicate it. A Microsoft Entra token is bound
    to an application registration or a managed identity, cannot be meaningfully copied, and expires.

    modes
    -----
    "subscription_key" (default)
        APIM subscription key in the api-key header. No Entra validation. Attribution is by
        subscription id. This is the status quo and remains appropriate for a proof of concept.

    "both" (recommended for production)
        A subscription key AND a valid Entra token are required. The key continues to select the
        product tier - which is what drives token limits and model entitlement - while the Entra
        token establishes who the caller actually is. Attribution uses the Entra identity. This keeps
        every governance feature working and is the only mode that upgrades attribution without
        giving anything up.

    "entra_id"
        Entra token only; no subscription key. Cleanest from a secret-management point of view, but
        understand the trade-off: with no subscription there is no product, and APIM does not run
        product-scope policy for a request it cannot associate with a product. Per-product token
        limits and per-product model entitlement therefore do not apply. A single gateway-wide token
        limit is applied instead, from tokens_per_minute below. Choose this only when consumers are
        genuinely homogeneous, or when quotas are enforced somewhere else.

    fields
    ------
    tenant_id
        Entra tenant id or a well-known value ("organizations", "common"). Required unless the mode
        is subscription_key.

    audiences / client_application_ids
        At least one of these must be set for the entra modes. Validating neither would accept any
        token this tenant ever issued - including tokens minted for an entirely different API - which
        is a confused-deputy vulnerability rather than authentication. audiences is normally the
        gateway's own application ID URI; client_application_ids is the allow-list of callers.

    consumer_claim / consumer_claim_fallbacks
        Which claim identifies the consumer for attribution. "appid" is the calling application's
        client id and is the right answer for service-to-service traffic, which is what a model
        gateway almost always carries. The fallbacks are tried in order when the primary claim is
        absent: "azp" appears instead of "appid" in v2.0 tokens, and "oid"/"sub" cover managed
        identities and user-delegated calls.

    consumer_names
        Optional friendly names, keyed by claim value, so reports say "claims-assistant" rather than
        a bare GUID. Purely cosmetic; unmapped identities still attribute correctly.

    tokens_per_minute
        Gateway-wide token limit used only in entra_id mode, where product-scope limits are
        unavailable. Ignored in the other modes.
  EOT

  type = object({
    mode                       = optional(string, "subscription_key")
    tenant_id                  = optional(string)
    audiences                  = optional(list(string), [])
    client_application_ids     = optional(list(string), [])
    header_name                = optional(string, "Authorization")
    consumer_claim             = optional(string, "appid")
    consumer_claim_fallbacks   = optional(list(string), ["azp", "oid", "sub"])
    consumer_names             = optional(map(string), {})
    failed_validation_httpcode = optional(number, 401)
    tokens_per_minute          = optional(number)
    required_claims = optional(list(object({
      name      = string
      match     = optional(string, "any")
      separator = optional(string)
      values    = list(string)
    })), [])
  })

  default = {}

  validation {
    condition     = contains(["subscription_key", "entra_id", "both"], var.caller_authentication.mode)
    error_message = "caller_authentication.mode must be one of: subscription_key, entra_id, both."
  }

  validation {
    condition = (
      var.caller_authentication.mode == "subscription_key" ||
      try(trimspace(var.caller_authentication.tenant_id), "") != ""
    )
    error_message = "caller_authentication.tenant_id is required when mode is entra_id or both."
  }

  validation {
    condition = (
      var.caller_authentication.mode == "subscription_key" ||
      length(var.caller_authentication.audiences) > 0 ||
      length(var.caller_authentication.client_application_ids) > 0
    )
    error_message = join(" ", [
      "caller_authentication requires at least one of audiences or client_application_ids when mode is entra_id or both.",
      "Validating a token's signature and tenant alone accepts any token issued by that tenant, including one minted for a different API."
    ])
  }

  validation {
    condition     = try(trimspace(var.caller_authentication.consumer_claim), "") != ""
    error_message = "caller_authentication.consumer_claim must not be empty."
  }

  validation {
    condition = alltrue([
      for claim in var.caller_authentication.required_claims :
      contains(["all", "any"], claim.match) && length(claim.values) > 0
    ])
    error_message = "Each caller_authentication.required_claims entry needs match of all or any, and at least one value."
  }
}

# ---------------------------------------------------------------------------------------------------
# Audit-grade export
# ---------------------------------------------------------------------------------------------------

variable "enable_eventhub_audit" {
  description = <<-EOT
    Stream every gateway request to Event Hub in addition to Application Insights.

    Application Insights is a sampled, retention-limited telemetry store. That is the right trade-off
    for operating a gateway and the wrong one for producing an invoice somebody will dispute. Turn this
    on when chargeback numbers need to survive an audit, and land the stream in your own warehouse.

    The stream carries the same chargeback ledger the policy writes to Application Insights, one JSON
    object per request, unsampled. Requires enable_cost_attribution, since the ledger is what is sent.
  EOT
  type        = bool
  default     = false
}

variable "eventhub_partition_count" {
  description = "Partitions on the audit event hub."
  type        = number
  default     = 4
}

variable "eventhub_retention_days" {
  description = "Message retention on the audit event hub, in days. This is a buffer, not an archive: land the stream somewhere durable."
  type        = number
  default     = 7
}

variable "eventhub_sku" {
  description = "Event Hubs namespace SKU."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.eventhub_sku)
    error_message = "eventhub_sku must be Basic, Standard or Premium."
  }
}
