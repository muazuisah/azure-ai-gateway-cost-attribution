# Individual (per-user) attribution: input validation, the rendered policy and the LLM-log wiring.
#
# Providers are mocked, so these runs exercise the module's own logic without touching Azure.

mock_provider "azurerm" {
  mock_data "azurerm_api_management" {
    defaults = {
      identity = [{
        type         = "SystemAssigned"
        principal_id = "22222222-2222-2222-2222-222222222222"
        tenant_id    = "11111111-1111-1111-1111-111111111111"
        identity_ids = []
      }]
    }
  }

  # The provider parses some ids during apply, so mocked ids have to be well formed.
  mock_resource "azurerm_api_management_logger" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test/loggers/appinsights"
    }
  }
}

mock_provider "azapi" {}
mock_provider "random" {}

variables {
  resource_group_name                      = "rg-test"
  location                                 = "swedencentral"
  name_prefix                              = "test"
  existing_api_management_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test"
  application_insights_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Insights/components/appi-test"
  application_insights_instrumentation_key = "00000000-0000-0000-0000-000000000000"
  log_analytics_workspace_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"

  foundry_backends = {
    primary = {
      inference_url = "https://foundry-test.services.ai.azure.com"
      deployments   = ["gpt-4.1-mini"]
    }
  }

  model_routes = {
    "chat-small" = {
      deployment       = "gpt-4.1-mini"
      description      = "Test route."
      backend_priority = { primary = 1 }
    }
  }
}

run "rejects_user_attribution_with_subscription_keys" {
  command = plan

  variables {
    caller_authentication = {
      mode             = "subscription_key"
      user_attribution = { enabled = true }
    }
  }

  expect_failures = [var.caller_authentication]
}

run "rejects_non_positive_per_user_limit" {
  command = plan

  variables {
    caller_authentication = {
      mode      = "both"
      tenant_id = "11111111-1111-1111-1111-111111111111"
      audiences = ["api://ai-gateway"]
      user_attribution = {
        enabled                    = true
        tokens_per_minute_per_user = 0
      }
    }
  }

  expect_failures = [var.caller_authentication]
}

run "renders_user_attribution_policy" {
  command = apply

  variables {
    enable_diagnostics      = true
    enable_cost_attribution = true
    pricing_map = {
      "chat-small" = { unit = 1000000, input = 0.4, cachedInput = 0.1, output = 1.6, effectiveDate = "2026-01-01" }
    }
    caller_authentication = {
      mode      = "both"
      tenant_id = "11111111-1111-1111-1111-111111111111"
      audiences = ["api://ai-gateway"]
      user_attribution = {
        enabled                    = true
        tokens_per_minute_per_user = 5000
      }
    }
  }

  assert {
    condition     = strcontains(azurerm_api_management_api_policy.llm.xml_content, "<metadata name=\"schemaVersion\" value=\"3\" />")
    error_message = "The ledger must be written at schema version 3."
  }

  assert {
    condition     = strcontains(azurerm_api_management_api_policy.llm.xml_content, "x-ai-user-tokens-remaining")
    error_message = "A per-user token limit was configured but not rendered."
  }

  assert {
    condition     = length(azapi_resource.llm_api_azuremonitor_diagnostic) == 1
    error_message = "LLM logs must be enabled on the API so streamed usage can be backfilled."
  }

  assert {
    condition     = azurerm_monitor_diagnostic_setting.apim[0].log_analytics_destination_type == "Dedicated"
    error_message = "GatewayLlmLogs only reach Log Analytics in resource-specific (Dedicated) mode."
  }
}

run "omits_user_limit_when_disabled" {
  command = apply

  variables {
    enable_diagnostics = true
    enable_llm_logs    = false
  }

  assert {
    condition     = !strcontains(azurerm_api_management_api_policy.llm.xml_content, "x-ai-user-tokens-remaining")
    error_message = "No per-user limit should be rendered when user attribution is off."
  }

  assert {
    condition     = length(azapi_resource.llm_api_azuremonitor_diagnostic) == 0
    error_message = "The LLM-log API diagnostic must follow enable_llm_logs."
  }
}
