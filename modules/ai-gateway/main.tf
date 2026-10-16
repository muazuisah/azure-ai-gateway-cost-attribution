# ===================================================================================================
# ai-gateway
#
# The centralised entry point for an organisation's Microsoft Foundry model deployments.
#
# The module is deliberately built on first-class API Management primitives - backend pools, circuit
# breakers, managed identity, products and token limits - rather than on policy code that reimplements
# them. Native primitives keep state across requests, are visible in the portal, and are maintained by
# the platform team rather than by whoever inherits this repository.
# ===================================================================================================

locals {
  create_apim = var.existing_api_management_id == null
  is_v2_sku   = can(regex("V2_", var.apim_sku_name))

  # An API Management resource ID is /subscriptions/<sub>/resourceGroups/<rg>/providers/
  # Microsoft.ApiManagement/service/<name>, so index 4 is the resource group and index 8 the name.
  existing_apim_parts = local.create_apim ? [] : split("/", var.existing_api_management_id)

  apim_name = local.create_apim ? azurerm_api_management.this[0].name : element(local.existing_apim_parts, 8)
  apim_rg   = local.create_apim ? var.resource_group_name : element(local.existing_apim_parts, 4)
  apim_id   = local.create_apim ? azurerm_api_management.this[0].id : var.existing_api_management_id

  apim_principal_id = local.create_apim ? azurerm_api_management.this[0].identity[0].principal_id : data.azurerm_api_management.existing[0].identity[0].principal_id

  apim_gateway_url = local.create_apim ? azurerm_api_management.this[0].gateway_url : data.azurerm_api_management.existing[0].gateway_url

  # -------------------------------------------------------------------------------------------------
  # Deployment parity
  #
  # A backend pool treats its members as interchangeable. If one member is missing the deployment a
  # route points at, the failure is a 404 that appears only when load balancing happens to pick that
  # member - which is to say, intermittently, in production, at the worst possible time. Catch it at
  # plan time instead.
  # -------------------------------------------------------------------------------------------------
  parity_violations = flatten([
    for alias, route in var.model_routes : [
      for backend_key, _priority in route.backend_priority : format(
        "model route '%s' targets deployment '%s' on backend '%s', which advertises only [%s]",
        alias,
        route.deployment,
        backend_key,
        join(", ", try(var.foundry_backends[backend_key].deployments, []))
      )
      if contains(keys(var.foundry_backends), backend_key)
      && length(try(var.foundry_backends[backend_key].deployments, [])) > 0
      && !contains(try(var.foundry_backends[backend_key].deployments, []), route.deployment)
    ]
  ])

  unknown_backend_references = flatten([
    for alias, route in var.model_routes : [
      for backend_key, _priority in route.backend_priority :
      format("model route '%s' references backend '%s', which is not defined in foundry_backends", alias, backend_key)
      if !contains(keys(var.foundry_backends), backend_key)
    ]
  ])

  # -------------------------------------------------------------------------------------------------
  # Route table published to the gateway policy
  #
  # The policy needs alias -> { pool, deployment } and nothing more. Priorities and weights are the
  # pool's business, not the policy's: that separation is the whole point of moving failover out of
  # policy code.
  # -------------------------------------------------------------------------------------------------
  routes_payload = {
    for alias, route in var.model_routes : alias => {
      pool        = "pool-${alias}"
      deployment  = route.deployment
      description = coalesce(route.description, "")
    }
  }

  # Base64 rather than raw JSON. A named value is substituted verbatim into the surrounding C# string
  # literal in the policy expression, so raw JSON would terminate that literal on its first quote.
  routes_named_value_name  = "${var.name_prefix}-model-routes"
  pricing_named_value_name = "${var.name_prefix}-model-pricing"
  environment_named_value  = "${var.name_prefix}-environment"
  audit_logger_name        = "${var.name_prefix}-ai-audit-logger"

  # The map's effective date has to be derived from the rates themselves, never from the clock. Stamping
  # it with timestamp() makes the named value differ on every single plan, which forces the choice
  # between permanent plan noise and ignoring changes to the value altogether - and ignoring them means
  # a freshly regenerated rate table produces no diff and silently never reaches the gateway.
  pricing_entry_dates = compact([
    for alias, rates in var.pricing_map : try(tostring(rates.effectiveDate), "")
  ])

  pricing_effective_date = coalesce(
    var.pricing_effective_date,
    length(local.pricing_entry_dates) > 0 ? reverse(sort(local.pricing_entry_dates))[0] : null,
    "unknown"
  )

  # The gateway prices requests; it does not audit where a rate came from. "source" exists so that a
  # human reading the generated tfvars can see which retail meter produced each number, and it is a
  # third of each entry. An API Management named value caps at 4096 characters, so shipping provenance
  # spends a genuinely scarce resource on data the policy never reads.
  pricing_rates = {
    for alias, rates in var.pricing_map : alias => {
      for key, value in rates : key => value if key != "source"
    }
  }

  pricing_payload = merge(
    { "_meta" = { effectiveDate = local.pricing_effective_date } },
    local.pricing_rates
  )

  pricing_named_value_length = length(base64encode(jsonencode(local.pricing_payload)))

  # -------------------------------------------------------------------------------------------------
  # Operations. Chat completions and embeddings are always published; the Responses API is opt-in
  # because not every model family supports it and an advertised-but-broken operation is worse than an
  # absent one.
  # -------------------------------------------------------------------------------------------------
  operations = merge(
    {
      "create-chat-completion" = {
        display_name = "Create chat completion"
        method       = "POST"
        url_template = "/chat/completions"
        description  = "OpenAI-compatible chat completion. Send the gateway model alias in the 'model' field."
      }
      "create-embedding" = {
        display_name = "Create embedding"
        method       = "POST"
        url_template = "/embeddings"
        description  = "OpenAI-compatible embeddings. Send the gateway model alias in the 'model' field."
      }
      "list-models" = {
        display_name = "List models"
        method       = "GET"
        url_template = "/models"
        description  = "Returns the gateway's model catalogue. Answered by the gateway; no backend call is made."
      }
    },
    var.enable_responses_api ? {
      "create-response" = {
        display_name = "Create response"
        method       = "POST"
        url_template = "/responses"
        description  = "OpenAI Responses API. Send the gateway model alias in the 'model' field."
      }
    } : {}
  )

  semantic_cache_backend_key = coalesce(var.semantic_cache_embeddings_backend, element(sort(keys(var.foundry_backends)), 0))

  # -------------------------------------------------------------------------------------------------
  # Caller authentication
  #
  # These two flags are independent on purpose. "both" turns Entra validation on while leaving the
  # subscription requirement in place, which is what keeps product-scope policy - and therefore
  # per-product token limits and model entitlement - working. "entra_id" drops the subscription, and
  # with it the product, which is a real capability loss rather than a cosmetic one.
  # -------------------------------------------------------------------------------------------------
  entra_enabled         = var.caller_authentication.mode != "subscription_key"
  subscription_required = var.caller_authentication.mode != "entra_id"

  # Primary claim first, then fallbacks, de-duplicated so a caller who lists "appid" in both places
  # does not produce a redundant loop iteration in the policy.
  entra_claim_order = distinct(concat(
    [var.caller_authentication.consumer_claim],
    var.caller_authentication.consumer_claim_fallbacks
  ))

  # The gateway-wide limit only applies where product-scope policy cannot run.
  entra_gateway_token_limit = (
    var.caller_authentication.mode == "entra_id" ? var.caller_authentication.tokens_per_minute : null
  )

  # Products that gate models or tokens are inert in entra_id mode. Surfaced as a guard rather than
  # silently ignored, because a quota you believe is enforced and is not is worse than no quota.
  inert_product_controls = var.caller_authentication.mode != "entra_id" ? [] : [
    for key, product in var.products :
    format("product '%s'", key)
    if length(product.allowed_models) > 0 || try(product.tokens_per_minute, null) != null
  ]

  default_tags = merge(var.tags, {
    "module"      = "ai-gateway"
    "environment" = var.environment_name
  })
}

data "azurerm_api_management" "existing" {
  count               = local.create_apim ? 0 : 1
  name                = element(local.existing_apim_parts, 8)
  resource_group_name = element(local.existing_apim_parts, 4)
}

# ---------------------------------------------------------------------------------------------------
# Plan-time guards
#
# terraform_data carries no cloud footprint; it exists purely to host preconditions that variable
# validation cannot express because they span more than one variable.
# ---------------------------------------------------------------------------------------------------
resource "terraform_data" "guards" {
  input = {
    routes    = keys(var.model_routes)
    backends  = keys(var.foundry_backends)
    parity_on = var.enforce_deployment_parity
  }

  lifecycle {
    precondition {
      condition     = length(local.unknown_backend_references) == 0
      error_message = "model_routes references backends that do not exist:\n  ${join("\n  ", local.unknown_backend_references)}"
    }

    precondition {
      condition     = !var.enforce_deployment_parity || length(local.parity_violations) == 0
      error_message = "Deployment parity check failed. Every backend in a route's pool must host that route's deployment:\n  ${join("\n  ", local.parity_violations)}\nDeploy the missing deployments, drop the backend from the route, or set enforce_deployment_parity = false if you accept intermittent 404s."
    }

    precondition {
      condition     = !local.create_apim || var.publisher_email != null
      error_message = "publisher_email is required when the module creates the API Management instance."
    }

    precondition {
      condition     = !var.enable_content_safety || var.content_safety_endpoint != null
      error_message = "content_safety_endpoint is required when enable_content_safety is true."
    }

    precondition {
      condition     = !var.enable_semantic_cache || var.semantic_cache_redis_connection_string != null
      error_message = "semantic_cache_redis_connection_string is required when enable_semantic_cache is true."
    }

    precondition {
      condition     = !var.enable_eventhub_audit || var.enable_cost_attribution
      error_message = "enable_eventhub_audit requires enable_cost_attribution. The audit stream carries the chargeback ledger, and without cost attribution there is no ledger to carry."
    }

    precondition {
      condition     = var.semantic_cache_embeddings_backend == null || contains(keys(var.foundry_backends), coalesce(var.semantic_cache_embeddings_backend, "__unset__"))
      error_message = "semantic_cache_embeddings_backend must name a key from foundry_backends. Known keys: ${join(", ", sort(keys(var.foundry_backends)))}."
    }

    precondition {
      condition = alltrue([
        for name, sub in var.subscriptions : contains(keys(var.products), sub.product_key)
      ])
      error_message = "Every subscription must reference a product key defined in var.products."
    }

    precondition {
      condition = alltrue(flatten([
        for key, product in var.products : [
          for alias in product.allowed_models : contains(keys(var.model_routes), alias)
        ]
      ]))
      error_message = "A product's allowed_models may only list aliases that exist in model_routes."
    }

    # ---------------------------------------------------------------------------------------------
    # Caller authentication
    # ---------------------------------------------------------------------------------------------
    precondition {
      condition     = length(local.inert_product_controls) == 0
      error_message = "caller_authentication.mode is \"entra_id\", so requests carry no subscription key. APIM cannot resolve a product without one, and does not execute product-scope policy, so these controls would never be enforced: ${join(", ", local.inert_product_controls)}. Use mode = \"both\" to keep per-product entitlement and token limits, or clear allowed_models and tokens_per_minute on those products and rely on caller_authentication.tokens_per_minute."
    }

    precondition {
      condition = (
        var.caller_authentication.mode != "entra_id" ||
        var.caller_authentication.tokens_per_minute != null
      )
      error_message = "caller_authentication.tokens_per_minute is required when mode is \"entra_id\". Product-scope token limits do not run in that mode, so without it the gateway has no rate ceiling at all and a single client can consume the entire quota."
    }

    precondition {
      condition     = !var.enable_cost_attribution || length(var.pricing_map) > 0
      error_message = "enable_cost_attribution is true but pricing_map is empty; every request would be reported as unpriced. Generate a map with scripts/generate_pricing_map.py."
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# API Management
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management" "this" {
  count = local.create_apim ? 1 : 0

  # checkov:skip=CKV_AZURE_174:Driven by the public_network_access_enabled input rather than fixed here.
  # A gateway whose whole purpose is to be the organisation's entry point is frequently and legitimately
  # internet-facing, protected by Entra ID, WAF and rate limiting rather than by network reachability.
  # The production example disables it; the quickstart does not, so the example can actually be called.

  name                = "${var.name_prefix}-apim"
  location            = var.location
  resource_group_name = var.resource_group_name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.apim_sku_name
  tags                = local.default_tags

  public_network_access_enabled = var.public_network_access_enabled

  virtual_network_type = var.virtual_network_type

  dynamic "virtual_network_configuration" {
    for_each = var.virtual_network_type == "None" ? [] : [1]
    content {
      subnet_id = var.virtual_network_subnet_id
    }
  }

  dynamic "security" {
    for_each = var.disable_legacy_tls && !local.is_v2_sku ? [1] : []
    content {
      backend_ssl30_enabled      = false
      backend_tls10_enabled      = false
      backend_tls11_enabled      = false
      frontend_ssl30_enabled     = false
      frontend_tls10_enabled     = false
      frontend_tls11_enabled     = false
      triple_des_ciphers_enabled = false
    }
  }

  # A system-assigned identity is what makes keyless access to Foundry possible. Nothing in this
  # accelerator stores a Foundry API key, because a key that is never issued cannot be leaked.
  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    precondition {
      condition     = var.virtual_network_type == "None" || var.virtual_network_subnet_id != null
      error_message = "virtual_network_subnet_id is required when virtual_network_type is not None."
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Named values
#
# Route and pricing tables live in named values so that adding a model or repricing a token is a data
# change, not a policy rewrite. The policy document itself is stable across environments.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_named_value" "routes" {
  name                = local.routes_named_value_name
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  display_name        = local.routes_named_value_name
  value               = base64encode(jsonencode(local.routes_payload))
  tags                = ["ai-gateway", "routing"]
}

resource "azurerm_api_management_named_value" "pricing" {
  count = var.enable_cost_attribution ? 1 : 0

  name                = local.pricing_named_value_name
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  display_name        = local.pricing_named_value_name
  value               = base64encode(jsonencode(local.pricing_payload))
  tags                = ["ai-gateway", "cost"]

  lifecycle {
    precondition {
      # Azure caps a named value at 4096 characters and rejects anything longer with an error that
      # names neither the limit nor the resource. Catching it at plan time turns a confusing failure
      # part-way through an apply into a sentence that says what to do about it.
      condition     = local.pricing_named_value_length <= 4096
      error_message = "The pricing map encodes to ${local.pricing_named_value_length} characters and API Management caps a named value at 4096. Price fewer aliases on this gateway, or drop the models nobody routes to - scripts/generate_pricing_map.py emits only the aliases you ask it for."
    }
  }
}

resource "azurerm_api_management_named_value" "environment" {
  name                = local.environment_named_value
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  display_name        = local.environment_named_value
  value               = var.environment_name
  tags                = ["ai-gateway"]
}

# ---------------------------------------------------------------------------------------------------
# Backends
#
# One backend per Foundry endpoint, each with a circuit breaker. accept_retry_after is the important
# setting: a throttled Foundry deployment can return a Retry-After measured in hours, and honouring it
# is what stops the gateway from queueing behind a backend that has already said no.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_backend" "foundry" {
  for_each = var.foundry_backends

  # checkov:skip=CKV_AZURE_215:This "protocol" field selects the backend *type* - APIM accepts only
  # "http" or "soap" here - and says nothing about TLS. Transport security is determined by the URL
  # scheme, and foundry_backends validates that every inference_url matches ^https://. Setting this to
  # "https" would simply be rejected by the provider.

  name                = "foundry-${each.key}"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  protocol            = "http"
  url                 = "${each.value.inference_url}/openai/v1"
  description         = coalesce(each.value.description, "Microsoft Foundry endpoint ${each.key}")

  dynamic "circuit_breaker_rule" {
    for_each = var.circuit_breaker.enabled ? [var.circuit_breaker] : []
    content {
      name                       = circuit_breaker_rule.value.name
      trip_duration              = circuit_breaker_rule.value.trip_duration
      accept_retry_after_enabled = circuit_breaker_rule.value.accept_retry_after
      failure_condition {
        count             = circuit_breaker_rule.value.failure_count
        interval_duration = circuit_breaker_rule.value.interval
        status_code_range {
          min = circuit_breaker_rule.value.status_code_min
          max = circuit_breaker_rule.value.status_code_max
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Embeddings backend for semantic cache lookups
#
# The semantic cache policy vectorises each prompt before it can compare it to anything, and it does
# that by calling an embeddings deployment through a backend of its own. That backend cannot be one of
# the pool members above: those are registered at the /openai/v1 inference root, whereas the cache
# policy needs a URL that already resolves to a specific embedding deployment. Pointing the policy at a
# pool member instead is the quiet failure mode here - every lookup errors and the cache simply never
# returns a hit, which looks identical to a cache that is merely cold.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_backend" "embeddings" {
  count = var.enable_semantic_cache ? 1 : 0

  # checkov:skip=CKV_AZURE_215:As above, "protocol" selects http vs soap and is unrelated to TLS.

  name                = "foundry-embeddings"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  protocol            = "http"
  url                 = "${var.foundry_backends[local.semantic_cache_backend_key].inference_url}/openai/deployments/${var.semantic_cache_embeddings_deployment}/embeddings"
  description         = "Embedding deployment ${var.semantic_cache_embeddings_deployment} on ${local.semantic_cache_backend_key}, used only for semantic cache vectorisation."
}

# ---------------------------------------------------------------------------------------------------
# Backend pools
#
# The provider does not model pools yet, so they are created through the Azure API directly. This is
# the single most valuable thing in the module: priority groups give automatic spillover from reserved
# to pay-as-you-go capacity, and weights spread load inside a group, with none of it written in policy.
# A lower-priority group is only reached once every backend in every higher group has a tripped breaker.
# ---------------------------------------------------------------------------------------------------
resource "azapi_resource" "model_pool" {
  for_each = var.model_routes

  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "pool-${each.key}"
  parent_id = local.apim_id

  body = {
    properties = {
      title       = "Pool for ${each.key}"
      description = coalesce(each.value.description, "Backend pool serving the ${each.key} alias")
      type        = "Pool"
      pool = {
        services = [
          for backend_key, priority in each.value.backend_priority : {
            id       = azurerm_api_management_backend.foundry[backend_key].id
            priority = priority
            weight   = try(each.value.backend_weight[backend_key], 1)
          }
        ]
      }
    }
  }

  schema_validation_enabled = false

  depends_on = [azurerm_api_management_backend.foundry]
}

# ---------------------------------------------------------------------------------------------------
# Content safety backend (optional)
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_backend" "content_safety" {
  count = var.enable_content_safety ? 1 : 0

  # checkov:skip=CKV_AZURE_215:As above, "protocol" selects http vs soap and is unrelated to TLS.
  # content_safety_endpoint is validated to be https.

  name                = "content-safety"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  protocol            = "http"
  url                 = var.content_safety_endpoint
  description         = "Azure AI Content Safety endpoint used by llm-content-safety."
}

# ---------------------------------------------------------------------------------------------------
# Semantic cache (optional)
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_redis_cache" "semantic" {
  count = var.enable_semantic_cache ? 1 : 0

  name              = "${var.name_prefix}-semantic-cache"
  api_management_id = local.apim_id
  connection_string = var.semantic_cache_redis_connection_string
  description       = "RediSearch-compatible cache backing llm-semantic-cache-lookup."
  cache_location    = var.location
}

# ---------------------------------------------------------------------------------------------------
# The API
#
# Path defaults to openai/v1 so that an OpenAI client pointed at
# https://<gateway>/openai/v1 works unchanged. The Azure OpenAI v1 API is generally available and needs
# no api-version parameter, which removes an entire class of version-skew bugs from the gateway.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_api" "llm" {
  name                = "${var.name_prefix}-llm"
  resource_group_name = local.apim_rg
  api_management_name = local.apim_name
  revision            = "1"
  display_name        = "AI Gateway (${var.environment_name})"
  description         = "Centralised OpenAI-compatible entry point for Microsoft Foundry model deployments."
  path                = var.api_path
  protocols           = ["https"]

  # False only in entra_id mode, where the Entra token is the sole credential. In "both" mode the key
  # is still required: it is what lets APIM resolve the product, and the product is what carries token
  # limits and model entitlement.
  subscription_required = local.subscription_required

  # api-key matches what Azure OpenAI clients already send. Callers using the plain OpenAI SDK pass it
  # with default_headers={"api-key": "<subscription key>"}.
  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }
}

resource "azurerm_api_management_api_operation" "llm" {
  for_each = local.operations

  operation_id        = each.key
  api_name            = azurerm_api_management_api.llm.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  display_name        = each.value.display_name
  method              = each.value.method
  url_template        = each.value.url_template
  description         = each.value.description

  response {
    status_code = 200
  }
}

# ---------------------------------------------------------------------------------------------------
# Gateway policy
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_api_policy" "llm" {
  api_name            = azurerm_api_management_api.llm.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg

  xml_content = templatefile("${path.module}/policies/llm-api.xml.tftpl", {
    environment_name        = var.environment_name
    environment_named_value = local.environment_named_value
    routes_named_value      = local.routes_named_value_name
    pricing_named_value     = local.pricing_named_value_name
    metric_namespace        = var.metric_namespace

    backend_auth_resource   = var.backend_auth_resource
    forward_timeout_seconds = var.forward_timeout_seconds
    buffer_response         = var.buffer_response

    enable_cost_attribution = var.enable_cost_attribution

    enable_content_safety              = var.enable_content_safety
    content_safety_backend_id          = var.enable_content_safety ? azurerm_api_management_backend.content_safety[0].name : ""
    content_safety_shield_prompt       = var.content_safety_shield_prompt
    content_safety_max_characters      = var.content_safety_max_characters
    content_safety_threshold_hate      = var.content_safety_thresholds.hate
    content_safety_threshold_self_harm = var.content_safety_thresholds.self_harm
    content_safety_threshold_sexual    = var.content_safety_thresholds.sexual
    content_safety_threshold_violence  = var.content_safety_thresholds.violence

    enable_semantic_cache                = var.enable_semantic_cache
    semantic_cache_max_temperature       = var.semantic_cache_settings.max_temperature
    semantic_cache_score_threshold       = var.semantic_cache_settings.score_threshold
    semantic_cache_max_message_count     = var.semantic_cache_settings.max_message_count
    semantic_cache_duration_seconds      = var.semantic_cache_settings.duration_seconds
    semantic_cache_embeddings_backend_id = var.enable_semantic_cache ? azurerm_api_management_backend.embeddings[0].name : ""

    semantic_cache_share_across_consumers = var.semantic_cache_settings.share_across_consumers
    enable_eventhub_audit                 = var.enable_eventhub_audit
    audit_logger_name                     = local.audit_logger_name

    entra_enabled                = local.entra_enabled
    entra_tenant_id              = coalesce(var.caller_authentication.tenant_id, "organizations")
    entra_header_name            = var.caller_authentication.header_name
    entra_failed_httpcode        = var.caller_authentication.failed_validation_httpcode
    entra_audiences              = var.caller_authentication.audiences
    entra_client_application_ids = var.caller_authentication.client_application_ids
    entra_required_claims        = var.caller_authentication.required_claims
    entra_claim_order            = local.entra_claim_order
    entra_consumer_names         = var.caller_authentication.consumer_names
    entra_gateway_token_limit    = local.entra_gateway_token_limit
  })

  depends_on = [
    azurerm_api_management_api_operation.llm,
    azurerm_api_management_named_value.routes,
    azurerm_api_management_named_value.environment,
    azurerm_api_management_named_value.pricing,
    azapi_resource.model_pool,
  ]
}

# ---------------------------------------------------------------------------------------------------
# Products, entitlements and token governance
#
# The product is the governance boundary. Rate limits and quotas are attached here rather than to the
# API, so a noisy experiment cannot starve a production workload and each tier's ceiling is visible as
# configuration rather than buried in a policy document.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_product" "this" {
  for_each = var.products

  product_id          = each.key
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  display_name        = coalesce(each.value.display_name, title(replace(each.key, "-", " ")))
  description         = each.value.description

  subscription_required = each.value.subscription_required
  approval_required     = each.value.subscription_required ? each.value.approval_required : null
  subscriptions_limit   = each.value.subscription_required ? each.value.subscriptions_limit : null
  published             = each.value.published
}

resource "azurerm_api_management_product_api" "this" {
  for_each = var.products

  product_id          = azurerm_api_management_product.this[each.key].product_id
  api_name            = azurerm_api_management_api.llm.name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
}

resource "azurerm_api_management_product_policy" "this" {
  for_each = var.products

  product_id          = azurerm_api_management_product.this[each.key].product_id
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg

  xml_content = templatefile("${path.module}/policies/product.xml.tftpl", {
    product_key            = each.key
    allowed_models         = each.value.allowed_models
    tokens_per_minute      = each.value.tokens_per_minute
    token_quota            = each.value.token_quota
    token_quota_period     = each.value.token_quota_period
    estimate_prompt_tokens = each.value.estimate_prompt_tokens
  })

  depends_on = [azurerm_api_management_product_api.this]
}

resource "azurerm_api_management_subscription" "this" {
  for_each = var.subscriptions

  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  product_id          = azurerm_api_management_product.this[each.value.product_key].id

  # Pinning the subscription id to the map key is what makes chargeback joinable. The policy stamps
  # context.Subscription.Id onto every ledger record, and left unset APIM generates a GUID - so the
  # chargeback register would have to be keyed by an opaque identifier that only exists after an apply,
  # and a human-readable register would silently join to nothing and report every consumer as
  # "unassigned". With this set, the key you write in var.subscriptions is the key you charge.
  subscription_id = each.key

  display_name  = coalesce(each.value.display_name, each.key)
  state         = each.value.state
  allow_tracing = false
}

# ---------------------------------------------------------------------------------------------------
# Diagnostics
#
# The single most consequential setting in this module. The trace policy that writes the chargeback
# ledger only emits when the API diagnostic verbosity is verbose, and what it emits is then subject to
# the logger's sampling percentage. A gateway left on the 5% default silently reports about a twentieth
# of its real usage - and looks perfectly healthy while doing it. Sampling is pinned to 100 on this API
# alone, so the cost of full fidelity is paid only where the ledger is produced.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_api_management_logger" "appinsights" {
  name                = "${var.name_prefix}-ai-logger"
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  resource_id         = var.application_insights_id

  application_insights {
    instrumentation_key = var.application_insights_instrumentation_key
  }
}

resource "azurerm_api_management_api_diagnostic" "llm" {
  identifier               = "applicationinsights"
  resource_group_name      = local.apim_rg
  api_management_name      = local.apim_name
  api_name                 = azurerm_api_management_api.llm.name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage       = var.diagnostic_sampling_percentage
  always_log_errors         = true
  log_client_ip             = true
  verbosity                 = "verbose"
  http_correlation_protocol = "W3C"

  frontend_request {
    body_bytes     = var.log_request_and_response_bodies ? 8192 : 0
    headers_to_log = ["x-ms-client-request-id", "x-request-id"]
  }

  frontend_response {
    body_bytes     = var.log_request_and_response_bodies ? 8192 : 0
    headers_to_log = ["x-ms-region", "x-gateway-model", "x-gateway-backend"]
  }

  backend_request {
    body_bytes     = var.log_request_and_response_bodies ? 8192 : 0
    headers_to_log = ["x-ms-client-request-id"]
  }

  backend_response {
    body_bytes     = var.log_request_and_response_bodies ? 8192 : 0
    headers_to_log = ["x-ms-region", "retry-after", "x-ratelimit-remaining-tokens"]
  }
}

# ---------------------------------------------------------------------------------------------------
# Keyless access to Foundry
#
# The gateway's managed identity is granted Cognitive Services User on each Foundry account. Combined
# with local_auth_enabled = false on those accounts, this removes Foundry keys from existence rather
# than merely from source control.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_role_assignment" "gateway_to_foundry" {
  for_each = var.foundry_account_ids

  scope                            = each.value
  role_definition_name             = "Cognitive Services User"
  principal_id                     = local.apim_principal_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------------------------------
# Diagnostics
#
# GatewayLogs is the per-request record: which operation, which backend, which subscription, the
# response code and the latency. The token metrics the policy emits are aggregates and cannot answer
# "what happened to that one request at 14:07" - this can, and it is the log the cost-attribution
# telemetry_gap alert is implicitly reasoning about.
# ---------------------------------------------------------------------------------------------------
#
# The count keys off a dedicated flag rather than `log_analytics_workspace_id != null`, because the
# workspace is usually created by the same root module that calls this one. Its id is then unknown at
# plan time, and Terraform cannot decide how many instances a count produces from an unknown value -
# it refuses to plan at all. A bool the caller sets literally is always known, so the graph stays
# plannable in one pass no matter where the workspace comes from.
resource "azurerm_monitor_diagnostic_setting" "apim" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag-to-law"
  target_resource_id         = local.apim_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "GatewayLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  lifecycle {
    precondition {
      condition     = var.log_analytics_workspace_id != null
      error_message = "enable_diagnostics is true but log_analytics_workspace_id is null. Set the workspace id, or set enable_diagnostics = false."
    }
  }
}
# ---------------------------------------------------------------------------------------------------
# Audit-grade export (optional)
#
# Application Insights is sampled and retention-limited by design. That is correct for operating a
# gateway and wrong for producing a number somebody will dispute. When chargeback has to be defensible,
# this streams every request out unsampled.
#
# These resources live here, beside the API policy, rather than with the rest of the cost-attribution
# reporting. The policy is the only thing that writes to the hub, and a policy may not reference a
# logger that does not yet exist - so the logger has to be created by the same module, in the same
# dependency graph, as the policy that names it. The cost-attribution module already depends on this
# one for the gateway's name and identity, which makes the reverse ordering impossible to express.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_eventhub_namespace" "audit" {
  count = var.enable_eventhub_audit ? 1 : 0

  name                = "${var.name_prefix}-ai-audit-ehns"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.eventhub_sku
  capacity            = 1
  tags                = var.tags

  local_authentication_enabled  = false
  public_network_access_enabled = true
  minimum_tls_version           = "1.2"
}

resource "azurerm_eventhub" "audit" {
  count = var.enable_eventhub_audit ? 1 : 0

  name              = "ai-gateway-ledger"
  namespace_id      = azurerm_eventhub_namespace.audit[0].id
  partition_count   = var.eventhub_partition_count
  message_retention = var.eventhub_retention_days
}

resource "azurerm_api_management_logger" "eventhub" {
  count = var.enable_eventhub_audit ? 1 : 0

  name                = local.audit_logger_name
  api_management_name = local.apim_name
  resource_group_name = local.apim_rg
  description         = "Unsampled chargeback ledger stream for audit-grade cost attribution."

  # endpoint_uri without a connection string selects identity-based auth against the namespace, which
  # is the only option that works here: local_authentication_enabled is false on the namespace above.
  eventhub {
    name         = azurerm_eventhub.audit[0].name
    endpoint_uri = "sb://${azurerm_eventhub_namespace.audit[0].name}.servicebus.windows.net"
  }
}

# The gateway's managed identity writes to the hub. Local authentication is disabled on the namespace,
# so there is no connection string to rotate, leak or check into a repository.
resource "azurerm_role_assignment" "gateway_to_eventhub" {
  count = var.enable_eventhub_audit ? 1 : 0

  scope                            = azurerm_eventhub_namespace.audit[0].id
  role_definition_name             = "Azure Event Hubs Data Sender"
  principal_id                     = local.apim_principal_id
  skip_service_principal_aad_check = true
}
