# Example 02 — Production, private networking

The full topology: two Foundry regions behind backend pools with circuit breakers, API Management injected into a VNet, Foundry reachable only over private endpoints, content safety in line, Entra ID caller authentication, and chargeback on top.

Pick this one when the gateway is going to carry real traffic. It is the same module code as [example 01](../01-quickstart/) — the difference is the variables, not a rewrite — but it is a materially larger and more expensive deployment, and it assumes you have somewhere to run it from that can reach a private endpoint.

## What this deploys

| Module | What it creates here |
|---|---|
| [`networking`](../../modules/networking/) | VNet, an API Management subnet, a private endpoint subnet, the three Foundry private DNS zones, and optionally a NAT gateway for a stable egress address. |
| [`observability`](../../modules/observability/) | Log Analytics workspace and Application Insights. |
| [`foundry-models`](../../modules/foundry-models/) | **Two** accounts — `primary` and `secondary` — each with `public_network_access_enabled = false`, reached over private endpoints. Three deployments per account: `gpt-4.1`, `gpt-4.1-mini`, `text-embedding-3-large`. |
| [`ai-gateway`](../../modules/ai-gateway/) | API Management in the VNet, three aliases over backend pools, circuit breakers, three products, content safety, and the gateway policy. |
| [`cost-attribution`](../../modules/cost-attribution/) | Chargeback workbook, Cost Management budget, and the alert rules. |

### Deployment parity is load-bearing

Both accounts deploy **identical deployment names**. This is not tidiness. A backend pool treats its members as interchangeable, so a deployment present in one region and missing from the other becomes a 404 that only appears when load balancing happens to pick the wrong one — intermittently, under load, in production. The gateway module checks this at plan time and refuses rather than letting you find out later.

### Routing

| Alias | Deployment | Behaviour |
|---|---|---|
| `chat` | `gpt-4.1` | Primary first; secondary only once the primary's breaker trips. |
| `chat-fast` | `gpt-4.1-mini` | Both regions active, weighted 70/30. |
| `embed` | `text-embedding-3-large` | Primary first, secondary on failover. |

The circuit breaker trips after 5 failures in a minute across status codes 429–599, and **honours `Retry-After`**. Foundry answers a throttle with a `Retry-After` that can run to hours; honouring it is what stops the gateway queueing behind a backend that has already said no.

### Products

| Product | Tokens/minute | Monthly quota | Models |
|---|---|---|---|
| `internal-apps` | 200,000 | 500,000,000 | all |
| `agents` | 50,000 | 50,000,000 | `chat-fast`, `embed` only |
| `evaluation` | 30,000 | 20,000,000 | all |

Agents are capped hardest on purpose. An agent loop is the most effective way to spend a month's budget in an afternoon.

### Caller authentication

`caller_authentication.mode` is **`both`** when you supply `caller_tenant_id`, and degrades to `subscription_key` when you do not — so the example still applies end-to-end for someone evaluating it before they have an app registration.

`both` is deliberate rather than a halfway house. The subscription key is what lets APIM resolve the **product**, and the product carries the token limits and the `allowed_models` entitlement above; drop the key and all of that silently disarms. The Entra token is what the chargeback ledger attributes spend to, because an app registration cannot be copied into a second service the way a key can. See [ADR-0007](../../docs/decisions/0007-entra-id-caller-authentication.md).

## Prerequisites

- Terraform **>= 1.9.0**, `hashicorp/azurerm` **>= 5.0.0, < 6.0.0**, `Azure/azapi` **>= 2.0.0, < 3.0.0**.
- An Azure subscription, and rights to create VNets, private endpoints, private DNS zones, API Management, Cognitive Services and Log Analytics.
- **`Microsoft.Authorization/roleAssignments/write`** on the resource group. The gateway grants its own identity `Cognitive Services User` on both Foundry accounts.
- Both `primary_location` and `secondary_location` must carry all three models. Regional model availability is the most common reason this example fails on first apply.
- **Network reachability.** Foundry has public access disabled and API Management may be internal, depending on `apim_virtual_network_type`. You need a path to it — a jumpbox, a VPN, ExpressRoute, or peering from wherever you test.
- If your private DNS zones are owned centrally, name them in `existing_private_dns_zone_ids` and they will be reused rather than created. The decision is made per zone, so naming one and letting the other two be created is fine. A duplicate zone in a spoke breaks resolution estate-wide, which is a much larger incident than a failed apply.
- The same applies to the rest of the network. `existing_virtual_network_id`, `existing_apim_subnet_id`, `existing_private_endpoint_subnet_id`, `existing_apim_nsg_id` and `existing_private_endpoint_nsg_id` are each decided on their own: leave one blank and it is created, fill it in and it is reused. Supplying the virtual network alone is the common case — subnets are still carved inside it unless you supply those too.
- Observability follows the same rule. `existing_log_analytics_workspace_id` and `existing_application_insights_id` are decided independently: leave one blank and it is created, supply a resource ID and it is reused. The workspace is usually a platform-team resource, so reuse is the normal answer. Two things about a supplied Application Insights component cannot be fixed from here — it must be workspace-based, and its sampling must be 100%. Sampling silently drops telemetry, and a dropped record is a missing chargeback row, so a sampled component understates spend without ever reporting an error.
- A subnet you supply is used exactly as it is. Nothing is attached to it, so it must already have a network security group, and on the v2 tiers it must be delegated to `Microsoft.Web/serverFarms`. Both are checked at plan time; without the check the first shows up as `NetworkSecurityGroupNotFound` well into the apply.

## Usage

```bash
cd examples/02-production-private
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

## Inputs you must set

Only one variable has no default:

| Name | Type | Why |
|---|---|---|
| `publisher_email` | `string` | Publisher email for API Management. Azure sends service notifications here, so use a monitored address. |

In practice you should also set, even though they have defaults: `name_prefix`, `primary_location`, `secondary_location`, `apim_sku_name`, `apim_virtual_network_type`, the address space variables, `subscriptions`, `pricing_map`, and the `caller_*` variables if you want Entra authentication. Read `terraform.tfvars.example` — it is annotated and is the intended starting point.

`pricing_map` deserves particular attention: generate it rather than typing it.

```bash
python ../../scripts/generate_pricing_map.py --region eastus2 --alias chat=gpt-4.1 --format hcl
```

## Outputs

| Name | Description |
|---|---|
| `openai_base_url` | Base URL for OpenAI-compatible clients. |
| `model_aliases` | Aliases callers may put in the `model` field. |
| `gateway_principal_id` | The gateway's managed identity — the only thing with data-plane access to Foundry. |
| `backend_pool_ids` | Backend pool per alias. Useful when checking circuit breaker state in the portal. |
| `subscription_keys` | Per-application subscription keys. `sensitive`. |
| `chargeback_workbook_id` | The chargeback workbook. |
| `budget_id` | Cost Management budget watching actual Foundry spend. |
| `nat_gateway_public_ip` | Stable outbound address, when the NAT gateway is enabled. Give this to anyone who needs to allow-list your egress. |
| `private_dns_zone_ids` | The three Foundry private DNS zones in use. |

## Cost and cleanup

This is the expensive example, and most of it bills whether or not anyone calls it:

- **API Management** — set by `apim_sku_name`, billed hourly. The dominant line item.
- **Private endpoints** — billed per endpoint per hour, plus data processed. There are several.
- **NAT gateway** — if `enable_nat_gateway` is true, billed hourly plus per GB.
- **Log Analytics ingestion** — `diagnostic_sampling_percentage` is pinned to **100** here, because anything less makes the chargeback ledger silently undercount. Full fidelity is correct and it is not free; control it with `log_retention_days` and `log_analytics_daily_quota_gb`, never by lowering the sampling percentage.
- **Event Hub** — only when `enable_eventhub_audit` is true; a standing namespace cost.
- **Foundry** — `GlobalStandard`, billed per token, nothing when idle.

```bash
terraform destroy
```

## Notes

- **Bypass traffic breaks the cost model, not just the security model.** Any request that reaches a Foundry account without passing through the gateway shows up in the invoice and not in the ledger, and is then allocated across the gateway's consumers in proportion to their shares — everyone is over-charged for traffic none of them sent. `public_network_access_enabled = false` on both accounts is load-bearing for chargeback.
- **Prompt bodies are not logged.** `log_request_and_response_bodies = false` is deliberate: request and response bodies are prompts, they carry whatever the user typed, and a telemetry store is the wrong place for it. Turn it on only for a bounded debugging window, and only after someone has agreed to the data-protection consequences.
- Content safety runs in line against the primary Foundry endpoint, with prompt shields on the way in and category thresholds applied in both directions.
- Background reading: [architecture](../../docs/architecture.md), [policy reference](../../docs/policies.md), [operations](../../docs/operations.md), [cost attribution](../../docs/cost-attribution.md).
