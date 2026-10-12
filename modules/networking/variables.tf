# ===================================================================================================
# networking - inputs
# ===================================================================================================

variable "resource_group_name" {
  description = "Resource group for the network resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names."
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

# ---------------------------------------------------------------------------------------------------
# Virtual network
# ---------------------------------------------------------------------------------------------------

variable "existing_virtual_network_id" {
  description = <<-EOT
    Resource ID of a virtual network to deploy into. Leave blank to create one.

    Supplying a network does not oblige you to supply subnets. The common enterprise hand-off is a
    spoke with nothing in it and an expectation that the workload carves its own subnets, so the
    subnet fields below are decided independently of this one.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.existing_virtual_network_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Network/virtualNetworks/[^/]+$", coalesce(var.existing_virtual_network_id, "/")))
    error_message = "existing_virtual_network_id must be a full virtual network resource ID: /subscriptions/{id}/resourceGroups/{rg}/providers/Microsoft.Network/virtualNetworks/{name}. The name and resource group are read back out of it, so a truncated ID produces subnets in the wrong place rather than an error."
  }
}

variable "address_space" {
  description = "Address space of the virtual network this module creates."
  type        = list(string)
  default     = ["10.60.0.0/16"]
}

variable "apim_subnet_address_prefix" {
  description = <<-EOT
    Subnet delegated to API Management.

    The v2 tiers use outbound VNet integration and require the subnet to be delegated to
    Microsoft.Web/serverFarms, with a minimum size of /27. The classic tiers require no delegation but
    do require a /27 or larger and an NSG that permits the management endpoint. Both are handled below.
  EOT
  type        = string
  default     = "10.60.1.0/27"
}

variable "private_endpoint_subnet_address_prefix" {
  description = "Subnet holding the private endpoints for Foundry and any other PaaS dependency."
  type        = string
  default     = "10.60.2.0/24"
}

variable "existing_apim_subnet_id" {
  description = <<-EOT
    Resource ID of an existing subnet for API Management. Leave blank to create one.

    A supplied subnet is used exactly as it is. This module will not attach a network security group,
    a delegation, service endpoints or a NAT gateway to a subnet it did not create - those are
    properties of the subnet itself, and changing them on a platform team's resource from a workload
    deployment is how landing zones get broken. Arrive with the subnet configured, or let this module
    create one.

    Two of those properties are not optional for API Management, so they are checked at plan time
    rather than discovered during the apply: the subnet must have a network security group, and on the
    v2 tiers it must be delegated to Microsoft.Web/serverFarms.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.existing_apim_subnet_id == null || can(regex("(?i)/virtualNetworks/[^/]+/subnets/[^/]+$", coalesce(var.existing_apim_subnet_id, "/")))
    error_message = "existing_apim_subnet_id must be a full subnet resource ID ending in /virtualNetworks/{vnet}/subnets/{subnet}."
  }
}

variable "existing_private_endpoint_subnet_id" {
  description = <<-EOT
    Resource ID of an existing subnet for private endpoints. Leave blank to create one.

    As above, a supplied subnet is left untouched. Check that it has private_endpoint_network_policies
    enabled if you intend network security group rules to apply to the endpoints in it - with the
    policies disabled, which was the platform default for years, rules on that subnet are accepted and
    then never evaluated.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.existing_private_endpoint_subnet_id == null || can(regex("(?i)/virtualNetworks/[^/]+/subnets/[^/]+$", coalesce(var.existing_private_endpoint_subnet_id, "/")))
    error_message = "existing_private_endpoint_subnet_id must be a full subnet resource ID ending in /virtualNetworks/{vnet}/subnets/{subnet}."
  }
}

variable "existing_apim_nsg_id" {
  description = <<-EOT
    Resource ID of an existing network security group to attach to the API Management subnet. Leave
    blank to create one with the rules the chosen tier requires.

    Only consulted when this module creates the API Management subnet. A supplied subnet keeps
    whatever network security group it already has.
  EOT
  type        = string
  default     = null
}

variable "existing_private_endpoint_nsg_id" {
  description = <<-EOT
    Resource ID of an existing network security group to attach to the private endpoint subnet. Leave
    blank to create one that permits HTTPS from the virtual network and denies the rest.

    Only consulted when this module creates the private endpoint subnet.
  EOT
  type        = string
  default     = null
}

variable "apim_sku_name" {
  description = "API Management SKU the subnet is being prepared for. Determines whether the subnet is delegated and which NSG rules are required."
  type        = string
  default     = "StandardV2_1"
}

variable "apim_virtual_network_type" {
  description = "How API Management attaches to the network: None, External or Internal. Only used to decide which NSG rules the classic tiers need."
  type        = string
  default     = "External"

  validation {
    condition     = contains(["None", "External", "Internal"], var.apim_virtual_network_type)
    error_message = "apim_virtual_network_type must be None, External or Internal."
  }
}

# ---------------------------------------------------------------------------------------------------
# Private DNS
# ---------------------------------------------------------------------------------------------------

variable "existing_private_dns_zone_ids" {
  description = <<-EOT
    Resource IDs of private DNS zones that already exist, keyed by zone name. Leave blank to create
    all three; name a zone here and it is used instead of being created.

    The decision is made per zone, not for the set, so a partial hand-over works: supply the one zone
    the platform team owns and this module creates the other two. Foundry needs all three, because
    which zone answers depends on which hostname the caller used, and a missing zone fails
    intermittently rather than outright:

      privatelink.cognitiveservices.azure.com
      privatelink.openai.azure.com
      privatelink.services.ai.azure.com

    In a hub-and-spoke estate these are almost always central. Creating a duplicate zone in a spoke is
    one of the more effective ways to break name resolution for everything else in it, so if you are
    unsure whether your platform team owns them, assume they do and ask.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name in keys(var.existing_private_dns_zone_ids) : contains([
        "privatelink.cognitiveservices.azure.com",
        "privatelink.openai.azure.com",
        "privatelink.services.ai.azure.com",
      ], name)
    ])
    error_message = "existing_private_dns_zone_ids must be keyed by zone name, and Foundry uses only these three: privatelink.cognitiveservices.azure.com, privatelink.openai.azure.com, privatelink.services.ai.azure.com. A key that is a resource name rather than a zone name silently creates a duplicate of the zone you were trying to reuse."
  }
}

variable "create_private_dns_zones" {
  description = <<-EOT
    Override for the per-zone decision above. Leave null to decide by presence, which is almost always
    what you want: zones named in existing_private_dns_zone_ids are reused, the rest are created.

    Set it to false to create no zones at all, including ones you have not supplied. That is a valid
    choice when name resolution is handled somewhere this module cannot see - a central DNS resolver,
    a forwarder, or conditional forwarding from on-premises - and you want no zones here even though
    none were passed in. Private endpoints will still be created; they simply will not have a zone in
    this deployment to register in.

    Setting it to true forces creation of all three, which will collide with any zone of the same name
    already linked to the virtual network.
  EOT
  type        = bool
  default     = null
}

variable "require_private_dns_coverage" {
  description = <<-EOT
    Fail the plan if the deployment would end up with no private DNS zone for Foundry at all.

    This only triggers when create_private_dns_zones is explicitly false and no zones were supplied.
    Without a zone, a client inside the network resolves the model endpoint to its public address and
    the private endpoint is never used - the deployment looks healthy, the traffic is not private, and
    nothing reports an error. Set this to false if resolution genuinely lives elsewhere.
  EOT
  type        = bool
  default     = true
}

variable "link_existing_private_dns_zones" {
  description = <<-EOT
    Link zones supplied through existing_private_dns_zone_ids to this virtual network.

    Off by default, because a centrally-owned zone is usually already linked to the spokes that need
    it and the workload identity usually cannot write to the zone's resource group anyway. Turn it on
    when you own the zones but keep them in a different resource group from this deployment: a zone
    that is not linked to the virtual network resolves nothing from inside it.
  EOT
  type        = bool
  default     = false
}

variable "private_dns_zone_resource_group_name" {
  description = "Resource group to create the private DNS zones in. Defaults to resource_group_name."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------------------------------

variable "enable_nat_gateway" {
  description = <<-EOT
    Attach a NAT gateway to the API Management subnet so that outbound traffic leaves from a stable,
    known address.

    Worth the cost in two situations: a Foundry or partner endpoint that allow-lists source addresses,
    and any workload large enough to exhaust SNAT ports on the platform's shared outbound path.
  EOT
  type        = bool
  default     = false
}

variable "enable_service_endpoints" {
  description = "Add service endpoints for Cognitive Services and Key Vault to the API Management subnet. Harmless when private endpoints are used, and the fallback when they are not."
  type        = bool
  default     = true
}
