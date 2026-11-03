# ===================================================================================================
# cost-attribution - individual attribution and the streaming backfill
#
# The ledger query is generated, not written: the backfill join only exists when a workspace is
# supplied, and the backfill price is rendered from the rate card. These runs pin both shapes, plus
# the alerts that depend on them, against a mocked provider.
#
#   terraform test
# ===================================================================================================

mock_provider "azurerm" {}
mock_provider "random" {}

variables {
  resource_group_name     = "unit-test-rg"
  location                = "eastus2"
  name_prefix             = "unittest"
  application_insights_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/unit-test-rg/providers/Microsoft.Insights/components/unittest-ai"
  api_management_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/unit-test-rg/providers/Microsoft.ApiManagement/service/unittest-apim"
  alert_emails            = ["finops@example.com"]
  enable_budget           = false
}

# ---------------------------------------------------------------------------------------------------
# No workspace: the ledger is exactly the policy's view, with no cross-resource dependency.
# ---------------------------------------------------------------------------------------------------
run "ledger_has_no_backfill_without_workspace" {
  command = plan

  assert {
    condition     = !strcontains(local.ledger_query, "workspace(")
    error_message = "The backfill join must not be rendered when no workspace is supplied."
  }

  assert {
    condition     = strcontains(local.ledger_query, "| extend usageSource = iff(usageMeasured, \"policy\", \"none\")")
    error_message = "usageSource must still exist without the backfill, so the workbook queries are shape-stable."
  }

  assert {
    condition     = strcontains(local.ledger_query, "userAttributed")
    error_message = "The ledger must carry user attribution columns."
  }

  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.user_spend) == 0
    error_message = "The per-user spend alert is opt-in and must not exist without a threshold."
  }

  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.unattributed_user_share) == 1
    error_message = "The unattributed share alert is on by default."
  }
}

# ---------------------------------------------------------------------------------------------------
# Workspace and tiered rate card: the join is rendered against that workspace, and tiers are tested
# highest threshold first so the first matching branch is the right one.
# ---------------------------------------------------------------------------------------------------
run "backfill_join_and_tiered_pricing" {
  command = plan

  variables {
    log_analytics_workspace_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/unit-test-rg/providers/Microsoft.OperationalInsights/workspaces/unittest-law"
    daily_user_spend_threshold_usd = 25
    pricing_map = {
      "chat" = {
        unit   = 1000000
        input  = 5
        output = 30
        contextTiers = [
          { name = "long", minPromptTokens = 272001, input = 10, output = 45 },
          { name = "xl", minPromptTokens = 900001, input = 12 },
        ]
      }
    }
  }

  assert {
    condition     = strcontains(local.ledger_query, "workspace(\"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/unit-test-rg/providers/Microsoft.OperationalInsights/workspaces/unittest-law\").ApiManagementGatewayLlmLog")
    error_message = "The backfill must read the LLM log from the supplied workspace."
  }

  assert {
    condition     = strcontains(local.ledger_query, "on $left.requestId == $right.CorrelationId")
    error_message = "The backfill must join on the request id."
  }

  assert {
    condition = (
      length(local.pricing_branches) == 3 &&
      strcontains(local.pricing_branches[0].predicate, ">= 900001") &&
      strcontains(local.pricing_branches[1].predicate, ">= 272001") &&
      !strcontains(local.pricing_branches[2].predicate, ">=")
    )
    error_message = "Pricing branches must be ordered highest tier first, then the base rate."
  }

  assert {
    condition     = local.pricing_branches[0].output == 0
    error_message = "A tier that omits a rate must price it at zero, as the policy does, not inherit the base rate."
  }

  assert {
    condition     = length(azurerm_monitor_scheduled_query_rules_alert_v2.user_spend) == 1
    error_message = "Setting a threshold must create the per-user spend alert."
  }
}

# ---------------------------------------------------------------------------------------------------
# The directory is optional per field; a user with only a name must not break the plan.
# ---------------------------------------------------------------------------------------------------
run "sparse_user_directory" {
  command = plan

  variables {
    users = {
      "11111111-1111-1111-1111-111111111111" = { display_name = "Siobhan O'Brien" }
      "22222222-2222-2222-2222-222222222222" = {}
    }
  }

  assert {
    condition = alltrue([
      for u in local.user_directory : u.department == "" && u.costCentre == "" && u.displayName != ""
    ])
    error_message = "Missing directory fields must become empty strings, and a missing name falls back to the object id."
  }
}

# ---------------------------------------------------------------------------------------------------
# The telemetry gap is scoped to the gateway API, so other APIs on a shared instance are not counted.
# ---------------------------------------------------------------------------------------------------
run "telemetry_gap_scoped_to_gateway_api" {
  command = plan

  variables {
    gateway_api_name = "unit-llm"
  }

  assert {
    condition     = strcontains(azurerm_monitor_scheduled_query_rules_alert_v2.telemetry_gap[0].criteria[0].query, "let gatewayApi = \"unit-llm\";")
    error_message = "The telemetry gap must count only the gateway API's requests."
  }
}

run "rejects_malformed_workspace_id" {
  command = plan

  variables {
    log_analytics_workspace_id = "unittest-law"
  }

  expect_failures = [var.log_analytics_workspace_id]
}
