# ===================================================================================================
# cost-attribution - inputs
# ===================================================================================================

variable "resource_group_name" {
  description = "Resource group that holds the reporting artefacts created by this module."
  type        = string
}

variable "location" {
  description = "Azure region for the reporting artefacts."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names. Keep it short; some names have tight length limits."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 characters of lowercase letters, digits or hyphens."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "environment_name" {
  description = "Environment label used in workbook titles and alert descriptions."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------------------------------
# Telemetry sources
# ---------------------------------------------------------------------------------------------------

variable "application_insights_id" {
  description = "Application Insights resource the gateway writes its chargeback ledger to. The workbook and every log alert read from here."
  type        = string
}

variable "api_management_id" {
  description = "API Management resource ID, used to scope the gateway metric alerts."
  type        = string
}

variable "metric_namespace" {
  description = "Custom metric namespace the gateway emits token counts to, matching the ai-gateway module's metric_namespace."
  type        = string
  default     = "aigateway"
}

# ---------------------------------------------------------------------------------------------------
# Consumers
# ---------------------------------------------------------------------------------------------------

variable "consumers" {
  description = <<-EOT
    The chargeback register: who consumes the gateway and who pays for them.

    The key must equal the consumer identity the gateway stamps onto each ledger record, because that
    is the column the workbook joins on. Which value that is depends on how callers authenticate:

      * caller_authentication = "subscription_key"
          The key from the ai-gateway module's `subscriptions` map. That map key becomes the API
          Management subscription id verbatim, and the policy records it as the consumer.

      * caller_authentication = "entra_id"
          The Entra claim value the policy resolved - in practice the calling application's client id.
          These are the same keys you use in the ai-gateway module's `entra_consumer_names`, which
          supplies the friendly label the reports display beside the id.

      * caller_authentication = "both"
          Token-authenticated callers are recorded by claim, key-only callers by subscription id, so
          register whichever identities are actually in use. The ledger's consumerType column records
          which of the two priced each request.

    A consumer that appears in the ledger but not here is not dropped: it is reported with a cost
    centre of "unassigned", which is the signal that the register has drifted from reality.

    Everything else here is finance metadata that Azure has no way of knowing.

    * cost_centre     - The account that gets charged.
    * owner           - Who to contact when the spend looks wrong.
    * monthly_budget_usd - Soft budget used for the per-consumer burn-down in the workbook and, when
                           alerting is enabled, for a spend alert at each threshold percentage.
  EOT

  type = map(object({
    cost_centre        = string
    owner              = optional(string)
    business_unit      = optional(string)
    monthly_budget_usd = optional(number)
    alert_email        = optional(string)
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.consumers : v.monthly_budget_usd == null || v.monthly_budget_usd > 0
    ])
    error_message = "monthly_budget_usd must be greater than zero when set."
  }
}

# ---------------------------------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------------------------------

variable "enable_alerts" {
  description = "Create the log and metric alert rules. Turn this off in ephemeral environments where nobody is watching the mailbox."
  type        = bool
  default     = true
}

variable "existing_action_group_id" {
  description = "Action group to notify. Leave null to have the module create one from alert_emails."
  type        = string
  default     = null
}

variable "alert_emails" {
  description = "Addresses notified by the action group this module creates. Ignored when existing_action_group_id is set."
  type        = list(string)
  default     = []
}

variable "alert_evaluation_frequency" {
  description = "How often the log alert rules run, as an ISO 8601 duration."
  type        = string
  default     = "PT1H"
}

variable "unpriced_model_threshold" {
  description = <<-EOT
    Number of unpriced requests in an evaluation window that triggers the unpriced-model alert.

    An unpriced request is one whose model alias is absent from the pricing map. The gateway reports
    its cost as -1 rather than 0, precisely so that a missing rate shows up as a gap rather than as
    free usage. This alert is what stops that gap from going unnoticed for a month.
  EOT
  type        = number
  default     = 1
}

variable "enable_cache_economics_alert" {
  description = <<-EOT
    Alert when caching costs a model more than it saves it.

    Cache writes are billed at a premium and cache reads at a discount, so a workload whose prompts
    vary too much to hit the cache pays the premium without collecting the discount. Turn this off if
    caching is disabled, or if the gateway serves workloads where cold-cache periods are expected and
    the noise is unwelcome.
  EOT
  type        = bool
  default     = true
}

variable "cache_economics_minimum_requests" {
  description = <<-EOT
    Requests a model must serve in a day before its cache economics are judged.

    Populating a cache necessarily happens before reading it, so any small sample taken around a cold
    start looks net-negative. This suppresses that.
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.cache_economics_minimum_requests >= 1
    error_message = "cache_economics_minimum_requests must be at least 1."
  }
}

variable "cache_write_premium_usd_per_million" {
  description = <<-EOT
    Assumed extra cost, per million tokens, of writing to the prompt cache rather than sending the
    same tokens as ordinary input. Used only to judge whether caching is paying for itself.

    This is a single estimate applied across models because the ledger records how many tokens were
    written to cache, not which rate card priced them. The alert it feeds turns on whether a ratio is
    above or below one, so an approximation is sufficient; raise it if the models behind this gateway
    charge more for cache writes than the default assumes.
  EOT
  type        = number
  default     = 0.25

  validation {
    condition     = var.cache_write_premium_usd_per_million >= 0
    error_message = "cache_write_premium_usd_per_million cannot be negative."
  }
}

variable "unmeasured_usage_threshold_percent" {
  description = <<-EOT
    Percentage of successful requests with no usage block that triggers an alert.

    Streaming callers who omit stream_options.include_usage return no token counts at all, so their
    spend is invisible to the ledger. A rising percentage here means the chargeback numbers are
    quietly drifting away from reality.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.unmeasured_usage_threshold_percent > 0 && var.unmeasured_usage_threshold_percent <= 100
    error_message = "unmeasured_usage_threshold_percent must be between 0 and 100."
  }
}

variable "daily_spend_threshold_usd" {
  description = <<-EOT
    Raise an alert when any single product's estimated spend over the trailing day exceeds this amount.

    Deliberately an absolute threshold rather than a baseline comparison. Azure log alerts evaluate
    over a window of at most two days, which is too short to establish a trailing average worth
    comparing against, and a rule that silently compares against a meaningless baseline is worse than
    no rule. The trailing-average and anomaly views live in the workbook, where the query range is
    unconstrained.
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.daily_spend_threshold_usd > 0
    error_message = "daily_spend_threshold_usd must be greater than zero."
  }
}

variable "token_rate_alert_threshold" {
  description = <<-EOT
    Total tokens in a five-minute window that raises a near-real-time alert, read from the
    llm-emit-token-metric custom metric rather than from the log ledger.

    This is the fast signal. The log alerts above are accurate but arrive on an hourly cadence; a
    runaway agent loop can spend real money inside that hour. Set to null to disable.
  EOT
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------------------------------
# Budgets
#
# Cost Management is the source of truth for money. The gateway ledger decides who consumed what; the
# budget watches what Azure actually bills. Keeping both is the whole point.
# ---------------------------------------------------------------------------------------------------

variable "enable_budget" {
  description = "Create an Azure Cost Management budget over the Foundry spend this gateway fronts."
  type        = bool
  default     = true
}

variable "budget_scope_resource_group_id" {
  description = "Resource group whose actual Azure spend the budget watches. Normally the group holding the Foundry accounts. Required when enable_budget is true."
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Total monthly budget for the gateway's Foundry spend."
  type        = number
  default     = 1000

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_thresholds_percent" {
  description = <<-EOT
    Percentages of the budget at which to notify.

    Values at or below 100 are evaluated against actual spend; values above 100 make little sense for
    actual cost, so anything above 100 is raised as a forecast notification instead. Forecast alerts
    are the useful ones: they arrive while there is still time to act.
  EOT
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = length(var.budget_thresholds_percent) > 0 && alltrue([for t in var.budget_thresholds_percent : t > 0 && t <= 1000])
    error_message = "budget_thresholds_percent must contain at least one value between 1 and 1000."
  }
}

variable "budget_forecast_threshold_percent" {
  description = "Percentage of the budget that, if forecast to be reached this month, raises a notification. Set to null to skip the forecast notification."
  type        = number
  default     = 100
}

variable "budget_start_date" {
  description = "First day of the budget period, as YYYY-MM-01T00:00:00Z. Defaults to the first day of the current month. Azure rejects a start date in the past for a new budget, so pin this once the budget exists."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------------------------------
# Workbook
# ---------------------------------------------------------------------------------------------------

variable "enable_workbook" {
  description = "Deploy the chargeback workbook."
  type        = bool
  default     = true
}

variable "workbook_display_name" {
  description = "Display name of the chargeback workbook."
  type        = string
  default     = null
}

variable "long_context_review_threshold" {
  description = <<-EOT
    Prompt-token count above which a request is considered long enough that context-length pricing
    might apply to it.

    Default 200,000. Chosen below the lowest real threshold in use (GPT-5.5 reprices above 272,000)
    so that a workload creeping towards the boundary is noticed before it crosses it, rather than
    after a month of under-reported invoices.

    This is only used to decide which requests the untiered_long_context alert examines. It has no
    effect on what anything costs - the actual thresholds live in pricing_map contextTiers.
  EOT
  type        = number
  default     = 200000

  validation {
    condition     = var.long_context_review_threshold > 0
    error_message = "long_context_review_threshold must be greater than zero."
  }
}

variable "untiered_long_context_threshold" {
  description = <<-EOT
    How many flat-rate long-prompt requests in one evaluation window before the alert fires.

    Not zero-tolerance, because a model that genuinely has one flat rate at every context length will
    produce these legitimately, and an alert nobody can clear gets muted - at which point it is worse
    than absent. Set it to 1 if every model you serve is known to have context tiers configured.
  EOT
  type        = number
  default     = 25

  validation {
    condition     = var.untiered_long_context_threshold >= 1
    error_message = "untiered_long_context_threshold must be at least 1."
  }
}
