variable "name_prefix" {
  description = "Prefix for every resource name. Must be globally unique enough to win a Foundry custom subdomain."
  type        = string
  default     = "aigw"
}

variable "environment_name" {
  description = "Environment label, used in names, tags and telemetry."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region. Pick one where the models below are actually available; not every region carries every model."
  type        = string
  default     = "eastus"
}

variable "publisher_name" {
  description = "Publisher name shown in the API Management developer portal."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "Publisher email for API Management. Azure sends service notifications here, so use a monitored address."
  type        = string
}

variable "log_analytics_daily_quota_gb" {
  description = "Daily ingestion cap on the Log Analytics workspace. A cap is a cost guardrail, not a retention policy; data beyond it is dropped, not deferred."
  type        = number
  default     = 5
}

# ---------------------------------------------------------------------------------------------------
# Bring your own observability
#
# Platform teams usually own the workspace and expect workloads to log into it rather than stand up
# their own. Each of these is decided independently: leave one blank and it is created, supply a
# resource ID and it is reused.
#
# Two things to check before reusing an Application Insights component, because neither can be fixed
# from here: it must be workspace-based, and its sampling must be 100%. Application Insights sampling
# silently drops telemetry, and a dropped record is a missing chargeback row, so a sampled component
# understates spend without ever reporting an error.
# ---------------------------------------------------------------------------------------------------

variable "existing_log_analytics_workspace_id" {
  description = "Resource ID of an existing Log Analytics workspace to log into. Leave blank to create one."
  type        = string
  default     = null
}

variable "existing_application_insights_id" {
  description = "Resource ID of an existing Application Insights component to reuse. Leave blank to create one. It must be workspace-based and must not be sampled."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
