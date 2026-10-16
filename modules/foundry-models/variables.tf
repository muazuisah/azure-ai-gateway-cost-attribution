variable "resource_group_name" {
  description = "Name of the resource group that will hold the Foundry accounts."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every generated resource name. Keep it short; Foundry account names are limited to 64 characters and must be globally unique when a custom subdomain is used."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix must be 2-21 characters, lowercase alphanumeric or hyphen, and start with a letter or digit."
  }
}

variable "accounts" {
  description = <<-EOT
    Foundry accounts (Microsoft.CognitiveServices/accounts, kind = AIServices) to create, keyed by a short
    logical name such as "eastus-std" or "eastus-ptu".

    Every account receives the full `model_deployments` set by default. That deployment-name parity is what
    allows a single APIM backend pool to serve a single model alias, so deviate from it only deliberately
    via `excluded_deployments`.

    * location              - Azure region for the account.
    * sku_name              - Cognitive Services SKU. "S0" is the only generally available option.
    * custom_subdomain_name - Optional explicit subdomain. Defaults to "<name_prefix>-<key>". A custom
                              subdomain is mandatory for Entra ID (managed identity) authentication and
                              for private endpoints.
    * public_network_access_enabled - Set false when fronting the account with a private endpoint.
    * excluded_deployments  - Deployment keys this account must NOT host. Breaks pool parity; see README.
    * deployment_overrides  - Per-account SKU/capacity overrides, e.g. reserved (PTU) capacity in one region
                              and pay-as-you-go elsewhere.
  EOT

  type = map(object({
    location                      = string
    sku_name                      = optional(string, "S0")
    custom_subdomain_name         = optional(string)
    public_network_access_enabled = optional(bool, true)
    excluded_deployments          = optional(list(string), [])
    deployment_overrides = optional(map(object({
      sku_name = optional(string)
      capacity = optional(number)
    })), {})
    tags = optional(map(string), {})
  }))

  validation {
    condition     = length(var.accounts) > 0
    error_message = "At least one Foundry account must be defined."
  }

  validation {
    condition     = alltrue([for k, v in var.accounts : can(regex("^[a-z0-9][a-z0-9-]{1,30}$", k))])
    error_message = "Account keys must be 2-31 characters, lowercase alphanumeric or hyphen."
  }
}

variable "model_deployments" {
  description = <<-EOT
    Model deployments created on every account, keyed by the physical deployment name that APIM will place
    in the request path. Keys are the contract between this module and the ai-gateway module.

    * model_name    - Publisher model name, e.g. "gpt-4o", "text-embedding-3-large", "Mistral-Large-2411".
    * model_format  - Publisher. "OpenAI" for Azure OpenAI models, "Mistral AI", "Meta", "Microsoft", etc.
    * model_version - Publisher model version. Pin it; "latest" makes cost and behaviour unpredictable.
    * sku_name      - Deployment SKU: GlobalStandard, Standard, DataZoneStandard, GlobalProvisionedManaged,
                      ProvisionedManaged. Use DataZoneStandard where data residency is constrained.
    * capacity      - Units of the chosen SKU. For Standard SKUs this is thousands of tokens per minute.
  EOT

  type = map(object({
    model_name                 = string
    model_format               = optional(string, "OpenAI")
    model_version              = string
    sku_name                   = optional(string, "GlobalStandard")
    capacity                   = optional(number, 10)
    rai_policy_name            = optional(string)
    version_upgrade_option     = optional(string, "OnceCurrentVersionExpired")
    dynamic_throttling_enabled = optional(bool, false)
  }))

  validation {
    condition = alltrue([
      for k, v in var.model_deployments :
      contains(["GlobalStandard", "Standard", "DataZoneStandard", "GlobalProvisionedManaged", "ProvisionedManaged", "GlobalBatch", "DataZoneBatch"], v.sku_name)
    ])
    error_message = "sku_name must be one of GlobalStandard, Standard, DataZoneStandard, GlobalProvisionedManaged, ProvisionedManaged, GlobalBatch, DataZoneBatch."
  }

  validation {
    condition     = alltrue([for k, v in var.model_deployments : v.model_version != "latest"])
    error_message = "Pin model_version to an explicit publisher version. Using 'latest' makes cost and behaviour change without a Terraform diff."
  }

  validation {
    condition = alltrue([
      for k, v in var.model_deployments :
      contains(["OnceNewDefaultVersionAvailable", "OnceCurrentVersionExpired", "NoAutoUpgrade"], v.version_upgrade_option)
    ])
    error_message = "version_upgrade_option must be OnceNewDefaultVersionAvailable, OnceCurrentVersionExpired, or NoAutoUpgrade."
  }
}

variable "local_auth_enabled" {
  description = "Whether key-based authentication is permitted on the Foundry accounts. Leave false so that managed identity is the only possible access path."
  type        = bool
  default     = false
}

variable "gateway_principal_ids" {
  description = "Object IDs of the principals (normally the API Management managed identity) granted data-plane access to every Foundry account."
  type        = list(string)
  default     = []
}

variable "data_plane_role" {
  description = "Built-in role granted to gateway_principal_ids. 'Cognitive Services User' covers inference across Foundry model families; 'Cognitive Services OpenAI User' is narrower and covers only Azure OpenAI."
  type        = string
  default     = "Cognitive Services User"

  validation {
    condition     = contains(["Cognitive Services User", "Cognitive Services OpenAI User"], var.data_plane_role)
    error_message = "data_plane_role must be 'Cognitive Services User' or 'Cognitive Services OpenAI User'."
  }
}

variable "private_endpoint_subnet_id" {
  description = "Subnet resource ID for Foundry private endpoints. Required when enable_private_endpoints is true, and ignored otherwise."
  type        = string
  default     = null
}

variable "private_endpoint_location" {
  description = <<-EOT
    Region the private endpoints are created in. This must be the region of
    private_endpoint_subnet_id, because a private endpoint occupies a subnet and a subnet belongs to
    exactly one region.

    Leave it null for a single-region deployment and each endpoint is created alongside its account.
    Set it whenever accounts span regions but share one virtual network: the endpoints then all sit
    in the network's region and target the accounts across regions, which is supported and is the
    normal topology for multi-region Foundry behind a single network.
  EOT
  type        = string
  default     = null
}

variable "enable_private_endpoints" {
  description = <<-EOT
    Whether to place a private endpoint in front of each Foundry account, removing its public
    endpoint from the data path.

    This is a separate flag rather than being inferred from private_endpoint_subnet_id because the
    subnet is normally created in the same apply as these accounts, which makes its id unknown at plan
    time. Terraform cannot derive for_each keys from an unknown value and refuses to plan. A literal
    bool is always known, so the configuration stays plannable in a single pass.
  EOT
  type        = bool
  default     = false
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    Private DNS zone resource IDs to associate with the Foundry private endpoints.

    Supply all three zones. A Foundry account answers on cognitiveservices, openai, and services.ai
    hostnames, and omitting any one of them produces intermittent resolution failures that are
    unpleasant to diagnose:
      privatelink.cognitiveservices.azure.com
      privatelink.openai.azure.com
      privatelink.services.ai.azure.com
  EOT
  type        = list(string)
  default     = []
}

variable "diagnostics_workspace_id" {
  description = "Log Analytics workspace resource ID for Foundry diagnostic settings. Required when enable_diagnostics is true, and ignored otherwise."
  type        = string
  default     = null
}

variable "enable_diagnostics" {
  description = <<-EOT
    Whether to create diagnostic settings on the Foundry accounts, sending Audit, RequestResponse and
    all metrics to diagnostics_workspace_id.

    This is a separate flag rather than being inferred from diagnostics_workspace_id because the
    workspace is normally created in the same apply as these accounts, which makes its id unknown at
    plan time. Terraform cannot build for_each keys from an unknown value and refuses to plan. A
    literal bool is always known, so the configuration stays plannable in a single pass.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

variable "projects" {
  description = <<-EOT
    Foundry projects to create on these accounts. Empty by default: a project is not needed to serve
    inference through the gateway, which is what this accelerator exists to do, and the account plus
    its deployments is the whole surface APIM talks to.

    Create one when you need the things that hang off a project rather than an account: the
    project-scoped endpoint that the Foundry SDK and portal expect
    (https://<subdomain>.services.ai.azure.com/api/projects/<name>), Agent Service threads, evaluations,
    or connections to AI Search and Storage.

    * account_key  - Key from `accounts`. The project is created on that account and inherits its region.
    * display_name - Name shown in the Foundry portal. Defaults to the project key.
    * is_default   - Marks this project as the account's default. At most one per account.
  EOT
  type = map(object({
    account_key  = string
    display_name = optional(string)
    description  = optional(string)
    is_default   = optional(bool, false)
    tags         = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for key, project in var.projects : contains(keys(var.accounts), project.account_key)])
    error_message = "Every projects[*].account_key must match a key in `accounts`."
  }

  validation {
    condition = alltrue([
      for account_key in distinct([for project in var.projects : project.account_key]) :
      length([for project in var.projects : project if project.account_key == account_key && project.is_default]) <= 1
    ])
    error_message = "At most one project per account can set is_default = true."
  }
}

variable "connections" {
  description = <<-EOT
    Connections from a Foundry account to other Azure resources, so projects on that account can reach
    AI Search, Storage or Cosmos DB. Authentication is Entra ID using the account's managed identity,
    which is why no key or connection string appears here and none is stored in state.

    Creating the connection does not grant access. The account's principal still needs a role on the
    target - `Search Index Data Reader` on a search service, `Storage Blob Data Contributor` on an
    account - which the caller assigns using the `accounts[*].principal_id` output.

    * category - Connection type as ARM names it, e.g. AzureAISearch, AzureBlob, CosmosDB.
    * target   - Endpoint of the resource being connected, not its ARM id.
    * metadata - Extra properties some categories require, e.g. ApiType or ResourceId.
  EOT
  type = map(object({
    account_key = string
    category    = string
    target      = string
    metadata    = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for key, conn in var.connections : contains(keys(var.accounts), conn.account_key)])
    error_message = "Every connections[*].account_key must match a key in `accounts`."
  }
}
