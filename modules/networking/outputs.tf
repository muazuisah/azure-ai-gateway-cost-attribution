output "virtual_network_id" {
  description = "Resource ID of the virtual network, whether created here or supplied."
  value       = local.vnet_id
}

# The depends_on is what makes this subnet safe to consume, and it is not decoration.
#
# API Management refuses to deploy into a subnet that has no network security group:
#
#   NetworkSecurityGroupNotFound: API Management service deployment into SubnetId ... requires a
#   Network Security Group to be associated with it.
#
# A caller that writes `virtual_network_subnet_id = module.network.apim_subnet_id` creates a
# dependency on the subnet alone. The NSG association is a separate resource that nothing downstream
# references, so Terraform is free to create API Management while the association is still in flight,
# and the deployment fails roughly half the time - the worst kind of bug, because re-running appears
# to fix it. Hanging the dependency off the output makes every consumer wait, without any of them
# having to know the rule exists.
output "apim_subnet_id" {
  description = "Subnet to hand to the ai-gateway module as virtual_network_subnet_id. Ordered behind its NSG and NAT gateway associations."
  value       = local.apim_subnet_id

  depends_on = [
    azurerm_subnet_network_security_group_association.apim,
    azurerm_subnet_nat_gateway_association.apim,
  ]
}

output "private_endpoint_subnet_id" {
  description = "Subnet to hand to the foundry-models module for its private endpoints. Ordered behind its NSG association."
  value       = local.pe_subnet_id

  depends_on = [azurerm_subnet_network_security_group_association.private_endpoints]
}

output "private_dns_zone_ids" {
  description = <<-EOT
    All three Foundry private DNS zones, keyed by zone name. Pass the whole map to the foundry-models
    module: a private endpoint needs records in each of them, because which zone answers depends on
    which hostname the caller used.
  EOT
  value       = local.private_dns_zone_ids
}

output "private_dns_zone_ids_list" {
  description = "The same zones as a list, for consumers that take an unkeyed collection."
  value       = values(local.private_dns_zone_ids)
}

output "network_security_group_id" {
  description = "Network security group on the API Management subnet - created here, or the one supplied as existing_apim_nsg_id. Null when the subnet itself was supplied, because its network security group is then the caller's to know about."
  value       = local.create_apim_subnet ? local.apim_nsg_id : null
}

output "private_endpoint_network_security_group_id" {
  description = "Network security group on the private endpoint subnet, on the same basis as above."
  value       = local.create_pe_subnet ? local.pe_nsg_id : null
}

output "nat_gateway_public_ip" {
  description = "Stable outbound address of the gateway, when the NAT gateway is enabled. This is the address to give anyone who needs to allow-list your egress."
  value       = var.enable_nat_gateway && local.create_apim_subnet ? one(azurerm_public_ip.nat[*].ip_address) : null
}

# What this deployment actually owns. Worth printing, because the whole point of the bring-your-own
# fields is that the answer differs between environments, and "who owns this subnet" is the first
# question asked when something needs changing.
output "created_resources" {
  description = "Which parts of the network this module created, as opposed to reused."
  value = {
    virtual_network         = local.create_vnet
    apim_subnet             = local.create_apim_subnet
    private_endpoint_subnet = local.create_pe_subnet
    apim_nsg                = local.create_apim_nsg
    private_endpoint_nsg    = local.create_pe_nsg
    private_dns_zones       = local.dns_zones_to_create
  }
}

# Empty in every supported configuration. Non-empty means Foundry's private endpoints have a zone
# missing and will resolve inconsistently depending on the hostname used, so it is surfaced rather
# than left to be discovered.
output "missing_private_dns_zones" {
  description = "Foundry private DNS zones that will neither be created nor were supplied."
  value       = local.missing_dns_zones
}
