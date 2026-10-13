# ===================================================================================================
# Example 01 - quickstart
#
# The smallest deployment that is still worth putting in front of a team: one Foundry account, two
# models, a public gateway on Standard v2, and two product tiers with real token ceilings.
#
# What it is for: proving the pattern, running a workshop, or giving an application team something to
# code against on day one. It is not the production topology - example 02 is - but everything in it is
# the same code, so moving between them is a change of variables rather than a rewrite.
#
# Cost note: Standard v2 API Management is billed hourly whether or not anyone calls it. Destroy this
# when you are finished with it.
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
  name_prefix = "${var.name_prefix}-${var.environment_name}"

  tags = merge(var.tags, {
    environment = var.environment_name
    workload    = "ai-gateway"
    managed_by  = "terraform"
    example     = "01-quickstart"
  })
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------------------------------
# Foundry
#
# One account, keyless. local_auth_enabled defaults to false, so there is no API key to leak: the
# gateway's managed identity is the only way in.
# ---------------------------------------------------------------------------------------------------
module "foundry" {
  source = "../../modules/foundry-models"

  resource_group_name = azurerm_resource_group.this.name
  name_prefix         = local.name_prefix
  tags                = local.tags

  accounts = {
    primary = {
      location = var.location
    }
  }

  # Model versions rot, and they stop being deployable well before they stop serving traffic. Azure
  # marks a version "deprecating" - rejecting new deployments with ServiceModelDeprecating - while the
  # catalogue still advertises an inference date years away. Confirm what is deployable today before
  # you run this:
  #
  #   az cognitiveservices model list --location <region> \
  #     --query "[?kind=='AIServices' && model.format=='OpenAI'].{name:model.name,ver:model.version}" -o table
  model_deployments = {
    "gpt-4.1-mini" = {
      model_name    = "gpt-4.1-mini"
      model_version = "2025-04-14"
      sku_name      = "GlobalStandard"
      capacity      = 50
    }
    "text-embedding-3-small" = {
      model_name    = "text-embedding-3-small"
      model_version = "1"
      sku_name      = "GlobalStandard"
      capacity      = 50
    }
  }

  # Role assignments are granted from the gateway module instead. Doing it here would require the
  # gateway's principal ID, which is not known until after this module has produced the endpoints the
  # gateway needs - a dependency cycle between the two module blocks.
  gateway_principal_ids    = []
  diagnostics_workspace_id = module.observability.log_analytics_workspace_id
  enable_diagnostics       = true
}

module "observability" {
  source = "../../modules/observability"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  name_prefix         = local.name_prefix
  tags                = local.tags

  log_retention_days = 30
  daily_quota_gb     = var.log_analytics_daily_quota_gb

  log_analytics_workspace_id = var.existing_log_analytics_workspace_id
  application_insights_id    = var.existing_application_insights_id
}

# ---------------------------------------------------------------------------------------------------
# Gateway
# ---------------------------------------------------------------------------------------------------
module "ai_gateway" {
  source = "../../modules/ai-gateway"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  name_prefix         = local.name_prefix
  environment_name    = var.environment_name
  tags                = local.tags

  apim_sku_name   = "StandardV2_1"
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email

  foundry_backends    = module.foundry.accounts
  foundry_account_ids = module.foundry.account_ids

  # Aliases are the gateway's public contract. Applications code against "chat-small", not against
  # "gpt-4.1-mini", which is what makes it possible to change the model underneath without touching a
  # single consumer.
  model_routes = {
    "chat-small" = {
      deployment       = "gpt-4.1-mini"
      description      = "General-purpose chat. Fast and inexpensive; the sensible default."
      backend_priority = { primary = 1 }
    }
    "embed-small" = {
      deployment       = "text-embedding-3-small"
      description      = "Text embeddings for retrieval and clustering."
      backend_priority = { primary = 1 }
    }
  }

  products = {
    "experimentation" = {
      display_name       = "Experimentation"
      description        = "Prototyping and evaluation. Deliberately capped so that a runaway notebook cannot become a budget conversation."
      tokens_per_minute  = 20000
      token_quota        = 5000000
      token_quota_period = "Monthly"
    }
    "production" = {
      display_name       = "Production"
      description        = "Applications with a named owner and a funded cost centre."
      tokens_per_minute  = 100000
      token_quota        = 100000000
      token_quota_period = "Monthly"
    }
  }

  subscriptions = {
    "demo-app" = {
      product_key  = "experimentation"
      display_name = "demo-app"
      cost_centre  = "CC-DEMO"
      owner        = var.publisher_email
    }
  }

  application_insights_id                  = module.observability.application_insights_id
  application_insights_instrumentation_key = module.observability.application_insights_instrumentation_key
  log_analytics_workspace_id               = module.observability.log_analytics_workspace_id
  enable_diagnostics                       = true

  # Cost attribution is off here, which means no pricing map is needed. Example 03 turns it on.
  enable_cost_attribution = false
}
