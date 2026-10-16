# ===================================================================================================
# cost-attribution
#
# Layer 2. The gateway already knows who called it, which model they used and how many tokens they
# burned. This module turns that stream into something a finance conversation can survive:
#
#   * a workbook that allocates real Azure spend across consumers by their share of tokens,
#   * alerts for the three ways chargeback silently goes wrong - unpriced models, unmeasured usage and
#     unexpected spend,
#   * an Azure Cost Management budget over what Azure actually bills,
#   * and, optionally, an unsampled Event Hub stream for numbers that have to survive an audit.
#
# The estimate is a management signal, not an invoice. Application Insights decides *who*; Cost
# Management decides *how much*. Anything that claims to do both is lying about one of them.
# ===================================================================================================

locals {
  tags = merge(var.tags, {
    "module"      = "cost-attribution"
    "environment" = var.environment_name
  })

  action_group_id = var.existing_action_group_id != null ? var.existing_action_group_id : (
    length(azurerm_monitor_action_group.this) > 0 ? azurerm_monitor_action_group.this[0].id : null
  )

  # Whether an action group will exist, decided from the input variables alone. It deliberately does
  # NOT consult local.action_group_id: that reads the id of a resource created in this same apply, so
  # it is unknown at plan time, and a count derived from an unknown value makes Terraform refuse to
  # plan the whole configuration ("Invalid count argument"). This expression is the same condition
  # that creates azurerm_monitor_action_group.this below, so the two cannot disagree.
  action_group_available = var.existing_action_group_id != null || length(var.alert_emails) > 0

  alerts_enabled = var.enable_alerts && local.action_group_available

  budget_start_date = coalesce(var.budget_start_date, formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp()))

  # Cost Management distinguishes thresholds evaluated against money already spent from thresholds
  # evaluated against where the month is heading. Anything over 100% of budget can only be a forecast.
  actual_thresholds = [for t in var.budget_thresholds_percent : t if t <= 100]
  forecast_thresholds = distinct(concat(
    [for t in var.budget_thresholds_percent : t if t > 100],
    var.budget_forecast_threshold_percent != null ? [var.budget_forecast_threshold_percent] : []
  ))

  consumer_registry = [
    for name, consumer in var.consumers : {
      consumer      = name
      costCentre    = consumer.cost_centre
      owner         = coalesce(consumer.owner, "")
      businessUnit  = coalesce(consumer.business_unit, "")
      monthlyBudget = coalesce(consumer.monthly_budget_usd, 0)
    }
  ]

  budget_contact_emails = distinct(compact(concat(
    var.alert_emails,
    [for k, v in var.consumers : v.alert_email]
  )))

  # -------------------------------------------------------------------------------------------------
  # The ledger projection.
  #
  # Every query below starts from this. Pinning it in one place means the schema is defined once and
  # the alerts cannot drift away from the workbook.
  # -------------------------------------------------------------------------------------------------
  ledger_query = <<-KQL
    traces
    | where message startswith "llm.request"
    | extend
        correlationId  = tostring(customDimensions["correlationId"]),
        environment    = tostring(customDimensions["environment"]),
        product        = tostring(customDimensions["product"]),
        subscriptionId = tostring(customDimensions["subscriptionId"]),
        consumerId     = tostring(customDimensions["consumerId"]),
        consumerName   = tostring(customDimensions["consumerName"]),
        consumerTypeRaw = tostring(customDimensions["consumerType"]),
        modelAlias     = tostring(customDimensions["modelAlias"]),
        deployment     = tostring(customDimensions["deployment"]),
        pool           = tostring(customDimensions["pool"]),
        statusCode     = toint(customDimensions["statusCode"]),
        streaming      = tostring(customDimensions["streaming"]) =~ "True",
        usageMeasured  = tostring(customDimensions["usageMeasured"]) =~ "True",
        promptTokens   = toint(customDimensions["promptTokens"]),
        // Prompt tokens charged at the full input rate, i.e. promptTokens minus the cached ones. The
        // policy prices on this, so a report that recomputes spend from promptTokens alone will not
        // reconcile against the ledger's own estimatedCostUSD.
        billablePromptTokens = toint(customDimensions["billablePromptTokens"]),
        cachedTokens   = toint(customDimensions["cachedTokens"]),
        // Writing to the prompt cache is billed separately from reading it, and reasoning tokens are
        // billed as output the caller never sees. Both are emitted per request and both are a common
        // source of "the invoice is higher than the ledger" when they are left out of a breakdown.
        cacheWriteTokens = toint(customDimensions["cacheWriteTokens"]),
        reasoningTokens  = toint(customDimensions["reasoningTokens"]),
        completionTokens = toint(customDimensions["completionTokens"]),
        totalTokens    = toint(customDimensions["totalTokens"]),
        estimatedCostUSD = todouble(customDimensions["estimatedCostUSD"]),
        // Served from the semantic cache, so no model ran and estimatedCostUSD is zero by design.
        // Without this column a cache hit is indistinguishable from a genuinely free request, and the
        // drop in spend that caching produces has no visible cause.
        cacheHitRaw = tostring(customDimensions["cacheHit"]),
        // What caching saved: the whole request on a semantic cache hit, or the input discount on
        // tokens the model served from its prompt cache. Coalesced because traces predate the field,
        // and a null here would poison every sum it takes part in rather than contributing nothing.
        costAvoidedUSD = coalesce(todouble(customDimensions["costAvoidedUSD"]), 0.0),
        contextTierRaw = tostring(customDimensions["contextTier"])
    // consumer is the chargeback key. It prefers the Entra identity and falls back to the APIM
    // subscription id, so the same queries keep working on traces emitted before caller
    // authentication was enabled - and across a staged rollout where both shapes are in flight.
    // A separate extend is required because KQL cannot reference a column defined in the same one.
    | extend
        consumer     = iff(isempty(consumerId), subscriptionId, consumerId),
        consumerType = iff(isempty(consumerTypeRaw), "subscription", consumerTypeRaw)
    | extend consumerLabel = iff(isempty(consumerName), consumer, consumerName)
    // Which rate card priced the request: "base" for a flat-rate model, or a tier name such as
    // "long" when input length pushed it into a higher band. Defaulted for traces emitted before
    // context tiers existed.
    | extend contextTier = iff(isempty(contextTierRaw), "base", contextTierRaw)
    | extend cacheHit = cacheHitRaw =~ "True"
  KQL
}

# ---------------------------------------------------------------------------------------------------
# Notification target
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "this" {
  count = var.existing_action_group_id == null && length(var.alert_emails) > 0 ? 1 : 0

  name                = "${var.name_prefix}-ai-cost-ag"
  resource_group_name = var.resource_group_name
  short_name          = substr(replace("${var.name_prefix}cost", "-", ""), 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = { for idx, address in var.alert_emails : idx => address }
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 1 - unpriced models
#
# The gateway reports an unknown model's cost as -1 rather than 0. A zero would have been absorbed
# silently into the monthly total and nobody would notice until the reconciliation was already wrong.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "unpriced_models" {
  count = local.alerts_enabled ? 1 : 0

  name                = "${var.name_prefix}-ai-unpriced-models"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "A model alias served by the AI gateway is missing from the pricing map, so its spend is not being attributed to anyone."
  severity    = 3
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = var.alert_evaluation_frequency
  window_duration         = var.alert_evaluation_frequency
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      ${local.ledger_query}
      | where estimatedCostUSD < 0
      | summarize UnpricedRequests = count() by modelAlias
    KQL

    time_aggregation_method = "Total"
    metric_measure_column   = "UnpricedRequests"
    threshold               = var.unpriced_model_threshold
    operator                = "GreaterThanOrEqual"

    dimension {
      name     = "modelAlias"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 1b - long prompts priced at a flat rate
#
# Some models charge more above a context-length threshold. GPT-5.5 doubles its input rate and raises
# output by half above 272,000 prompt tokens, and the whole request reprices - it is not marginal.
#
# If the pricing map has no contextTiers for such a model, every one of those requests is costed at
# the short-context rate and the ledger under-reports by roughly half. Nothing about the resulting
# number looks wrong, which is exactly why it needs an alert rather than a dashboard: the failure is
# a missing configuration, and a missing configuration produces no symptom on its own.
#
# A request that genuinely has no tier because its model is flat-rate priced is not caught here, since
# the threshold only fires on prompts long enough to matter.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "untiered_long_context" {
  count = local.alerts_enabled ? 1 : 0

  name                = "${var.name_prefix}-ai-untiered-long-context"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "Requests with very long prompts are being priced at a flat rate. If the model has context-length pricing, add contextTiers to its pricing_map entry - otherwise this spend is under-reported."
  severity    = 3
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = var.alert_evaluation_frequency
  window_duration         = var.alert_evaluation_frequency
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      ${local.ledger_query}
      | where usageMeasured and estimatedCostUSD >= 0
      | where promptTokens >= ${var.long_context_review_threshold}
      | where contextTier == "base"
      | summarize UntieredLongRequests = count() by modelAlias
    KQL

    time_aggregation_method = "Total"
    metric_measure_column   = "UntieredLongRequests"
    threshold               = var.untiered_long_context_threshold
    operator                = "GreaterThanOrEqual"

    dimension {
      name     = "modelAlias"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 2 - unmeasured usage
#
# A streaming caller who omits stream_options.include_usage gets a perfectly good answer and returns no
# token counts at all. Their spend is real and invisible. This alert is the difference between a
# chargeback model that is approximately right and one that is confidently wrong.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "unmeasured_usage" {
  count = local.alerts_enabled ? 1 : 0

  name                = "${var.name_prefix}-ai-unmeasured-usage"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "Successful gateway requests are returning no token usage, so their cost cannot be attributed. Usually a streaming client that has not set stream_options.include_usage."
  severity    = 3
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = var.alert_evaluation_frequency
  window_duration         = var.alert_evaluation_frequency
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      ${local.ledger_query}
      | where statusCode between (200 .. 299)
      | summarize Total = count(), Unmeasured = countif(not(usageMeasured)) by product
      | where Total > 0
      | extend UnmeasuredPercent = round(100.0 * Unmeasured / Total, 2)
      | project product, UnmeasuredPercent
    KQL

    time_aggregation_method = "Maximum"
    metric_measure_column   = "UnmeasuredPercent"
    threshold               = var.unmeasured_usage_threshold_percent
    operator                = "GreaterThan"

    dimension {
      name     = "product"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 3 - product spend
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "product_spend" {
  count = local.alerts_enabled ? 1 : 0

  name                = "${var.name_prefix}-ai-product-spend"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "A product tier's estimated spend over the trailing day has exceeded its threshold."
  severity    = 2
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = "PT1H"
  window_duration         = "P1D"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      ${local.ledger_query}
      | where estimatedCostUSD > 0
      | summarize SpendUSD = round(sum(estimatedCostUSD), 4) by product
    KQL

    time_aggregation_method = "Total"
    metric_measure_column   = "SpendUSD"
    threshold               = var.daily_spend_threshold_usd
    operator                = "GreaterThan"

    dimension {
      name     = "product"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 4 - telemetry gap
#
# Compares the number of ledger records against the number of requests the gateway API actually served.
# If the ledger is short, the chargeback numbers are short too, and the usual cause is the API
# diagnostic sampling percentage having been moved off 100 by someone trying to save money on
# Application Insights ingestion.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "telemetry_gap" {
  count = local.alerts_enabled ? 1 : 0

  name                = "${var.name_prefix}-ai-telemetry-gap"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "Fewer chargeback ledger records than gateway requests. Check that the API diagnostic sampling percentage is still 100 and verbosity is still verbose."
  severity    = 2
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = "PT1H"
  window_duration         = "PT6H"
  auto_mitigation_enabled = true

  criteria {
    query = <<-KQL
      let ledgerCount = toscalar(
          traces
          | where message startswith "llm.request"
          | count
      );
      requests
      | where success == true or toint(resultCode) between (200 .. 599)
      | summarize GatewayRequests = count()
      | extend LedgerRecords = coalesce(ledgerCount, 0)
      | extend MissingPercent = iff(GatewayRequests == 0, 0.0, round(100.0 * (GatewayRequests - LedgerRecords) / GatewayRequests, 2))
      | project MissingPercent
    KQL

    time_aggregation_method = "Maximum"
    metric_measure_column   = "MissingPercent"
    threshold               = 5
    operator                = "GreaterThan"

    # Both must be 1. Azure rejects a rule with multiple evaluation periods unless the query projects
    # a datetime 'timestamp' column, and this query deliberately does not - it collapses the whole
    # window to a single percentage rather than producing a time series. Asking for 3 periods returns
    # "Number of evaluation periods must be 1 for queries that do not project the 'timestamp' column"
    # at apply time, long after every static check has passed. The other four rules here are already
    # 1/1 for the same reason.
    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 5 - token burn rate
#
# The only alert here that reads a metric rather than a log. Metrics arrive in about a minute; log
# queries run hourly. A runaway agent loop can spend a great deal of money in an hour.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_metric_alert" "token_burn_rate" {
  count = local.alerts_enabled && var.token_rate_alert_threshold != null ? 1 : 0

  name                = "${var.name_prefix}-ai-token-burn-rate"
  resource_group_name = var.resource_group_name
  scopes              = [var.api_management_id]
  tags                = local.tags

  description = "Token consumption through the AI gateway has exceeded its five-minute ceiling."
  severity    = 2
  frequency   = "PT1M"
  window_size = "PT5M"

  criteria {
    metric_namespace = var.metric_namespace
    metric_name      = "Total Tokens"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.token_rate_alert_threshold

    # "Total Tokens" is a custom metric emitted by llm-emit-token-metric in the gateway policy, so it
    # does not exist in the namespace until real traffic has flowed. Azure validates metric names at
    # creation time and rejects the unknown name with
    #   "Couldn't find a metric named Total Tokens ... If this metric hasn't been reported yet, use
    #    the -skipMetricValidation flag"
    # which makes this alert impossible to create on a fresh deployment - the alert needs the traffic
    # and the traffic is what the alert is meant to be watching. Skipping validation is the documented
    # answer for custom metrics that are not emitted yet; the rule simply stays dormant until the
    # first tokens arrive.
    skip_metric_validation = true
  }

  action {
    action_group_id = local.action_group_id
  }
}

# ---------------------------------------------------------------------------------------------------
# Alert 6 - cache economics
#
# Caching is assumed to save money and is almost never checked. It does not always save money.
#
# Writing to a prompt cache is charged at a premium over the normal input rate, and reading from one is
# charged at a discount. A workload whose prompts vary just enough to miss on every request pays the
# write premium repeatedly and collects the read discount rarely, so enabling the cache makes the bill
# go up. Nothing about this is visible in a spend chart: the total simply drifts upward and looks like
# organic growth.
#
# This compares what caching actually returned against what it cost to populate, per model, and fires
# when the return falls short. It is deliberately scoped per modelAlias - one badly-behaved workload
# can be net-negative while the estate as a whole still benefits, and the aggregate would hide it.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "cache_economics" {
  count = local.alerts_enabled && var.enable_cache_economics_alert ? 1 : 0

  name                = "${var.name_prefix}-ai-cache-economics"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  description = "Caching is costing more than it is saving for a model. Prompts are varying too much to hit the cache while still paying the cache-write premium. Review whether caching is worth keeping on for this workload."
  severity    = 3
  enabled     = true

  scopes                  = [var.application_insights_id]
  evaluation_frequency    = "PT1H"
  window_duration         = "P1D"
  auto_mitigation_enabled = true

  criteria {
    # The write premium is approximated as 25 percent of the input rate, which is where Azure prices
    # it for the models that charge for cache writes at all. The ledger carries the token counts but
    # not a per-request breakdown of which rate applied to which token, so the exact premium is not
    # recoverable here - and it does not need to be. This alert answers "is this cache worth having",
    # a question that turns on a ratio, not on a precise figure.
    query = <<-KQL
      ${local.ledger_query}
      | where statusCode between (200 .. 299)
      | summarize
          SavedUSD = sum(costAvoidedUSD),
          WriteTokens = sum(cacheWriteTokens),
          Requests = count()
          by modelAlias
      // Below this volume the ratio is noise - a handful of requests during a cold cache will always
      // look net-negative, because populating a cache necessarily precedes reading it.
      | where Requests >= ${var.cache_economics_minimum_requests}
      | where WriteTokens > 0
      | extend EstimatedWriteCostUSD = (WriteTokens / 1000000.0) * ${var.cache_write_premium_usd_per_million}
      | extend NetCacheBenefitUSD = round(SavedUSD - EstimatedWriteCostUSD, 6)
      | project modelAlias, NetCacheBenefitUSD
    KQL

    time_aggregation_method = "Minimum"
    metric_measure_column   = "NetCacheBenefitUSD"
    threshold               = 0
    operator                = "LessThan"

    dimension {
      name     = "modelAlias"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [local.action_group_id]
  }
}

# ---------------------------------------------------------------------------------------------------
# Budget
#
# Watches what Azure actually charges, not what the gateway estimated. The two are reconciled in the
# workbook; if they disagree by more than about ten percent for several days running, the pricing map
# is stale.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_consumption_budget_resource_group" "foundry" {
  count = var.enable_budget ? 1 : 0

  name              = "${var.name_prefix}-ai-foundry-budget"
  resource_group_id = var.budget_scope_resource_group_id

  amount     = var.monthly_budget_usd
  time_grain = "Monthly"

  time_period {
    start_date = local.budget_start_date
  }

  dynamic "notification" {
    for_each = { for t in local.actual_thresholds : tostring(t) => t }
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      threshold_type = "Actual"
      contact_emails = local.budget_contact_emails
      contact_groups = local.action_group_id != null ? [local.action_group_id] : []
    }
  }

  dynamic "notification" {
    for_each = { for t in local.forecast_thresholds : "forecast-${t}" => t }
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThan"
      threshold_type = "Forecasted"
      contact_emails = local.budget_contact_emails
      contact_groups = local.action_group_id != null ? [local.action_group_id] : []
    }
  }

  lifecycle {
    precondition {
      condition     = var.budget_scope_resource_group_id != null
      error_message = "budget_scope_resource_group_id is required when enable_budget is true."
    }

    precondition {
      condition     = length(local.budget_contact_emails) > 0 || var.existing_action_group_id != null
      error_message = "A budget needs somewhere to send its notifications. Supply alert_emails, per-consumer alert_email values, or existing_action_group_id."
    }

    # The start date is stamped from the current month on first apply. Without this the budget would
    # be proposed for replacement every month, on every plan, forever.
    ignore_changes = [time_period]
  }
}

# ---------------------------------------------------------------------------------------------------
# Chargeback workbook
# ---------------------------------------------------------------------------------------------------
resource "random_uuid" "workbook" {
  count = var.enable_workbook ? 1 : 0
}

resource "azurerm_application_insights_workbook" "chargeback" {
  count = var.enable_workbook ? 1 : 0

  name                = random_uuid.workbook[0].result
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = coalesce(var.workbook_display_name, "AI Gateway chargeback (${var.environment_name})")
  category            = "workbook"
  source_id           = lower(var.application_insights_id)
  tags                = local.tags

  data_json = templatefile("${path.module}/workbooks/cost-attribution.workbook.json", {
    environment_name = var.environment_name
    # The registry is embedded in a KQL string literal which is itself inside a JSON string. The inner
    # double quotes therefore have to survive one round of JSON decoding, so they are escaped here and
    # the KQL literal is single-quoted in the template.
    consumer_registry = replace(jsonencode(local.consumer_registry), "\"", "\\\"")
  })
}
