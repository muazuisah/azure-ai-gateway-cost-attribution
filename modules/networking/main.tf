# ===================================================================================================
# networking
#
# The network the private deployment topology sits on: a virtual network, a subnet prepared correctly
# for whichever API Management tier is in use, a subnet for private endpoints, and the three private
# DNS zones Foundry needs.
#
# This module is optional. Skip it when a platform team already owns the landing zone and feed their
# subnet and zone IDs into the other modules instead - duplicating a private DNS zone inside a spoke
# is a reliable way to break name resolution for everything else in it.
# ===================================================================================================

locals {
  tags = merge(var.tags, { "module" = "networking" })

  # Every piece of this network is independently bring-your-own, and the decision is made by presence:
  # a field left blank is a request to create that resource, a field with a resource ID in it is a
  # request to use what is already there.
  #
  # The pieces are decided separately rather than from one switch because the realistic enterprise
  # hand-over is partial. A platform team gives you an empty spoke and expects you to carve your own
  # subnets in it; or owns the private DNS zones centrally and nothing else; or owns the whole network
  # and leaves you only the resources that hang off it. All of those work here, as does owning
  # nothing, which is what the quickstart does.
  create_vnet        = var.existing_virtual_network_id == null
  create_apim_subnet = var.existing_apim_subnet_id == null
  create_pe_subnet   = var.existing_private_endpoint_subnet_id == null

  # A network security group is only created when there is a subnet of ours to attach it to. Creating
  # one next to a supplied subnet would leave an unattached resource behind that looks like it is
  # enforcing something.
  create_apim_nsg = local.create_apim_subnet && var.existing_apim_nsg_id == null
  create_pe_nsg   = local.create_pe_subnet && var.existing_private_endpoint_nsg_id == null

  # Creating a subnet needs the virtual network's name and resource group. When the network came in as
  # an ID they are read back out of it rather than asked for a second time - two fields that have to
  # agree are two fields that can disagree. The variable's own validation guarantees the shape, so the
  # regex cannot come back empty.
  supplied_vnet_name = try(regex("(?i)/virtualNetworks/([^/]+)$", coalesce(var.existing_virtual_network_id, "/"))[0], null)
  supplied_vnet_rg   = try(regex("(?i)/resourceGroups/([^/]+)/", coalesce(var.existing_virtual_network_id, "/"))[0], null)

  vnet_name = local.create_vnet ? one(azurerm_virtual_network.this[*].name) : local.supplied_vnet_name
  vnet_rg   = local.create_vnet ? var.resource_group_name : local.supplied_vnet_rg
  vnet_id   = local.create_vnet ? one(azurerm_virtual_network.this[*].id) : var.existing_virtual_network_id

  # The v2 tiers integrate outbound through a delegated subnet; the classic tiers inject the service
  # itself into an undelegated subnet. The delegation is not cosmetic - the platform refuses the
  # deployment if it is wrong in either direction.
  is_v2_sku = can(regex("V2_", var.apim_sku_name))

  dns_zone_names = [
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
  ]

  dns_zone_rg = coalesce(var.private_dns_zone_resource_group_name, var.resource_group_name)

  # Per zone, not for the set. Supplying one zone and letting the module create the other two is a
  # supported and fairly common shape, so the all-or-nothing version of this was wrong.
  dns_zones_to_create = var.create_private_dns_zones == false ? [] : [
    for name in local.dns_zone_names :
    name if var.create_private_dns_zones == true || !contains(keys(var.existing_private_dns_zone_ids), name)
  ]

  apim_subnet_id = local.create_apim_subnet ? one(azurerm_subnet.apim[*].id) : var.existing_apim_subnet_id
  pe_subnet_id   = local.create_pe_subnet ? one(azurerm_subnet.private_endpoints[*].id) : var.existing_private_endpoint_subnet_id

  apim_nsg_id = local.create_apim_nsg ? one(azurerm_network_security_group.apim[*].id) : var.existing_apim_nsg_id
  pe_nsg_id   = local.create_pe_nsg ? one(azurerm_network_security_group.private_endpoints[*].id) : var.existing_private_endpoint_nsg_id

  private_dns_zone_ids = merge(
    { for name, zone in azurerm_private_dns_zone.foundry : name => zone.id },
    var.existing_private_dns_zone_ids,
  )

  service_endpoints = var.enable_service_endpoints ? ["Microsoft.CognitiveServices", "Microsoft.KeyVault", "Microsoft.Storage"] : []

  missing_dns_zones = [for name in local.dns_zone_names : name if !contains(keys(local.private_dns_zone_ids), name)]
}

# A supplied subnet is read back so that the two properties API Management cannot start without are
# checked while there is still a plan on screen. Both of these otherwise fail part-way through a
# thirty-minute apply, and the network security group one fails intermittently, which is worse.
data "azurerm_subnet" "existing_apim" {
  count = local.create_apim_subnet ? 0 : 1

  name                 = regex("(?i)/subnets/([^/]+)$", var.existing_apim_subnet_id)[0]
  virtual_network_name = regex("(?i)/virtualNetworks/([^/]+)/subnets/", var.existing_apim_subnet_id)[0]
  resource_group_name  = regex("(?i)/resourceGroups/([^/]+)/", var.existing_apim_subnet_id)[0]
}

resource "terraform_data" "guards" {
  input = {
    vnet    = local.create_vnet
    subnets = [local.create_apim_subnet, local.create_pe_subnet]
    zones   = local.dns_zones_to_create
  }

  lifecycle {
    precondition {
      condition     = local.create_vnet || local.supplied_vnet_name != null
      error_message = "existing_virtual_network_id does not look like a virtual network resource ID, so the network name and resource group could not be read out of it."
    }

    # API Management refuses to deploy into a subnet with no network security group, and says so with
    # NetworkSecurityGroupNotFound after the instance has already begun provisioning.
    precondition {
      condition     = local.create_apim_subnet || var.apim_virtual_network_type == "None" || one(data.azurerm_subnet.existing_apim[*].network_security_group_id) != null
      error_message = "The subnet supplied as existing_apim_subnet_id has no network security group attached, and API Management will not deploy into one without it. Attach a network security group to that subnet, or leave existing_apim_subnet_id blank and let this module create a subnet with the rules the ${var.apim_sku_name} tier needs."
    }

    precondition {
      condition     = !var.link_existing_private_dns_zones || length(var.existing_private_dns_zone_ids) > 0
      error_message = "link_existing_private_dns_zones is true but existing_private_dns_zone_ids is empty, so there is nothing to link."
    }

    # Not fatal - resolution may be handled by a resolver this module cannot see - but silence here
    # produces private endpoints that resolve to public addresses, which looks like it works until it
    # matters. Only raised when the caller explicitly asked for no zones.
    precondition {
      condition     = var.create_private_dns_zones != false || length(var.existing_private_dns_zone_ids) > 0 || !var.require_private_dns_coverage
      error_message = "create_private_dns_zones is false and no zones were supplied, so Foundry's private endpoints will have nowhere to register and callers inside the network will keep resolving the public address. If name resolution is handled elsewhere - a central resolver or a forwarder - set require_private_dns_coverage = false to confirm that is deliberate."
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Virtual network and subnets
# ---------------------------------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  count = local.create_vnet ? 1 : 0

  name                = "${var.name_prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "apim" {
  count = local.create_apim_subnet ? 1 : 0

  name = "snet-apim"
  # The subnet lives in the virtual network's resource group, which is not necessarily this
  # deployment's own when the network was supplied.
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.apim_subnet_address_prefix]

  dynamic "service_endpoint" {
    for_each = toset(local.service_endpoints)
    content {
      service = service_endpoint.value
    }
  }

  dynamic "delegation" {
    for_each = local.is_v2_sku ? [1] : []
    content {
      name = "apim-v2-outbound"
      service_delegation {
        name    = "Microsoft.Web/serverFarms"
        actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  count = local.create_pe_subnet ? 1 : 0

  name                 = "snet-private-endpoints"
  resource_group_name  = local.vnet_rg
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.private_endpoint_subnet_address_prefix]

  private_endpoint_network_policies = "Enabled"
}

# ---------------------------------------------------------------------------------------------------
# Network security
#
# The classic tiers inject the service into the subnet and need the control-plane rules below or the
# deployment degrades in ways that are hard to attribute. The v2 tiers integrate outbound only and need
# none of it, so the rules are omitted rather than applied "just in case" - an unnecessary allow rule is
# still an allow rule somebody has to justify at review time.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_network_security_group" "apim" {
  count = local.create_apim_nsg ? 1 : 0

  name                = "${var.name_prefix}-apim-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "apim_management" {
  count = local.create_apim_nsg && !local.is_v2_sku ? 1 : 0

  name = "AllowApiManagementControlPlane"
  # Without this rule a classic-tier instance reports as unhealthy and configuration updates silently
  # stop applying, which is a genuinely unpleasant failure to diagnose after the fact.
  description                 = "Required by the classic tiers so that Azure can manage the injected service."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim[0].name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3443"
  source_address_prefix       = "ApiManagement"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "apim_load_balancer" {
  count = local.create_apim_nsg && !local.is_v2_sku ? 1 : 0

  name                        = "AllowAzureLoadBalancerHealthProbe"
  description                 = "Health probes from the platform load balancer."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim[0].name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "6390"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "apim_client_https" {
  count = local.create_apim_nsg && !local.is_v2_sku && var.apim_virtual_network_type == "External" ? 1 : 0

  name                        = "AllowClientHttps"
  description                 = "Client traffic to the gateway when the instance is externally reachable."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.apim[0].name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "VirtualNetwork"
}

// Only ever applied to a subnet this module created. Attaching a network security group to a
// supplied subnet would reconfigure a resource the caller already owns, and would fight whatever
// their platform team's policy puts there.
resource "azurerm_subnet_network_security_group_association" "apim" {
  count = local.create_apim_subnet ? 1 : 0

  subnet_id                 = azurerm_subnet.apim[0].id
  network_security_group_id = local.apim_nsg_id
}

# ---------------------------------------------------------------------------------------------------
# Private endpoint subnet security
#
# A subnet with no NSG inherits only the platform defaults, which permit any VNet-sourced traffic to
# reach it. That is a wide blast radius for the one subnet holding private links to Foundry, Key Vault
# and storage: anything that gains a foothold anywhere in the VNet, or in a peered VNet, can reach
# every private endpoint in it.
#
# Note that NSG rules only take effect on private endpoints because private_endpoint_network_policies
# is "Enabled" on the subnet above. With it disabled - which was the default for years - these rules
# would be accepted by Terraform and silently never evaluated.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_network_security_group" "private_endpoints" {
  count = local.create_pe_nsg ? 1 : 0

  name                = "${var.name_prefix}-pe-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "pe_allow_vnet_https" {
  count = local.create_pe_nsg ? 1 : 0

  name                        = "AllowVnetHttpsInbound"
  description                 = "Private endpoints are reached over 443 from inside the virtual network."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints[0].name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

# The platform's own DenyAllInBound sits at priority 65500, *below* AllowVnetInBound at 65000. Without
# an explicit rule here, that default allow wins and the 443-only rule above constrains nothing.
resource "azurerm_network_security_rule" "pe_deny_inbound" {
  count = local.create_pe_nsg ? 1 : 0

  name                        = "DenyAllInbound"
  description                 = "Everything other than the HTTPS rule above is denied."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints[0].name
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  count = local.create_pe_subnet ? 1 : 0

  subnet_id                 = azurerm_subnet.private_endpoints[0].id
  network_security_group_id = local.pe_nsg_id
}

# ---------------------------------------------------------------------------------------------------
# Private DNS
#
# All three zones, every time. Which one answers depends on the hostname the caller used, and Foundry
# is reachable under all three. Creating only the obvious one produces a gateway that works until
# somebody changes a base URL.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "foundry" {
  for_each = toset(local.dns_zones_to_create)

  name                = each.value
  resource_group_name = local.dns_zone_rg
  tags                = local.tags
}

# A zone this module creates is linked to the network it is for, otherwise it resolves nothing. This
# applies whether the network was created here or supplied - an unlinked zone is not a half-working
# zone, it is an invisible one.
resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  for_each = toset(local.dns_zones_to_create)

  name                 = "${var.name_prefix}-link"
  private_dns_zone_id  = azurerm_private_dns_zone.foundry[each.value].id
  virtual_network_id   = local.vnet_id
  registration_enabled = false
  tags                 = local.tags
}

# Supplied zones are left alone by default. Linking a centrally-owned zone is usually both
# unnecessary and not permitted, so it is opt-in.
resource "azurerm_private_dns_zone_virtual_network_link" "supplied" {
  for_each = var.link_existing_private_dns_zones ? var.existing_private_dns_zone_ids : {}

  name                 = "${var.name_prefix}-link"
  private_dns_zone_id  = each.value
  virtual_network_id   = local.vnet_id
  registration_enabled = false
  tags                 = local.tags
}

# ---------------------------------------------------------------------------------------------------
# Stable egress (optional)
#
# Gated on this module owning the API Management subnet rather than the virtual network. A NAT gateway
# is attached to a subnet, and attaching one to a subnet the caller supplied would silently redirect
# the egress of everything else already in it.
# ---------------------------------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  count = var.enable_nat_gateway && local.create_apim_subnet ? 1 : 0

  name                = "${var.name_prefix}-nat-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  count = var.enable_nat_gateway && local.create_apim_subnet ? 1 : 0

  name                    = "${var.name_prefix}-nat"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = var.enable_nat_gateway && local.create_apim_subnet ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "apim" {
  count = var.enable_nat_gateway && local.create_apim_subnet ? 1 : 0

  subnet_id      = azurerm_subnet.apim[0].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}
