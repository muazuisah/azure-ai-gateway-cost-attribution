# ===================================================================================================
# Example 03 - cost attribution onto an API Management instance you already own
#
# Layer 2 without Layer 1's greenfield assumptions. Nothing here creates an API Management instance, a
# Foundry account or a network: the gateway API, its products and its chargeback telemetry are added to
# infrastructure that already exists, which is the situation most engagements actually start from.
#
# What you need before running this:
#   * an API Management instance on a tier that supports the token-limit policies - anything except
#     Consumption - with a system-assigned managed identity,
#   * one or more Foundry accounts with the deployments listed in model_routes,
#   * that identity holding Cognitive Services User on each of those accounts,
#   * an Application Insights resource.
#
# Read the chargeback model before you present its numbers to anyone: docs/cost-attribution.md. The
# short version is that the gateway decides *who* consumed capacity and Azure Cost Management decides
# *how much* it cost. Presenting the gateway's estimate as an invoice is the one way to get this wrong.
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
  features {}
  resource_provider_registrations = "none"
}

provider "azapi" {}

locals {
  tags = merge(var.tags, {
    environment = var.environment_name
    workload    = "ai-gateway"
    managed_by  = "terraform"
    example     = "03-cost-attribution"
  })
}

data "azurerm_resource_group" "target" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------------------------------------------
# Semantic cache store (optional, created only when one is not supplied)
#
# Same bring-your-own rule the networking example uses: name an existing cache and it is used as is,
# leave it blank and one is created here. Most organisations already run a cache and would rather not
# have Terraform stand up a second one next to it.
#
# The module requires RediSearch, which is why this is Azure Managed Redis rather than Azure Cache for
# Redis. The Basic, Standard and Premium tiers of the latter cannot carry the module, and the failure
# is silent: lookups return no match, every request goes to the model, and the cache reports as healthy
# while never serving a hit.
# ---------------------------------------------------------------------------------------------------
locals {
  create_semantic_cache = var.enable_semantic_cache && var.semantic_cache_redis_connection_string == null

  semantic_cache_connection_string = var.enable_semantic_cache ? (
    local.create_semantic_cache ? format(
      "%s:%d,password=%s,ssl=True,abortConnect=False",
      azurerm_managed_redis.semantic[0].hostname,
      azurerm_managed_redis.semantic[0].default_database[0].port,
      azurerm_managed_redis.semantic[0].default_database[0].primary_access_key,
    ) : var.semantic_cache_redis_connection_string
  ) : null
}

resource "azurerm_managed_redis" "semantic" {
  count = local.create_semantic_cache ? 1 : 0

  name                = "${var.name_prefix}-${var.environment_name}-amr"
  resource_group_name = var.resource_group_name
  location            = coalesce(var.semantic_cache_redis_location, data.azurerm_resource_group.target.location)
  sku_name            = var.semantic_cache_redis_sku
  tags                = local.tags

  default_database {
    client_protocol = "Encrypted"

    # API Management authenticates to the cache with an access key, so key authentication has to stay
    # on. There is no managed-identity path from the semantic cache policies to Redis.
    access_keys_authentication_enabled = true

    # RediSearch holds its index in memory and cannot rebuild an entry the cache has already thrown
    # away, so the database is told never to evict. The alternative is an index that drifts out of
    # agreement with the keyspace under memory pressure.
    eviction_policy = "NoEviction"

    # RediSearch indexes are not distributed across OSS cluster shards, so the enterprise clustering
    # policy is the one that works with the module rather than a preference.
    clustering_policy = "EnterpriseCluster"

    module {
      name = "RediSearch"
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Gateway, onto existing API Management
# ---------------------------------------------------------------------------------------------------
module "ai_gateway" {
  source = "../../modules/ai-gateway"

  resource_group_name = var.resource_group_name
  location            = data.azurerm_resource_group.target.location
  name_prefix         = var.name_prefix
  environment_name    = var.environment_name
  tags                = local.tags

  existing_api_management_id = var.existing_api_management_id
  api_path                   = var.api_path

  foundry_backends = var.foundry_backends

  # The identity already holds Cognitive Services User on these accounts, so no role assignment is
  # made here. Pass the account IDs instead if you would rather Terraform owned the grant.
  foundry_account_ids = var.foundry_account_ids

  model_routes  = var.model_routes
  products      = var.products
  subscriptions = var.subscriptions

  application_insights_id                  = var.application_insights_id
  application_insights_instrumentation_key = var.application_insights_instrumentation_key

  # The setting that decides whether any of this is accurate. The trace policy that writes the
  # chargeback ledger emits only at verbose verbosity and is then sampled like everything else, so a
  # gateway left on a default sampling percentage reports a fraction of its real usage while looking
  # entirely healthy. Pinned to 100 on this API alone, so the cost is paid only where it buys something.
  diagnostic_sampling_percentage = 100

  enable_cost_attribution = true
  pricing_map             = var.pricing_map

  # Caching changes what the ledger means, not just what it costs: on a hit the gateway reports the
  # spend it avoided instead of the spend it incurred. docs/cost-attribution.md section 5b is the part
  # to read before presenting those numbers.
  enable_semantic_cache                  = var.enable_semantic_cache
  semantic_cache_redis_connection_string = local.semantic_cache_connection_string
  semantic_cache_embeddings_deployment   = var.semantic_cache_embeddings_deployment
  semantic_cache_embeddings_backend      = var.semantic_cache_embeddings_backend
  semantic_cache_settings                = var.semantic_cache_settings

  # The unsampled copy of the ledger. This lives on the gateway module rather than the reporting module
  # because the API policy is what writes to the hub, and a policy cannot name a logger that does not
  # exist yet - so both have to be created in the same dependency graph.
  enable_eventhub_audit = var.enable_eventhub_audit
}

# ---------------------------------------------------------------------------------------------------
# Chargeback
# ---------------------------------------------------------------------------------------------------
module "cost_attribution" {
  source = "../../modules/cost-attribution"

  resource_group_name = var.resource_group_name
  location            = data.azurerm_resource_group.target.location
  name_prefix         = var.name_prefix
  environment_name    = var.environment_name
  tags                = local.tags

  application_insights_id = var.application_insights_id
  api_management_id       = var.existing_api_management_id
  metric_namespace        = module.ai_gateway.metric_namespace

  consumers    = var.consumers
  alert_emails = var.alert_emails

  enable_budget                  = var.enable_budget
  budget_scope_resource_group_id = var.foundry_resource_group_id
  monthly_budget_usd             = var.monthly_budget_usd
  budget_thresholds_percent      = var.budget_thresholds_percent

  daily_spend_threshold_usd          = var.daily_spend_threshold_usd
  token_rate_alert_threshold         = var.token_rate_alert_threshold
  unmeasured_usage_threshold_percent = var.unmeasured_usage_threshold_percent

  enable_cache_economics_alert        = var.enable_cache_economics_alert
  cache_write_premium_usd_per_million = var.cache_write_premium_usd_per_million
}
