# ===================================================================================================
# Example 02 - production, private, multi-region
#
# The topology to actually run: Foundry reachable only over private endpoints, two regions behind a
# priority-ordered backend pool, content safety in line, and full-fidelity chargeback telemetry.
#
# The interesting part is the routing. The "chat" alias lists the primary region at priority 1 and the
# secondary at priority 2. Traffic stays in the primary until every backend in that group has a tripped
# circuit breaker, at which point it spills into the secondary on its own. No policy code, no retry
# loop, no request paying the cost of discovering that a backend is down - the breaker is stateful
# across requests, so the first failure is what takes the backend out, not every subsequent caller.
#
# Swap the priorities for reserved capacity: put a provisioned deployment at priority 1 and a
# pay-as-you-go one at priority 2 and you get spillover billing for free.
# ===================================================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 5.0.0, < 6.0.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0.0, < 3.0.0"
    }
  }
}

provider "azurerm" {
  features {
    cognitive_account {
      purge_soft_delete_on_destroy = false
    }
  }
  resource_provider_registrations = "none"
}

provider "azapi" {}

locals {
  name_prefix = "${var.name_prefix}-${var.environment_name}"

  tags = merge(var.tags, {
    environment = var.environment_name
    workload    = "ai-gateway"
    managed_by  = "terraform"
    example     = "02-production-private"
    data_class  = "confidential"
  })
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.primary_location
  tags     = local.tags
}

# ---------------------------------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------------------------------
module "network" {
  source = "../../modules/networking"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.primary_location
  name_prefix         = local.name_prefix
  tags                = local.tags

  address_space                          = [var.address_space]
  apim_subnet_address_prefix             = var.apim_subnet_address_prefix
  private_endpoint_subnet_address_prefix = var.private_endpoint_subnet_address_prefix

  apim_sku_name             = var.apim_sku_name
  apim_virtual_network_type = var.apim_virtual_network_type

  # Bring your own, piece by piece. Anything left blank is created here; anything with a resource ID
  # in it is used as it stands. In a hub-and-spoke estate the private DNS zones are almost always
  # owned centrally - name them here, because a duplicate zone in a spoke breaks resolution
  # estate-wide.
  existing_virtual_network_id         = var.existing_virtual_network_id
  existing_apim_subnet_id             = var.existing_apim_subnet_id
  existing_private_endpoint_subnet_id = var.existing_private_endpoint_subnet_id
  existing_apim_nsg_id                = var.existing_apim_nsg_id
  existing_private_endpoint_nsg_id    = var.existing_private_endpoint_nsg_id

  create_private_dns_zones        = var.create_private_dns_zones
  existing_private_dns_zone_ids   = var.existing_private_dns_zone_ids
  link_existing_private_dns_zones = var.link_existing_private_dns_zones
  require_private_dns_coverage    = var.require_private_dns_coverage

  enable_nat_gateway = var.enable_nat_gateway
}

module "observability" {
  source = "../../modules/observability"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.primary_location
  name_prefix         = local.name_prefix
  tags                = local.tags

  log_retention_days = var.log_retention_days
  daily_quota_gb     = var.log_analytics_daily_quota_gb

  log_analytics_workspace_id = var.existing_log_analytics_workspace_id
  application_insights_id    = var.existing_application_insights_id
}

# ---------------------------------------------------------------------------------------------------
# Foundry
#
# Two accounts, identical deployment names. That parity is not a convenience: a backend pool treats its
# members as interchangeable, so a deployment missing from one region turns into a 404 that appears
# only when load balancing happens to choose it. The gateway module checks this at plan time.
# ---------------------------------------------------------------------------------------------------
module "foundry" {
  source = "../../modules/foundry-models"

  resource_group_name = azurerm_resource_group.this.name
  name_prefix         = local.name_prefix
  tags                = local.tags

  accounts = {
    primary = {
      location                      = var.primary_location
      public_network_access_enabled = false
    }
    secondary = {
      location                      = var.secondary_location
      public_network_access_enabled = false
    }
  }

  model_deployments = {
    "gpt-4.1" = {
      model_name    = "gpt-4.1"
      model_version = "2025-04-14"
      sku_name      = "GlobalStandard"
      capacity      = var.chat_capacity
    }
    "gpt-4.1-mini" = {
      model_name    = "gpt-4.1-mini"
      model_version = "2025-04-14"
      sku_name      = "GlobalStandard"
      capacity      = var.chat_mini_capacity
    }
    "text-embedding-3-large" = {
      model_name    = "text-embedding-3-large"
      model_version = "1"
      sku_name      = "GlobalStandard"
      capacity      = var.embedding_capacity
    }
  }

  local_auth_enabled = false

  private_endpoint_subnet_id = module.network.private_endpoint_subnet_id
  enable_private_endpoints   = true

  # The network is single-region by design, so both endpoints land in the primary region even though
  # the secondary account is elsewhere. A private endpoint belongs to the region of its subnet.
  private_endpoint_location = var.primary_location
  private_dns_zone_ids      = module.network.private_dns_zone_ids_list
  diagnostics_workspace_id  = module.observability.log_analytics_workspace_id
  enable_diagnostics        = true

  gateway_principal_ids = []
}

# ---------------------------------------------------------------------------------------------------
# Gateway
# ---------------------------------------------------------------------------------------------------
module "ai_gateway" {
  source = "../../modules/ai-gateway"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.primary_location
  name_prefix         = local.name_prefix
  environment_name    = var.environment_name
  tags                = local.tags

  apim_sku_name   = var.apim_sku_name
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email

  virtual_network_type      = var.apim_virtual_network_type
  virtual_network_subnet_id = module.network.apim_subnet_id

  foundry_backends    = module.foundry.accounts
  foundry_account_ids = module.foundry.account_ids

  model_routes = {
    "chat" = {
      deployment  = "gpt-4.1"
      description = "Frontier chat model. Primary region first, secondary on breaker trip."
      backend_priority = {
        primary   = 1
        secondary = 2
      }
    }
    "chat-fast" = {
      deployment  = "gpt-4.1-mini"
      description = "Lower-latency, lower-cost chat. Both regions active and load balanced."
      backend_priority = {
        primary   = 1
        secondary = 1
      }
      backend_weight = {
        primary   = 70
        secondary = 30
      }
    }
    "embed" = {
      deployment  = "text-embedding-3-large"
      description = "High-dimension embeddings for retrieval."
      backend_priority = {
        primary   = 1
        secondary = 2
      }
    }
  }

  circuit_breaker = {
    enabled       = true
    failure_count = 5
    interval      = "PT1M"
    trip_duration = "PT1M"

    # Foundry answers a throttle with a Retry-After that can run to hours. Honouring it is what stops
    # the gateway from queueing behind a backend that has already said no.
    accept_retry_after = true
    status_code_min    = 429
    status_code_max    = 599
  }

  products = {
    "internal-apps" = {
      display_name       = "Internal applications"
      description        = "Line-of-business applications with a named owner and a funded cost centre."
      tokens_per_minute  = 200000
      token_quota        = 500000000
      token_quota_period = "Monthly"
    }
    "agents" = {
      display_name       = "Autonomous agents"
      description        = "Agent workloads. Capped harder than everything else, because an agent loop is the single most effective way to spend a month's budget in an afternoon."
      tokens_per_minute  = 50000
      token_quota        = 50000000
      token_quota_period = "Monthly"
      allowed_models     = ["chat-fast", "embed"]
    }
    "evaluation" = {
      display_name       = "Evaluation"
      description        = "Model evaluation and benchmarking runs."
      tokens_per_minute  = 30000
      token_quota        = 20000000
      token_quota_period = "Monthly"
    }
  }

  subscriptions = var.subscriptions

  # Caller authentication.
  #
  # "both" rather than "entra_id" on purpose. The subscription key is what lets APIM resolve the
  # product, and the product is what carries the token limits and the allowed_models entitlement
  # declared above. Dropping the key would silently disarm all of it. The Entra token is what the
  # chargeback ledger attributes spend to, because an app registration cannot be copied into a second
  # service the way a key can - which is the difference between a cost report you can defend and one
  # you can only hope is right.
  caller_authentication = {
    # Degrades to subscription keys when no tenant is supplied, so the example still applies
    # end-to-end for someone evaluating it before they have an app registration to point at.
    mode                   = var.caller_tenant_id == null ? "subscription_key" : "both"
    tenant_id              = var.caller_tenant_id
    audiences              = var.caller_audiences
    client_application_ids = var.caller_client_application_ids
    consumer_names         = var.caller_consumer_names
  }

  # Content safety runs in line, against the multi-service Foundry endpoint that already exists. Prompt
  # shields catch jailbreak attempts on the way in; the category thresholds apply in both directions.
  enable_content_safety        = true
  content_safety_endpoint      = module.foundry.endpoints["primary"]
  content_safety_shield_prompt = true
  content_safety_thresholds = {
    hate      = var.content_safety_threshold
    self_harm = var.content_safety_threshold
    sexual    = var.content_safety_threshold
    violence  = var.content_safety_threshold
  }

  application_insights_id                  = module.observability.application_insights_id
  application_insights_instrumentation_key = module.observability.application_insights_instrumentation_key
  log_analytics_workspace_id               = module.observability.log_analytics_workspace_id
  enable_diagnostics                       = true

  # Full fidelity on this API only. Anything less and the chargeback ledger silently undercounts, since
  # the trace policy is subject to the same sampling percentage as everything else on the diagnostic.
  diagnostic_sampling_percentage = 100

  # Deliberately off. Request and response bodies are prompts: they carry whatever the user typed, and
  # a telemetry store is the wrong place for it. Turn it on only for a bounded debugging window, and
  # only after someone has agreed to the data-protection consequences.
  log_request_and_response_bodies = false

  enable_cost_attribution = true
  pricing_map             = var.pricing_map

  # The unsampled copy of the ledger. This lives on the gateway module rather than the reporting module
  # because the API policy is what writes to the hub, and a policy cannot name a logger that does not
  # exist yet - so both have to be created in the same dependency graph.
  enable_eventhub_audit = var.enable_eventhub_audit
}

module "cost_attribution" {
  source = "../../modules/cost-attribution"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.primary_location
  name_prefix         = local.name_prefix
  environment_name    = var.environment_name
  tags                = local.tags

  application_insights_id = module.observability.application_insights_id
  api_management_id       = module.ai_gateway.api_management_id
  metric_namespace        = module.ai_gateway.metric_namespace

  consumers = var.consumers

  alert_emails = var.alert_emails

  # A budget with nowhere to send its notifications is a budget nobody finds out about, so the module
  # refuses to build one. Supplying alert_emails is what turns it on.
  enable_budget                  = length(var.alert_emails) > 0
  budget_scope_resource_group_id = azurerm_resource_group.this.id
  monthly_budget_usd             = var.monthly_budget_usd

  token_rate_alert_threshold = var.token_rate_alert_threshold
  daily_spend_threshold_usd  = var.daily_spend_threshold_usd
}
