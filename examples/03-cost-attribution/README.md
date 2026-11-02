# Example 03 — Cost attribution onto API Management you already own

Layer 2 without Layer 1's greenfield assumptions. Nothing here creates an API Management instance, a Foundry account or a network. The gateway API, its products and its chargeback telemetry are added to infrastructure that already exists — which is the situation most engagements actually start from.

Pick this one when the question is "what did each team spend on AI last month?" and the gateway, or something like it, is already deployed. If you are starting from nothing, use [example 01](../01-quickstart/) or [example 02](../02-production-private/) instead.

> **Read [docs/cost-attribution.md](../../docs/cost-attribution.md) before you present any number this produces.** The short version is that the gateway decides *who* consumed capacity and Azure Cost Management decides *how much* it cost. Presenting the gateway's estimate as an invoice is the one way to get this wrong.

## What this deploys

| Module | What it creates here |
|---|---|
| [`ai-gateway`](../../modules/ai-gateway/) | The LLM API, backend pools, products, subscriptions and the gateway policy — onto your **existing** API Management instance, via `existing_api_management_id`. Cost attribution is on, so the policy writes the chargeback ledger. |
| [`cost-attribution`](../../modules/cost-attribution/) | The chargeback workbook, the alert rules, and optionally a Cost Management budget. |

Two settings carry this example:

- **`diagnostic_sampling_percentage = 100`.** The trace policy that writes the ledger emits only at verbose verbosity and is then sampled like everything else. A gateway left on a default sampling percentage reports a fraction of real usage while looking entirely healthy. This is the single most common cost-tracking bug, and it is why the value is pinned here.
- **`enable_cost_attribution = true`**, which requires a `pricing_map`. An alias absent from that map prices at `-1` — "unpriced" — never `0`, because a zero is indistinguishable from a free request and would quietly understate the bill.

## Prerequisites

This example attaches to things it does not create, so the prerequisites are real:

- An **API Management instance** on a tier that supports the token-limit policies — anything except **Consumption** — with a **system-assigned managed identity**.
- One or more **Foundry accounts** with the deployments named in `model_routes`.
- That managed identity holding **`Cognitive Services User`** on each of those accounts. This example does not grant it; `gateway_principal_id` is output so you can check which identity needs it.
- An **Application Insights** resource, and its instrumentation key.
- An existing **resource group** for the reporting artefacts.
- Terraform **>= 1.9.0**, `hashicorp/azurerm` **>= 5.0.0, < 6.0.0**, `Azure/azapi` **>= 2.0.0, < 3.0.0**.

## Usage

```bash
cd examples/03-cost-attribution
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

Generate the pricing map rather than typing rates by hand:

```bash
python ../../scripts/generate_pricing_map.py --region eastus2 --alias chat=gpt-4.1 --format hcl
```

## Inputs you must set

Every one of these has no default, because none of them can be guessed:

| Name | Type | What it is for |
|---|---|---|
| `resource_group_name` | `string` | Existing resource group to create the reporting artefacts in. |
| `existing_api_management_id` | `string` | Resource ID of the API Management instance to publish the gateway API onto. Any tier except Consumption; the token-limit policies are unavailable there. |
| `application_insights_id` | `string` | Resource ID of the Application Insights instance that receives the chargeback ledger. |
| `application_insights_instrumentation_key` | `string` | Instrumentation key for that Application Insights instance. |
| `foundry_backends` | map | The Foundry endpoints to route to, keyed by a short name. |
| `model_routes` | map | Client-facing aliases mapped onto physical deployments and an ordered set of backends. |
| `products` | map | Commercial tiers, each with its own token ceiling. The product is the governance boundary — put the limits here rather than on the API, so one noisy consumer cannot starve another. |
| `pricing_map` | any | Rates per alias. Generate it; see above. |

### Optional: per-user attribution

These have defaults and are off until set:

| Name | What it is for |
|---|---|
| `caller_tenant_id`, `caller_audiences`, `caller_client_application_ids`, `caller_consumer_names` | Turn on Entra caller authentication in `both` mode. Leave `caller_tenant_id` unset and the gateway stays on subscription keys, with user attribution off. |
| `user_attribution` | Read the signed-in user from On-Behalf-Of tokens; optional per-user token limits and `require_delegated`. Applies only when `caller_tenant_id` is set. |
| `log_analytics_workspace_id` | Turns on gateway diagnostics and LLM logs, and lets the ledger backfill streamed requests from `ApiManagementGatewayLlmLog`. **Switches the diagnostic setting to resource-specific tables.** |
| `users` | Names, departments and cost centres for object ids, for the workbook only. |
| `daily_user_spend_threshold_usd`, `unattributed_user_threshold_percent` | The per-user spend alert, and the alert for applications sending some requests without a user. |

Consuming applications have to call with On-Behalf-Of tokens for any of this to name a person; see the [integration guide](../../docs/obo-integration.md).

### Keys have to line up

The `consumers` register in the cost-attribution module is keyed by the identity the gateway stamps onto each ledger record. In `subscription_key` mode that is the key from the `subscriptions` map, which becomes the API Management subscription id verbatim. Get this wrong and every consumer reports as `unassigned` — the workbook will render, and the allocation will be meaningless.

## Outputs

| Name | Description |
|---|---|
| `openai_base_url` | Base URL for OpenAI-compatible clients. |
| `gateway_principal_id` | Managed identity that must hold `Cognitive Services User` on every Foundry account listed in `foundry_backends`. |
| `model_aliases` | Aliases published by the gateway. |
| `subscription_keys` | Per-application subscription keys. `sensitive`. |
| `chargeback_workbook_id` | The chargeback workbook. Reconciliation happens here. |
| `alert_rule_ids` | The alerts guarding chargeback accuracy: unpriced models, unmeasured usage, product spend, telemetry gaps and token burn rate. |
| `ledger_query` | KQL projection of the chargeback ledger. Start here when building reporting outside the workbook. |
| `reconciliation_note` | How to turn the gateway's estimate into a defensible chargeback number. |

## How a chargeback period actually runs

The workbook's `ActualCostUSD` is an **operator-entered parameter**, not an automated export. Each period:

1. Read actual Foundry spend for the period from Cost Management.
2. Enter it in the workbook's `ActualCostUSD` parameter.
3. The workbook allocates that real figure across consumers by their share of total tokens.

The per-request cost in the ledger is an estimate from published retail rates. It knows nothing about your EA discount, reservations or PTU amortisation, so never bill from it directly. Allocating a real invoice by token share is immune to all three; summing estimates is not. That argument is [ADR-0004](../../docs/decisions/0004-ratio-allocation-chargeback.md).

## Cost and cleanup

This example adds comparatively little, because it creates no gateway and no models. The costs it does add are:

- **Log Analytics / Application Insights ingestion**, at full fidelity. Sampling is pinned to 100 on this API, which is the point. If ingestion cost is a problem, shorten retention or set a daily cap — do not lower the sampling percentage, or the ledger starts under-reporting silently.
- **Event Hub**, only if you enable `enable_eventhub_audit` on the gateway module.
- **A Cost Management budget**, if `enable_budget` is set. Budgets themselves are free; the alerts they raise are not a charge.

```bash
terraform destroy
```

Destroying this removes the API, products and reporting it created. It does not touch the API Management instance, Foundry accounts or Application Insights resource you brought with you.

## Notes

- **Bypass traffic corrupts the allocation.** Any request reaching Foundry without passing through the gateway appears in the invoice and not in the ledger, so it is spread across the gateway's consumers in proportion to their shares — everyone is over-charged for traffic none of them sent. If you cannot close that path at the network level, treat the output as indicative rather than billable.
- The alerts exist because of the specific ways a chargeback number goes quietly wrong: unpriced models, untiered long-context requests, unmeasured usage and telemetry gaps. If one of them fires, the number is wrong, not merely interesting.
- Background reading: [cost attribution](../../docs/cost-attribution.md), [architecture](../../docs/architecture.md), [operations](../../docs/operations.md).
