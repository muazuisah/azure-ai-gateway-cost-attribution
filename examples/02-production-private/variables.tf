variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "aigw"
}

variable "environment_name" {
  description = "Environment label, used in names, tags and telemetry."
  type        = string
  default     = "prod"
}

variable "primary_location" {
  description = "Primary region. Carries priority-1 traffic for every route."
  type        = string
  default     = "eastus"
}

variable "secondary_location" {
  description = "Secondary region. Takes over when the primary's circuit breakers trip, and shares load on the routes that list both at the same priority."
  type        = string
  default     = "westeurope"
}

variable "publisher_name" {
  description = "Publisher name shown in the developer portal."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "Publisher email for API Management service notifications. Use a monitored distribution list, not a person."
  type        = string
}

# ---------------------------------------------------------------------------------------------------
# API Management
# ---------------------------------------------------------------------------------------------------

variable "apim_sku_name" {
  description = <<-EOT
    API Management SKU.

    Standard v2 is the default across this accelerator: it supports VNet integration, backend pools,
    circuit breakers and the token-limit policies, at a fraction of Premium's cost. Choose Premium v2
    when you need multi-region gateway deployment or availability zones for the gateway itself - note
    that the *models* are already multi-region here regardless, because that is the pool's job.
  EOT
  type        = string
  default     = "StandardV2_1"
}

variable "apim_virtual_network_type" {
  description = <<-EOT
    How the gateway attaches to the network.

    "External" keeps the gateway publicly addressable while its outbound traffic reaches Foundry over
    the virtual network - the usual choice, because the Foundry accounts are the thing that must be
    private, not the gateway. Use "Internal" only when the gateway itself must be unreachable from the
    internet, and be ready to provide your own ingress in front of it.
  EOT
  type        = string
  default     = "External"
}

variable "address_space" {
  description = "Virtual network address space."
  type        = string
  default     = "10.60.0.0/16"
}

variable "apim_subnet_address_prefix" {
  description = "Subnet for API Management. Minimum /27."
  type        = string
  default     = "10.60.1.0/27"
}

variable "private_endpoint_subnet_address_prefix" {
  description = "Subnet for the Foundry private endpoints."
  type        = string
  default     = "10.60.2.0/24"
}

variable "create_private_dns_zones" {
  description = "Override for the per-zone decision. Leave null to create only the zones not supplied below. False creates none at all, for estates where resolution is handled by a central resolver."
  type        = bool
  default     = null
}

variable "existing_private_dns_zone_ids" {
  description = "Centrally owned private DNS zones, keyed by zone name. Decided per zone: name the ones that already exist and the rest are created."
  type        = map(string)
  default     = {}
}

variable "require_private_dns_coverage" {
  description = "Fail the plan if the deployment would end up with no private DNS zone at all. Set false only when name resolution genuinely lives outside this deployment."
  type        = bool
  default     = true
}

variable "link_existing_private_dns_zones" {
  description = "Link the zones named above to this virtual network. Usually unnecessary - a central zone is normally linked already - and usually not permitted from a workload deployment."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------
# Bring your own network
#
# Each of these is decided on its own. Leave one blank and this deployment creates that piece; supply
# a resource ID and it uses what is already there. The realistic cases are the mixed ones: a platform
# team hands over an empty spoke and expects the workload to carve its own subnets, or owns the
# subnets as well and leaves you only what hangs off them.
#
# A supplied subnet is used exactly as it is. This deployment will not attach a network security
# group, a delegation or a NAT gateway to a subnet it did not create - those are properties of the
# subnet, and changing them on a platform team's resource from a workload deployment is how landing
# zones get broken. Two things API Management cannot start without are checked while the plan is
# still on screen: the subnet must have a network security group, and the v2 tiers need it delegated
# to Microsoft.Web/serverFarms.
# ---------------------------------------------------------------------------------------------------

variable "existing_virtual_network_id" {
  description = "Deploy into an existing virtual network. Leave blank to create one. Supplying it does not stop subnets being created in it."
  type        = string
  default     = null
}

variable "existing_apim_subnet_id" {
  description = "Existing subnet for API Management. Leave blank to create one, sized and configured for the chosen tier."
  type        = string
  default     = null
}

variable "existing_private_endpoint_subnet_id" {
  description = "Existing subnet for the Foundry private endpoints. Leave blank to create one."
  type        = string
  default     = null
}

variable "existing_apim_nsg_id" {
  description = "Existing network security group for the API Management subnet. Leave blank to create one with the rules the chosen tier requires. Only used when this deployment creates the subnet."
  type        = string
  default     = null
}

variable "existing_private_endpoint_nsg_id" {
  description = "Existing network security group for the private endpoint subnet. Leave blank to create one that allows HTTPS from the virtual network and denies the rest."
  type        = string
  default     = null
}

variable "enable_nat_gateway" {
  description = "Give the gateway a stable outbound address. Worth it when a downstream endpoint allow-lists source IPs, or at volumes where SNAT port exhaustion becomes real."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------------------------------

variable "chat_capacity" {
  description = "Capacity units for the frontier chat deployment in each region. For Standard SKUs this is thousands of tokens per minute."
  type        = number
  default     = 100
}

variable "chat_mini_capacity" {
  description = "Capacity units for the small chat deployment in each region."
  type        = number
  default     = 200
}

variable "embedding_capacity" {
  description = "Capacity units for the embedding deployment in each region."
  type        = number
  default     = 100
}

# ---------------------------------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------------------------------

variable "content_safety_threshold" {
  description = "Severity threshold applied to every harm category, on the eight-level scale. Lower is stricter. 4 blocks medium severity and above."
  type        = number
  default     = 4
}

# ---------------------------------------------------------------------------------------------------
# Consumers and cost
# ---------------------------------------------------------------------------------------------------

variable "subscriptions" {
  description = "Consuming applications, keyed by application name. The key becomes the chargeback identity, so name these after applications rather than after people."
  type = map(object({
    product_key  = string
    display_name = optional(string)
    state        = optional(string, "active")
    cost_centre  = optional(string)
    owner        = optional(string)
  }))
  default = {}
}

variable "consumers" {
  description = "Finance metadata per consuming application. Keys must match the subscriptions above, because that name is what the gateway stamps onto every ledger record."
  type = map(object({
    cost_centre        = string
    owner              = optional(string)
    business_unit      = optional(string)
    monthly_budget_usd = optional(number)
    alert_email        = optional(string)
  }))
  default = {}
}

variable "pricing_map" {
  description = <<-EOT
    Rates per million tokens, keyed by model alias. Generate it rather than typing it:

      python scripts/generate_pricing_map.py --region eastus --alias chat=gpt-4.1 --alias embed=text-embedding-3-large

    An alias missing from this map is reported with a cost of -1, which shows up as "unpriced" in the
    workbook and raises an alert, rather than quietly contributing zero to the monthly total.
  EOT
  type        = any
  default     = {}
}

variable "monthly_budget_usd" {
  description = "Monthly Cost Management budget over the resource group's actual Azure spend."
  type        = number
  default     = 5000
}

variable "daily_spend_threshold_usd" {
  description = "Per-product estimated daily spend that raises an alert."
  type        = number
  default     = 250
}

variable "token_rate_alert_threshold" {
  description = "Total tokens in five minutes that raises a near-real-time alert. The fast signal that catches a runaway agent loop before the hourly log alerts do."
  type        = number
  default     = 2000000
}

variable "alert_emails" {
  description = "Addresses that receive cost and data-quality alerts."
  type        = list(string)
  default     = []
}

variable "enable_eventhub_audit" {
  description = "Stream every request out unsampled, for chargeback numbers that have to survive an audit."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "Log Analytics retention in days."
  type        = number
  default     = 90
}

variable "log_analytics_daily_quota_gb" {
  description = "Daily ingestion cap in GB. Set it high enough that the chargeback ledger is never the thing that gets dropped."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------------------------------
# Caller authentication
#
# Leave caller_tenant_id null to run on subscription keys alone. Set it, together with at least one of
# caller_audiences or caller_client_application_ids, to require a Microsoft Entra token as well.
# ---------------------------------------------------------------------------------------------------
variable "caller_tenant_id" {
  description = "Microsoft Entra tenant whose tokens the gateway accepts. Null disables caller authentication and falls back to subscription keys."
  type        = string
  default     = null
}

variable "caller_audiences" {
  description = "Accepted token audiences, normally the gateway's own Application ID URI (api://<app-id> or a custom URI). Validating a token without checking its audience would accept any token this tenant ever issued, including one minted for a different API."
  type        = list(string)
  default     = []
}

variable "caller_client_application_ids" {
  description = "Allow-list of calling application (client) IDs. Combine with caller_audiences for defence in depth: the audience proves the token was meant for this gateway, the client id proves which application asked for it."
  type        = list(string)
  default     = []
}

variable "caller_consumer_names" {
  description = "Optional friendly names for cost reports, keyed by the claim value that identifies the caller - normally the client application id. Cosmetic only; unmapped callers still attribute correctly, just as a GUID."
  type        = map(string)
  default     = {}
}
