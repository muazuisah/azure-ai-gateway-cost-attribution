locals {
  # Cartesian product of accounts x deployments, minus explicit exclusions.
  # Per-account overrides let one region carry reserved (PTU) capacity while others stay pay-as-you-go,
  # without breaking the deployment-name parity that APIM backend pools depend on.
  account_deployments = {
    for pair in flatten([
      for account_key, account in var.accounts : [
        for deployment_key, deployment in var.model_deployments : {
          composite_key  = "${account_key}/${deployment_key}"
          account_key    = account_key
          deployment_key = deployment_key
          deployment = merge(deployment, {
            sku_name = try(account.deployment_overrides[deployment_key].sku_name, null) != null ? account.deployment_overrides[deployment_key].sku_name : deployment.sku_name
            capacity = try(account.deployment_overrides[deployment_key].capacity, null) != null ? account.deployment_overrides[deployment_key].capacity : deployment.capacity
          })
        }
        if !contains(account.excluded_deployments, deployment_key)
      ]
    ]) : pair.composite_key => pair
  }

  # Deployment names each account actually hosts. The ai-gateway module consumes this to verify that
  # every backend in a pool can serve the alias routed to it.
  deployments_by_account = {
    for account_key, account in var.accounts :
    account_key => sort([
      for deployment_key, _ in var.model_deployments : deployment_key
      if !contains(account.excluded_deployments, deployment_key)
    ])
  }

  # Keyed off a literal bool rather than `private_endpoint_subnet_id != null`. The subnet is normally
  # created in the same apply as these accounts, so its id is unknown at plan time, and Terraform
  # cannot derive for_each keys from an unknown value - it refuses to plan at all.
  private_endpoints_enabled = var.enable_private_endpoints

  # ARM rejects project creation with "Project can only created under AIServices Kind account with
  # allowProjectManagement set to true", and the flag lives on the account rather than the project.
  # Deriving it from `projects` instead of exposing a second switch means the two cannot be set
  # inconsistently: asking for a project is what enables the capability on the account hosting it.
  accounts_with_projects = toset([for project in var.projects : project.account_key])
}

resource "azurerm_cognitive_account" "this" {
  for_each = var.accounts

  # checkov:skip=CKV_AZURE_134:Public network access is a per-account input, not a hardcoded value. The
  # quickstart example leaves it enabled so the example is reachable without a jump host; the production
  # example disables it and fronts the account with a private endpoint. Enforced by the caller, not here.
  # checkov:skip=CKV2_AZURE_22:Encryption at rest with a customer-managed key is supported via the
  # customer_managed_key block but not imposed. CMK requires a Key Vault with purge protection and an
  # access policy for this account's identity; making that mandatory would force every adopter to stand
  # up key infrastructure for a quickstart. Platform-managed keys remain encrypted at rest.

  name                = "${var.name_prefix}-aif-${each.key}"
  location            = each.value.location
  resource_group_name = var.resource_group_name

  # kind = "AIServices" is the current Foundry resource. It serves Azure OpenAI models and the wider
  # Foundry model catalogue from one account, unlike the legacy kind = "OpenAI".
  kind     = "AIServices"
  sku_name = each.value.sku_name

  # Only on for accounts that actually host a project, so an inference-only account keeps the
  # smaller surface area.
  project_management_enabled = contains(local.accounts_with_projects, each.key)

  # A custom subdomain is mandatory for Entra ID token authentication and for private endpoints.
  custom_subdomain_name = coalesce(each.value.custom_subdomain_name, "${var.name_prefix}-aif-${each.key}")

  local_auth_enabled                 = var.local_auth_enabled
  public_network_access_enabled      = each.value.public_network_access_enabled
  outbound_network_access_restricted = false

  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, each.value.tags, {
    "accelerator-component" = "foundry-models"
    "accelerator-role"      = each.key
  })

  lifecycle {
    # Deployments are managed as separate resources; drift in the account's computed model list is expected.
    ignore_changes = [tags["created-by"]]
  }
}

resource "azurerm_cognitive_deployment" "this" {
  for_each = local.account_deployments

  name                 = each.value.deployment_key
  cognitive_account_id = azurerm_cognitive_account.this[each.value.account_key].id

  rai_policy_name            = each.value.deployment.rai_policy_name
  version_upgrade_option     = each.value.deployment.version_upgrade_option
  dynamic_throttling_enabled = each.value.deployment.dynamic_throttling_enabled

  model {
    format  = each.value.deployment.model_format
    name    = each.value.deployment.model_name
    version = each.value.deployment.model_version
  }

  sku {
    name     = each.value.deployment.sku_name
    capacity = each.value.deployment.capacity
  }

  # Creating several deployments on one account in parallel intermittently returns conflict errors.
  # Serialising per account keeps apply deterministic.
  depends_on = [azurerm_cognitive_account.this]
}

# ---------------------------------------------------------------------------------------------------
# Data-plane RBAC for the gateway identity.
# This is what makes keyless access possible; combined with local_auth_enabled = false it makes
# key-based access impossible.
# ---------------------------------------------------------------------------------------------------

resource "azurerm_role_assignment" "gateway_data_plane" {
  for_each = {
    for pair in flatten([
      for account_key, _ in var.accounts : [
        for principal_id in var.gateway_principal_ids : {
          key          = "${account_key}/${principal_id}"
          account_key  = account_key
          principal_id = principal_id
        }
      ]
    ]) : pair.key => pair
  }

  scope                = azurerm_cognitive_account.this[each.value.account_key].id
  role_definition_name = var.data_plane_role
  principal_id         = each.value.principal_id

  # APIM's system-assigned identity is a service principal; skipping the graph lookup avoids
  # replication-delay failures immediately after the identity is created.
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------------------------------------
# Private endpoints
# ---------------------------------------------------------------------------------------------------

resource "azurerm_private_endpoint" "this" {
  for_each = local.private_endpoints_enabled ? var.accounts : {}

  name = "${var.name_prefix}-pe-aif-${each.key}"

  # A private endpoint lives in the region of the subnet it occupies, NOT in the region of the
  # resource it fronts. Those are usually the same and the difference never shows up - until a
  # multi-region deployment puts a Foundry account in a second region and the apply fails with
  # "InvalidResourceReference: ... was not found. Please make sure that the referenced resource
  # exists, and that both resources are in the same region."
  #
  # Targeting across regions is supported and is exactly how several Foundry accounts sit behind one
  # virtual network: the endpoints all land in the VNet's region and reach out to wherever the
  # accounts are. Callers with a single-region deployment can leave this null and get the old
  # behaviour.
  location            = coalesce(var.private_endpoint_location, each.value.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.name_prefix}-psc-aif-${each.key}"
    private_connection_resource_id = azurerm_cognitive_account.this[each.key].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) > 0 ? [1] : []
    content {
      name                 = "default"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }

  tags = merge(var.tags, {
    "accelerator-component" = "foundry-models"
  })

  lifecycle {
    precondition {
      condition     = var.private_endpoint_subnet_id != null
      error_message = "enable_private_endpoints is true but private_endpoint_subnet_id is null. Supply the subnet, or set enable_private_endpoints = false."
    }
  }
}

# ---------------------------------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------------------------------

#
# The for_each keys off a dedicated flag rather than `diagnostics_workspace_id != null`, because the
# workspace is usually created by the same root module that calls this one. Its id is then unknown at
# plan time, and Terraform cannot derive instance keys from an unknown value - it refuses to plan at
# all. A bool the caller sets literally is always known, so the graph stays plannable in one pass.
resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each = var.enable_diagnostics ? var.accounts : {}

  name                       = "diag-to-law"
  target_resource_id         = azurerm_cognitive_account.this[each.key].id
  log_analytics_workspace_id = var.diagnostics_workspace_id

  enabled_log {
    category = "Audit"
  }

  enabled_log {
    category = "RequestResponse"
  }

  enabled_metric {
    category = "AllMetrics"
  }

  lifecycle {
    precondition {
      condition     = var.diagnostics_workspace_id != null
      error_message = "enable_diagnostics is true but diagnostics_workspace_id is null. Set the workspace id, or set enable_diagnostics = false."
    }
  }
}

# ------------------------------------------------------------------------------------------------
# Foundry projects
#
# A project is the workspace construct: it owns the project-scoped endpoint the Foundry SDK and
# portal use, and it is what Agent Service, evaluations and connections attach to. Inference does
# not need one, so none is created unless asked for.
# ------------------------------------------------------------------------------------------------
resource "azurerm_cognitive_account_project" "this" {
  for_each = var.projects

  name                 = "${var.name_prefix}-proj-${each.key}"
  cognitive_account_id = azurerm_cognitive_account.this[each.value.account_key].id

  # A project lives in its account's region. Taking the location from the created account rather
  # than from input keeps the two from drifting apart.
  location = azurerm_cognitive_account.this[each.value.account_key].location

  display_name = coalesce(each.value.display_name, each.key)
  description  = each.value.description

  # Its own identity, separate from the account's, so access a project needs for its connections can
  # be granted to the project rather than to every project on the account.
  identity {
    type = "SystemAssigned"
  }

  tags = merge(var.tags, each.value.tags, {
    "accelerator-component" = "foundry-models"
    "accelerator-role"      = "project"
  })
}

# ------------------------------------------------------------------------------------------------
# Connections to other Azure resources
#
# Entra ID only. The key-based variants of this resource exist, and using one would put a secret in
# state and leave a credential to rotate; the managed identity the account already has removes both
# problems. Access still has to be granted on the target resource - see the variable description.
# ------------------------------------------------------------------------------------------------
resource "azurerm_cognitive_account_connection_entra_id" "this" {
  for_each = var.connections

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.this[each.value.account_key].id

  category = each.value.category
  target   = each.value.target
  metadata = each.value.metadata
}
