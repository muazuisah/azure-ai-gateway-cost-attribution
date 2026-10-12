# ===================================================================================================
# networking - bring-your-own combinations
#
# Every field that accepts an existing resource ID is a branch, and the branches are independent of
# each other, so the interesting cases are the mixed ones rather than the two extremes. These run
# against a mocked provider: no subscription, no credentials, no cost, and they execute in about a
# second, which is what makes them worth having in CI.
#
#   terraform test
# ===================================================================================================

mock_provider "azurerm" {
  # A supplied API Management subnet is read back to check it has a network security group. The
  # default mock returns one, so the happy path is exercised; the run that checks the guard overrides
  # this to null.
  mock_data "azurerm_subnet" {
    defaults = {
      network_security_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/networkSecurityGroups/platform-nsg"
    }
  }
}

variables {
  resource_group_name = "unit-test-rg"
  location            = "eastus2"
  name_prefix         = "unittest"
}

# ---------------------------------------------------------------------------------------------------
# Owning nothing: every field blank, so everything is created. This is the quickstart shape.
# ---------------------------------------------------------------------------------------------------
run "creates_everything_when_no_ids_supplied" {
  command = plan

  assert {
    condition = (
      length(azurerm_virtual_network.this) == 1 &&
      length(azurerm_subnet.apim) == 1 &&
      length(azurerm_subnet.private_endpoints) == 1 &&
      length(azurerm_network_security_group.apim) == 1 &&
      length(azurerm_network_security_group.private_endpoints) == 1
    )
    error_message = "With no existing resource IDs supplied the module must create the network, both subnets and both network security groups."
  }

  assert {
    condition     = length(azurerm_private_dns_zone.foundry) == 3
    error_message = "All three Foundry private DNS zones must be created when none are supplied."
  }

  assert {
    condition     = length(output.missing_private_dns_zones) == 0
    error_message = "A deployment that creates all three zones cannot be missing any."
  }
}

# ---------------------------------------------------------------------------------------------------
# The common enterprise hand-off: an empty spoke, and the workload carves its own subnets in it.
# ---------------------------------------------------------------------------------------------------
run "creates_subnets_inside_a_supplied_virtual_network" {
  command = plan

  variables {
    existing_virtual_network_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/spoke-vnet"
  }

  assert {
    condition     = length(azurerm_virtual_network.this) == 0
    error_message = "A supplied virtual network must not be recreated."
  }

  assert {
    condition     = length(azurerm_subnet.apim) == 1 && length(azurerm_subnet.private_endpoints) == 1
    error_message = "Supplying a virtual network must not stop the module creating subnets in it. The two decisions are independent."
  }

  # The subnet has to be created in the network's resource group, which is not this deployment's.
  assert {
    condition     = azurerm_subnet.apim[0].resource_group_name == "platform-rg"
    error_message = "Subnets must be created in the supplied virtual network's resource group, read back from its ID, not in the deployment's own resource group."
  }

  assert {
    condition     = azurerm_subnet.apim[0].virtual_network_name == "spoke-vnet"
    error_message = "The virtual network name must be parsed out of the supplied resource ID."
  }
}

# ---------------------------------------------------------------------------------------------------
# Subnets supplied too. The module must then leave the subnets entirely alone - no network security
# group of its own, and no association onto a resource it does not own.
# ---------------------------------------------------------------------------------------------------
run "leaves_supplied_subnets_untouched" {
  command = plan

  variables {
    existing_virtual_network_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/spoke-vnet"
    existing_apim_subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/spoke-vnet/subnets/snet-apim"
    existing_private_endpoint_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/spoke-vnet/subnets/snet-pe"
  }

  assert {
    condition     = length(azurerm_subnet.apim) == 0 && length(azurerm_subnet.private_endpoints) == 0
    error_message = "Supplied subnets must not be recreated."
  }

  assert {
    condition = (
      length(azurerm_network_security_group.apim) == 0 &&
      length(azurerm_network_security_group.private_endpoints) == 0
    )
    error_message = "No network security group should be created when both subnets were supplied - it could not be attached to anything, and would sit there looking like it was enforcing something."
  }

  assert {
    condition = (
      length(azurerm_subnet_network_security_group_association.apim) == 0 &&
      length(azurerm_subnet_network_security_group_association.private_endpoints) == 0
    )
    error_message = "The module must never attach a network security group to a subnet it did not create."
  }

  assert {
    condition     = output.network_security_group_id == null
    error_message = "The network security group output must be null for a supplied subnet, because its security is then the caller's concern."
  }
}

# ---------------------------------------------------------------------------------------------------
# Our subnet, their network security group.
# ---------------------------------------------------------------------------------------------------
run "attaches_a_supplied_nsg_to_a_created_subnet" {
  command = plan

  variables {
    existing_apim_nsg_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/networkSecurityGroups/corp-apim-nsg"
    existing_private_endpoint_nsg_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/networkSecurityGroups/corp-pe-nsg"
  }

  assert {
    condition     = length(azurerm_network_security_group.apim) == 0 && length(azurerm_network_security_group.private_endpoints) == 0
    error_message = "A supplied network security group must not be duplicated."
  }

  assert {
    condition     = length(azurerm_network_security_rule.pe_allow_vnet_https) == 0 && length(azurerm_network_security_rule.pe_deny_inbound) == 0
    error_message = "Rules must not be written into a network security group the module does not own."
  }

  assert {
    condition     = azurerm_subnet_network_security_group_association.apim[0].network_security_group_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/networkSecurityGroups/corp-apim-nsg"
    error_message = "The created subnet must be associated with the supplied network security group."
  }
}

# ---------------------------------------------------------------------------------------------------
# Private DNS is decided per zone, so a partial hand-over has to work.
# ---------------------------------------------------------------------------------------------------
run "creates_only_the_dns_zones_not_supplied" {
  command = plan

  variables {
    existing_private_dns_zone_ids = {
      "privatelink.openai.azure.com" = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
    }
  }

  assert {
    condition     = length(azurerm_private_dns_zone.foundry) == 2
    error_message = "One zone was supplied, so exactly the other two must be created."
  }

  assert {
    condition     = !contains(keys(azurerm_private_dns_zone.foundry), "privatelink.openai.azure.com")
    error_message = "The supplied zone must not be recreated. A duplicate private DNS zone in a spoke breaks resolution across the landing zone."
  }

  assert {
    condition     = length(output.private_dns_zone_ids) == 3
    error_message = "The output must combine created and supplied zones, because Foundry needs records in all three."
  }

  assert {
    condition     = length(output.missing_private_dns_zones) == 0
    error_message = "Two created plus one supplied leaves none missing."
  }
}

run "does_not_link_supplied_dns_zones_by_default" {
  command = plan

  variables {
    existing_private_dns_zone_ids = {
      "privatelink.openai.azure.com" = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
    }
  }

  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.supplied) == 0
    error_message = "A centrally-owned zone must not be linked unless asked for; the deployment usually has no rights to it and it is usually already linked."
  }
}

run "links_supplied_dns_zones_on_request" {
  command = plan

  variables {
    link_existing_private_dns_zones = true
    existing_private_dns_zone_ids = {
      "privatelink.openai.azure.com" = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
    }
  }

  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.supplied) == 1
    error_message = "link_existing_private_dns_zones must link the zones that were supplied."
  }
}

# ---------------------------------------------------------------------------------------------------
# Guards. Each of these is a failure that is expensive or confusing to discover any later.
# ---------------------------------------------------------------------------------------------------
run "rejects_a_supplied_apim_subnet_with_no_nsg" {
  command = plan

  variables {
    existing_apim_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/spoke-vnet/subnets/snet-apim"
  }

  override_data {
    target = data.azurerm_subnet.existing_apim[0]
    values = {
      network_security_group_id = null
    }
  }

  expect_failures = [terraform_data.guards]
}

run "rejects_a_malformed_virtual_network_id" {
  command = plan

  variables {
    existing_virtual_network_id = "spoke-vnet"
  }

  expect_failures = [var.existing_virtual_network_id]
}

run "rejects_dns_zone_ids_keyed_by_anything_but_zone_name" {
  command = plan

  variables {
    existing_private_dns_zone_ids = {
      "openai-zone" = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.openai.azure.com"
    }
  }

  expect_failures = [var.existing_private_dns_zone_ids]
}

run "rejects_disabling_dns_with_no_alternative" {
  command = plan

  variables {
    create_private_dns_zones = false
  }

  expect_failures = [terraform_data.guards]
}

run "allows_disabling_dns_when_declared_deliberate" {
  command = plan

  variables {
    create_private_dns_zones     = false
    require_private_dns_coverage = false
  }

  assert {
    condition     = length(azurerm_private_dns_zone.foundry) == 0
    error_message = "create_private_dns_zones = false must create no zones at all."
  }

  assert {
    condition     = length(output.missing_private_dns_zones) == 3
    error_message = "With no zones created or supplied, all three must be reported as missing so the gap is visible rather than silent."
  }
}
