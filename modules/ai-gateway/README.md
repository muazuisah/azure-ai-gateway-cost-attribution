# `ai-gateway` module

Publishes an Azure API Management instance as a centralised entry point for Microsoft Foundry model deployments: load-balanced backend pools with circuit breakers, managed-identity egress, caller authentication, token governance, and an optional per-request chargeback ledger.

This is the reference for the module's inputs and outputs. For *why* it is shaped this way, read [`docs/architecture.md`](../../docs/architecture.md) and the [decision records](../../docs/decisions). For the policy internals, read [`docs/policies.md`](../../docs/policies.md).

---

## Minimal usage

```hcl
module "ai_gateway" {
  source = "github.com/muazuisah/azure-ai-gateway-cost-attribution//modules/ai-gateway"

  resource_group_name = azurerm_resource_group.this.name
  location            = "eastus2"
  name_prefix         = "contoso-ai"

  foundry_backends = {
    primary = {
      inference_url = "https://contoso-aif-eastus2.openai.azure.com"
      deployments   = ["gpt-4o", "text-embedding-3-small"]
    }
  }

  model_routes = {
    "chat" = {
      deployment       = "gpt-4o"
      backend_priority = { primary = 1 }
    }
    "embedding" = {
      deployment       = "text-embedding-3-small"
      backend_priority = { primary = 1 }
    }
  }

  foundry_account_ids = {
    primary = azurerm_cognitive_account.primary.id
  }

  application_insights_id                  = azurerm_application_insights.this.id
  application_insights_instrumentation_key = azurerm_application_insights.this.instrumentation_key
}
```

Clients then call the gateway with a model **alias**, not a deployment name:

```python
client = AzureOpenAI(
    base_url=module_output_openai_base_url,
    api_key="<apim-subscription-key>",
    api_version="2024-10-21",
)
client.chat.completions.create(model="chat", messages=[...])
```

The indirection is the point — see [ADR-0006](../../docs/decisions/0006-alias-routing-vs-unified-model-api.md). Moving `chat` from `gpt-4o` to a newer model is a Terraform change, not a client change.

---

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.9.0 |
| azurerm | >= 5.0.0, < 6.0.0 |
| azapi | >= 2.0.0, < 3.0.0 |
| random | >= 3.6.0 |

`azapi` is required because AzureRM has no resource for APIM backend **pools**. See [ADR-0003](../../docs/decisions/0003-azapi-for-backend-pools.md).

---

## Inputs

### Required

| Name | Type | Description |
|---|---|---|
| `resource_group_name` | `string` | Resource group to deploy into. |
| `location` | `string` | Azure region. |
| `name_prefix` | `string` | Prefix for generated resource names. The APIM instance becomes `<prefix>-apim`. |
| `foundry_backends` | `map(object)` | Foundry endpoints to front. See below. |
| `model_routes` | `map(object)` | Client-facing aliases and the deployment each resolves to. See below. |
| `application_insights_id` | `string` | Application Insights resource for telemetry. |
| `application_insights_instrumentation_key` | `string` | Instrumentation key for the same resource. |

### Instance

| Name | Type | Default | Description |
|---|---|---|---|
| `existing_api_management_id` | `string` | `null` | Adopt an existing APIM instance instead of creating one. When set, instance-level inputs below are ignored. |
| `apim_sku_name` | `string` | `"StandardV2_1"` | APIM SKU. The v2 tiers deploy in minutes rather than hours and support outbound VNet integration. |
| `publisher_name` | `string` | `"AI Platform Team"` | Required by APIM. |
| `publisher_email` | `string` | `null` | Required by APIM when creating an instance. |
| `environment_name` | `string` | `"dev"` | Label used in workbook titles and alert descriptions. |
| `tags` | `map(string)` | `{}` | Tags applied to created resources. |

### Networking

| Name | Type | Default | Description |
|---|---|---|---|
| `virtual_network_type` | `string` | `"None"` | `None`, `External`, or `Internal`. |
| `virtual_network_subnet_id` | `string` | `null` | Subnet for VNet integration. |
| `public_network_access_enabled` | `bool` | `true` | Disable for a private-only gateway. |
| `disable_legacy_tls` | `bool` | `true` | Turns off TLS 1.0/1.1 and weak ciphers. Leave enabled unless a legacy client forces otherwise. |

### Backends and routing

| Name | Type | Default | Description |
|---|---|---|---|
| `foundry_account_ids` | `map(string)` | `{}` | Foundry account resource IDs keyed by backend name. The module grants its managed identity **Cognitive Services User** on each. Leave empty if role assignments are managed by a platform team. |
| `enforce_deployment_parity` | `bool` | `true` | Validates at plan time that every alias resolves to a deployment present on **every** backend in its pool. |
| `circuit_breaker` | `object` | `{}` | Trip conditions and duration. |
| `api_path` | `string` | `"openai/v1"` | Path the API is published under. |
| `enable_responses_api` | `bool` | `true` | Publish the Responses API operations alongside chat completions. |
| `forward_timeout_seconds` | `number` | `240` | Backend timeout. Generous by default because long completions are legitimately slow. |
| `buffer_response` | `bool` | `false` | Leave `false` to preserve token-by-token streaming. |
| `backend_auth_resource` | `string` | `"https://cognitiveservices.azure.com"` | Audience the gateway requests its managed-identity token for. |

#### `foundry_backends`

```hcl
foundry_backends = {
  primary = {
    inference_url = "https://contoso-aif-eastus2.openai.azure.com"  # https, no path, no trailing slash
    deployments   = ["gpt-4o", "gpt-4o-mini"]
    description   = optional(string)
  }
}
```

`inference_url` is validated against `^https://[^/]+$`. Plaintext is rejected.

#### `model_routes`

```hcl
model_routes = {
  "chat" = {
    deployment = "gpt-4o" # must exist on every backend listed below

    # Backend key -> priority group (1 is highest). Every member of a group is
    # used before a lower group is touched, and a lower group is only reached
    # once every higher member's circuit breaker has tripped. Reserved (PTU)
    # capacity in group 1 and pay-as-you-go in group 2 gives you automatic
    # spillover.
    backend_priority = { eastus-ptu = 1, eastus-std = 2, westeurope-std = 3 }

    # Optional relative weight *within* a priority group.
    backend_weight = { eastus-std = 70, westeurope-std = 30 }

    description = "General-purpose chat" # optional; shown in the portal and /models
  }
}
```

| Field | Type | Required |
|---|---|---|
| `deployment` | `string` | yes |
| `backend_priority` | `map(number)` | yes — at least one entry, values `0`–`100` |
| `backend_weight` | `map(number)` | no, defaults to `{}` |
| `description` | `string` | no |

**Deployment-name parity** is the constraint that makes pools work: APIM routes to a pool member without rewriting the path, so the deployment name must be identical across members. `enforce_deployment_parity` catches a mismatch at plan time rather than as intermittent 404s under failover. See [ADR-0001](../../docs/decisions/0001-native-backend-pools.md).

### Caller authentication

| Name | Type | Default |
|---|---|---|
| `caller_authentication` | `object` | `{}` (equivalent to `mode = "subscription_key"`) |

```hcl
caller_authentication = {
  mode                   = "both"          # subscription_key | entra_id | both
  tenant_id              = "<tenant-guid>"
  audiences              = ["api://ai-gateway"]
  client_application_ids = ["<app-guid>"]
  claim_order            = ["appid", "azp", "oid"]
  tokens_per_minute      = 100000
}
```

At least one of `audiences` or `client_application_ids` is **required** in `entra_id` and `both` modes. Validating only the tenant and signature accepts any token Entra issued for any application in that tenant — a confused-deputy vulnerability. The module refuses to plan without one.

> **`entra_id` mode removes a governance tier.** APIM resolves the *product* from the subscription key. With no key there is no product, and product-scope policy **does not execute at all** — so per-product token limits and model entitlement are unavailable. The module applies `tokens_per_minute` gateway-wide instead, and fails the plan if `products` declare controls that would be silently ignored. See [ADR-0007](../../docs/decisions/0007-entra-id-caller-authentication.md).

### Products and subscriptions

| Name | Type | Default | Description |
|---|---|---|---|
| `products` | `map(object)` | `{}` | Product tiers carrying token limits and model entitlement. |
| `subscriptions` | `map(object)` | `{}` | Consuming applications and the product each belongs to. |

Both are inert in `entra_id` mode, by the mechanism described above.

### Telemetry

| Name | Type | Default | Description |
|---|---|---|---|
| `log_analytics_workspace_id` | `string` | `null` | Workspace that receives GatewayLogs and metrics. Required when `enable_diagnostics` is true. |
| `enable_diagnostics` | `bool` | `false` | Creates the API Management diagnostic setting. Separate from the workspace id on purpose — see below. |
| `diagnostic_sampling_percentage` | `number` | `100` | **Leave at 100 if you use the chargeback ledger.** Sampling discards requests, and a sampled ledger under-reports silently. |
| `metric_namespace` | `string` | `"aigateway"` | Namespace for `llm-emit-token-metric` output. |
| `log_request_and_response_bodies` | `bool` | `false` | Logs prompt and completion **content**. Review retention, access and regional requirements before enabling. |

### Content safety

| Name | Type | Default |
|---|---|---|
| `enable_content_safety` | `bool` | `false` |
| `content_safety_endpoint` | `string` | `null` (validated as https) |
| `content_safety_shield_prompt` | `bool` | `true` |
| `content_safety_max_characters` | `number` | `10000` |
| `content_safety_thresholds` | `object` | `{}` |

### Semantic cache

| Name | Type | Default |
|---|---|---|
| `enable_semantic_cache` | `bool` | `false` |
| `semantic_cache_redis_connection_string` | `string` | `null` |
| `semantic_cache_embeddings_deployment` | `string` | `"text-embedding-3-small"` |
| `semantic_cache_embeddings_backend` | `string` | `null` |
| `semantic_cache_settings` | `object` | `{}` |

Cache hits are marked explicitly in telemetry (`cacheHit=true`, `estimatedCostUSD=0`) so they appear as savings rather than quietly distorting attribution.

### Cost attribution

| Name | Type | Default |
|---|---|---|
| `enable_cost_attribution` | `bool` | `false` |
| `pricing_map` | `any` | `{}` |
| `pricing_effective_date` | `string` | `null` |
| `enable_eventhub_audit` | `bool` | `false` |
| `eventhub_sku` | `string` | `"Standard"` |
| `eventhub_partition_count` | `number` | `4` |
| `eventhub_retention_days` | `number` | `7` |

```hcl
pricing_map = {
  "gpt-4o" = { unit = 1000000, input = 2.50, cachedInput = 1.25, output = 10.00 }
  "gpt-5-5" = {
    unit = 1000000, input = 5.00, cachedInput = 0.50, output = 30.00
    contextTiers = [
      { name = "long", minPromptTokens = 272001, input = 10.00, cachedInput = 1.00, output = 45.00 }
    ]
  }
}
```

Generate it rather than typing it:

```bash
python scripts/generate_pricing_map.py --region eastus2 --alias chat=gpt-4o --format hcl
```

An unknown model prices at `-1` ("unpriced"), never `0` — a zero would be indistinguishable from a free request and would quietly understate the bill. See [ADR-0008](../../docs/decisions/0008-context-length-pricing-tiers.md) for context-length tiers.

`pricing_effective_date` is the date stamped on every priced request, so a chargeback number can be traced back to the rates that produced it. Left `null` it is the newest `effectiveDate` among the `pricing_map` entries, which is what the generator writes. It must not be derived from the clock: a value that changes on every plan forces a choice between permanent plan noise and ignoring changes to the named value, and ignoring them means a regenerated rate table produces no diff and never reaches the gateway.

The module strips each entry's `source` block before writing the named value. A named value caps at **4096 characters**, and provenance is roughly a third of each entry — so it stays in your tfvars where a reviewer can read it, and off the gateway where the policy never looks at it. The limit is checked at plan time rather than left to fail mid-apply with an error that names neither the cap nor the resource.

`enable_eventhub_audit` adds a `log-to-eventhub` element that writes the same ledger record, unsampled, as one JSON object per request, alongside a namespace, hub, logger and the Data Sender role assignment. It requires `enable_cost_attribution`, since the ledger is what it carries. It lives on this module rather than cost-attribution because a policy cannot name a logger that does not exist yet, so the two must be created in the same dependency graph. Event Hub is a buffer rather than an archive — land the stream somewhere durable inside `eventhub_retention_days`.

---

## Outputs

| Name | Description |
|---|---|
| `api_management_id` | Resource ID of the APIM instance. |
| `api_management_name` | Name of the APIM instance. |
| `gateway_url` | Base gateway URL. |
| `openai_base_url` | Base URL to hand to an OpenAI-compatible client. |
| `principal_id` | Object ID of the gateway's system-assigned managed identity. Grant it **Cognitive Services User** on any Foundry account not passed in `foundry_account_ids`. |
| `api_name`, `api_id` | The published LLM API. |
| `model_aliases` | Client-facing aliases served by the gateway. |
| `backend_pool_ids`, `backend_ids` | Pool and backend resource IDs. |
| `products` | Published product tiers with their token governance. |
| `subscription_keys` | **Sensitive.** Keys per consuming application. |
| `subscription_ids` | Subscription resource IDs. |
| `application_insights_id` | Telemetry sink — pass this to the `cost-attribution` module. |
| `metric_namespace` | Custom metric namespace. |
| `cost_attribution_enabled` | Whether the chargeback ledger is being emitted. |
| `routes_named_value_name` | Named value holding the base64 route table. **Change models here, not in policy.** |
| `pricing_named_value_name` | Named value holding the base64 pricing map. |

---

## Notes

**Managed identity only.** The gateway authenticates outbound to Foundry with its system-assigned identity. No model API key exists in state, in named values, or in Key Vault. The cost is a first-apply race: role assignments take time to propagate, so an immediate smoke test can return 401 before RBAC has caught up. See [ADR-0002](../../docs/decisions/0002-managed-identity-only.md).

**Editing policy.** `templatefile()` is evaluated at plan time, so `terraform validate` never renders the policy templates and cannot see malformed XML in them. After any `.tftpl` edit, run:

```powershell
./scripts/check_policies.ps1
```

[`docs/policies.md`](../../docs/policies.md) documents the authoring rules — in particular that an apostrophe inside a single-quoted policy attribute terminates it, producing an error that looks nothing like its cause.

**Not yet deployment-tested.** The modules validate, the policies render, and the test suite passes, but this has not been applied against a live subscription. Treat a first deployment as a genuine test and please report what differs.

### Why `enable_diagnostics` is separate from `log_analytics_workspace_id`

It would read better to create the diagnostic setting whenever a workspace id is supplied, and that is
how this module was originally written. It does not work.

The workspace is almost always created by the same root module that calls this one, so its id is
unknown until apply. Terraform resolves `count` and `for_each` during planning, and it cannot decide
how many instances an unknown value produces, so it refuses to plan at all:

```
Error: Invalid count argument
The "count" value depends on resource attributes that cannot be determined until apply.
```

A bool the caller writes literally is always known, so the graph stays plannable in a single pass no
matter where the workspace comes from. A precondition catches the mismatched case — `enable_diagnostics`
on with no workspace id — at apply time, with an error that says which one to change.

The same reasoning applies to `enable_private_endpoints` and `enable_diagnostics` in the
`foundry-models` module. It is worth remembering as a general rule: **never gate `count` or `for_each`
on whether another resource's attribute is null.**