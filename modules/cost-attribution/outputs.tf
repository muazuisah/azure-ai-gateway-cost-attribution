output "action_group_id" {
  description = "Action group notified by the cost alerts, whether created here or supplied."
  value       = local.action_group_id
}

output "workbook_id" {
  description = "Resource ID of the chargeback workbook."
  value       = var.enable_workbook ? azurerm_application_insights_workbook.chargeback[0].id : null
}

output "budget_id" {
  description = "Resource ID of the Cost Management budget watching actual Foundry spend."
  value       = var.enable_budget ? azurerm_consumption_budget_resource_group.foundry[0].id : null
}

output "alert_rule_ids" {
  description = "Resource IDs of the alert rules created by this module, keyed by what they watch."
  value = merge(
    {
      for key, rules in {
        unpriced_models       = azurerm_monitor_scheduled_query_rules_alert_v2.unpriced_models
        untiered_long_context = azurerm_monitor_scheduled_query_rules_alert_v2.untiered_long_context
        unmeasured_usage      = azurerm_monitor_scheduled_query_rules_alert_v2.unmeasured_usage
        product_spend         = azurerm_monitor_scheduled_query_rules_alert_v2.product_spend
        telemetry_gap         = azurerm_monitor_scheduled_query_rules_alert_v2.telemetry_gap
        user_spend            = azurerm_monitor_scheduled_query_rules_alert_v2.user_spend
        unattributed_users    = azurerm_monitor_scheduled_query_rules_alert_v2.unattributed_user_share
      } : key => length(rules) > 0 ? rules[0].id : null
    },
    {
      token_burn_rate = length(azurerm_monitor_metric_alert.token_burn_rate) > 0 ? azurerm_monitor_metric_alert.token_burn_rate[0].id : null
    }
  )
}

output "consumer_registry" {
  description = "The chargeback register as supplied, echoed for downstream reporting and for the ratio-allocation step in any external finance system."
  value = {
    for name, consumer in var.consumers : name => {
      cost_centre        = consumer.cost_centre
      owner              = consumer.owner
      business_unit      = consumer.business_unit
      monthly_budget_usd = consumer.monthly_budget_usd
    }
  }
}

output "ledger_query" {
  description = <<-EOT
    The KQL projection of the chargeback ledger, exported so that external reporting reads the same
    schema the alerts and the workbook do. Append your own summarisation to it.
  EOT
  value       = local.ledger_query
}
