# Cost attribution and chargeback

> **Audience:** platform engineers who operate the gateway and the finance or FinOps people who have to defend the numbers it produces.

This document describes Layer 2 of the accelerator: how per-request token telemetry becomes a per-application charge, what the shipped artefacts actually compute, and where the model is approximate. It assumes you have read [§4 of the architecture](architecture.md#4-layer-2--cost-attribution) and that you will read [ADR-0004](decisions/0004-ratio-allocation-chargeback.md) before presenting any of this to a finance team.

---

## 1. The distinction everything else depends on

The gateway computes an `estimatedCostUSD` for every request. It is a **management signal, not an invoice**.

The estimate is token counts multiplied by a rate card generated from the Azure Retail Prices API. Those are published list prices. They know nothing about an Enterprise Agreement discount, a reservation, a commitment tier, provisioned-throughput amortisation — where a PTU deployment's cost has no per-token relationship at all — or a mid-month repricing. The estimate is therefore fast, available per request, and structurally unable to equal the invoice.

Chargeback is computed differently, by **ratio allocation**:

```
charge(consumer) = actual spend for the period  ×  consumer's share of measured consumption
```

The property that matters is that ratio allocation is invariant to everything that makes the estimate drift. A discount, a reservation or a repricing moves the numerator and the denominator together and leaves every consumer's share untouched. If the ledger observed that one application consumed 30% of the tokens, that application is charged 30% of whatever Foundry actually cost. The allocation never has to know the discount exists, which is why it inherits enterprise pricing, reservations and PTU amortisation automatically rather than modelling them.

Two things about the shipped implementation have to be said plainly, because they are the parts people assume are more automatic than they are.

**The workbook allocates on share of *total* tokens across all models, not per meter.** `Share of tokens` is a consumer's `sum(totalTokens)` divided by the total across the filtered ledger. Tokens are not uniformly priced — an output token costs several times an input token, a cached input token a fraction of an uncached one — so a consumer whose traffic is output-heavy is under-charged relative to one with the same token count and a prompt-heavy profile. The distortion grows as consumer model mixes diverge. Per-meter allocation is the natural refinement and is discussed in §8.

**The actual spend figure is entered by hand.** The workbook exposes a parameter named `ActualCostUSD`, labelled *Actual Foundry spend for this period (USD)*, which an operator fills in from Azure Cost Management. There is **no automated Cost Management export, no scheduled job and no billing API call anywhere in this repository.** When the parameter is left blank, the `Allocated USD` column falls back to the gateway's own estimate. That fallback is deliberate — the workbook is useful before anyone has done the reconciliation — but it means a skipped reconciliation produces a report that runs on estimates while looking like it runs on actuals. `Estimated USD` and `Allocated USD` sit side by side in the same table so a reader can see which one is doing the work.

---

## 2. The ledger

Everything in Layer 2 reads one projection: `local.ledger_query` in [`modules/cost-attribution/main.tf`](../modules/cost-attribution/main.tf). Defining the schema once is what stops the alerts drifting away from the workbook. It is also exported as the module's `ledger_query` output, so external reporting can start from the same columns.

The source rows are Application Insights `traces` where `message startswith "llm.request"`, emitted by the `<trace source="ai-gateway">` element in §11 of [`llm-api.xml.tftpl`](../modules/ai-gateway/policies/llm-api.xml.tftpl). Every field below is a `customDimensions` entry on that trace.

| Column | Meaning |
| --- | --- |
| `correlationId` | The caller's `x-correlation-id` if it sent one, otherwise APIM's request id. Also returned on the response, so a user-reported failure is findable. |
| `environment` | The `environment_name` named value. Lets one Application Insights resource carry several gateways. |
| `product` | APIM product name, or `unassigned` when no product could be resolved. |
| `subscriptionId` | APIM subscription id, or `anonymous` when there is no subscription. |
| `consumerId` | The attribution identity: an Entra claim value in the Entra modes, otherwise the subscription id. `unattributed` if no claim in the configured order was present. |
| `consumerName` | Friendly name from `caller_authentication.consumer_names`, falling back to `consumerId`. Cosmetic only. |
| `consumerType` | `entra` or `subscription`. Carried so a report can tell a token-backed attribution from a key-backed one rather than treating both as equally trustworthy. |
| `modelAlias` | The alias the client asked for — the gateway's public contract, and the key into the pricing map. |
| `deployment` | The physical deployment the alias resolved to. |
| `pool` | The backend pool. Not the physical endpoint that answered: once the pool owns backend selection the policy cannot know which member served the request (see [ADR-0001](decisions/0001-native-backend-pools.md)). |
| `statusCode` | Response status. |
| `streaming` | Whether the client asked for a streamed response. |
| `usageMeasured` | Whether the response carried a `usage` block at all. The difference between "free" and "unmeasured". |
| `promptTokens`, `billablePromptTokens`, `cachedTokens`, `cacheWriteTokens`, `completionTokens`, `reasoningTokens`, `totalTokens` | The token counters the cost expression is built from. `billablePromptTokens` is `promptTokens` less the cached and cache-write counts, because those three are priced at different rates; recomputing spend from `promptTokens` alone will not reconcile. |
| `estimatedCostUSD` | What the consumer is charged. Full precision, `0` for a semantic cache hit, `-1` for an unpriced model. |
| `cacheHit` | Whether the gateway answered from its semantic cache without calling a model. |
| `costAvoidedUSD` | What caching saved on this request. Coalesced to `0` for traces emitted before the field existed. |
| `contextTier` | Which rate card priced the request: `base`, or a tier name such as `long`. Defaulted to `base` for traces emitted before context tiers existed. |

### `consumer` is the chargeback key

Two derived columns do the work:

```kql
| extend
    consumer     = iff(isempty(consumerId), subscriptionId, consumerId),
    consumerType = iff(isempty(consumerTypeRaw), "subscription", consumerTypeRaw)
```

`consumer` prefers the Entra identity and falls back to the APIM subscription id. That single line is why the same queries work in all three `caller_authentication` modes, and across a staged rollout where both shapes are in flight at once: traces emitted before caller authentication was enabled carry no `consumerId` and resolve to the subscription, and the reports keep working. A separate `extend` is required because KQL cannot reference a column defined in the same one.

Why the identity matters as much as the arithmetic is [ADR-0007](decisions/0007-entra-id-caller-authentication.md): a subscription key is a bearer secret that can be copied into a second service without trace, at which point the chargeback report is wrong and nothing says so. An Entra token is bound to an app registration or a managed identity and expires on its own. `consumerType` is on the ledger so a reader can tell which kind of evidence a row rests on.

### What the trace carries but the projection does not

The trace emits more than `local.ledger_query` projects: `backendModel`, `backendRegion`, `apiId`, `operationId`, `pricingEffectiveDate` and `latencyMs`. They are present in `customDimensions` and some are used directly by workbook tiles — the pricing-age tile reads `pricingEffectiveDate`. If you write your own query and need one of them, extend it yourself rather than assuming the shared projection already has it.

---

## 3. The consumer registry

`var.consumers` on the cost-attribution module is the finance metadata Azure has no way of knowing:

```hcl
consumers = {
  "claims-assistant" = {
    cost_centre        = "CC-4410"
    owner              = "jane.doe@contoso.com"
    business_unit      = "Claims"
    monthly_budget_usd = 2500
    alert_email        = "claims-platform@contoso.com"
  }
}
```

The map is rendered into `local.consumer_registry` and embedded in the workbook as a JSON literal, then joined `kind=leftouter` onto the ledger. **The join is on the `consumer` column** — that is, the Entra claim value in the Entra modes, or the APIM subscription id in `subscription_key` mode. A key that matches nothing still produces rows; the consumer simply shows a `Cost centre` of `unassigned` and no budget, which is a visible symptom rather than a silent one.

Be careful here: the variable's own description says the key must match the API Management subscription *display name*. The workbook's join is on the ledger's `consumer` value, and `consumerSubscription` in the policy is set from `context.Subscription.Id`, not from the display name. Key the registry on whatever actually appears in the `Consumer` column of the allocation table — run the ledger query for a few minutes of traffic and read it off — and treat the variable description as the thing that needs correcting.

`monthly_budget_usd` drives the `Budget used` column in the allocation table, which is computed against `Allocated USD`. It is a soft, reporting-only budget. The enforceable one is `azurerm_consumption_budget_resource_group`, which watches what Azure actually bills over the Foundry resource group, and the hard ceiling is the per-product `llm-token-limit`. Three different mechanisms, three different jobs.

`alert_email` values are merged with `var.alert_emails` into the budget's notification contacts. They do not create per-consumer alert rules; the module ships no per-consumer alerting.

---

## 4. The alerts, and what each one means when it fires

All of these are created only when `enable_alerts` is true **and** an action group exists — either `existing_action_group_id` or at least one address in `alert_emails`. With neither, `local.alerts_enabled` is false and no rule is created at all. That is easy to miss in a first deployment.

### `unpriced_models` — severity 3, default threshold 1 request

Fires when any request in the window has `estimatedCostUSD < 0`, grouped by `modelAlias`. One is enough by default, because one unpriced alias means an entire model's spend is unattributed.

**What it means:** a model alias served by the gateway has no entry in `pricing_map`. See §5 for why that is `-1` and not `0`.

**What to do:** regenerate the pricing map for the alias named in the alert dimension (§6), or accept it knowingly if the alias is deliberately unpriced.

### `untiered_long_context` — severity 3, default threshold 25 requests

Fires on requests that were measured, priced, had `promptTokens >= long_context_review_threshold` (default 200,000) and were nevertheless priced at `contextTier == "base"`.

**What it means:** long prompts are being costed at a flat rate. If the model has context-length pricing and no `contextTiers` entry, that spend is under-reported — for GPT-5.5, by 2× on input and 1.5× on output. Nothing else about the resulting number looks wrong, which is precisely why this is an alert and not a dashboard tile: the failure is a missing configuration, and a missing configuration produces no symptom of its own.

The review threshold is deliberately *below* the lowest real boundary in use (272,000 for GPT-5.5) so a workload creeping towards it is noticed before it crosses. The count threshold is 25 rather than 1 because a genuinely flat-rate model produces these legitimately, and an alert that cannot be cleared gets muted — at which point it is worse than absent. Set it to 1 once every model you serve is known to have its tiers configured.

**What to do:** check whether the alias in the dimension actually has banded pricing. If it does, add `contextTiers` (§7). If it does not, raise `untiered_long_context_threshold` or `long_context_review_threshold` and record why.

### `unmeasured_usage` — severity 3, default threshold 5%

Per product, the percentage of `2xx` responses where `usageMeasured` is false.

**What it means:** successful requests are returning no token counts, so their spend is real and entirely invisible to the ledger.

**By far the most common cause is streaming.** The ledger is built from a parsed JSON response body, and a streamed response is `text/event-stream`, so every streamed request is recorded `usageMeasured = false` by design. This is not a misconfiguration you can tune away — it is the cost of letting tokens reach the client as they are generated, and the reasoning is in [§10 of the policy reference](policies.md). Streamed usage still reaches the token *metrics* through `llm-emit-token-metric`, so you can size the gap: compare metric tokens against ledger tokens for the same period.

If the figure is high and your callers do **not** stream, look instead at a stream that terminated early, a response that was not JSON, or a non-2xx body that still looked successful.

This matters more than it first appears. Ratio allocation redistributes the **entire** invoice across the consumers the ledger observed. A consumer whose requests were not recorded does not get a smaller share — it gets no share, and its spend is silently redistributed over everybody else, who are then over-charged. Unmeasured usage is a correctness failure that propagates into other consumers' bills, not a reporting inconvenience.

### `product_spend` — severity 2, default $100/day

Estimated spend per product over a trailing day, evaluated hourly.

Deliberately an absolute threshold rather than a baseline comparison: Azure log alerts evaluate over a window of at most two days, which is too short to establish a trailing average worth comparing against, and a rule that silently compares against a meaningless baseline is worse than no rule. Trailing averages belong in the workbook, where the query range is unconstrained.

**What it means:** a tier spent more yesterday than you said was normal. It is computed from the **estimate**, so read it as a volume signal, not as a bill.

### `telemetry_gap` — severity 2, 5% over six hours, two failing periods of three

Compares ledger record count against the APIM `requests` count and fires when more than 5% of requests produced no ledger row.

**What it means:** chargeback is undercounting. In order of likelihood: the API diagnostic `sampling_percentage` has been moved off 100; the diagnostic `verbosity` is no longer `verbose`, in which case the `trace` policy emits nothing at all; or requests are failing before the outbound section runs and are landing in `llm.error` instead. The first two look like a cost saving at the time somebody makes them. Two failing periods are required so ordinary ingestion-latency skew does not page anyone.

### `token_burn_rate` — severity 2, optional

The only alert that reads a metric rather than a log: `Total Tokens` in the `metric_namespace` (default `aigateway`), `PT1M` frequency over a `PT5M` window. Disabled unless `token_rate_alert_threshold` is set.

**What it means:** token consumption is running away *now*. Every other alert here is a log query on an hourly cadence, and a runaway agent loop can spend a great deal of money inside an hour. This is the fast signal, and it is aggregate by nature — it tells you something is burning, not who.

### `cache_economics` — severity 3, optional but on by default

Runs hourly over a trailing day, per `modelAlias`. Compares what caching returned (`costAvoidedUSD`) against an estimate of what populating the cache cost (`cacheWriteTokens` priced at `cache_write_premium_usd_per_million`, default `0.25`). Fires when the difference is negative. Models serving fewer than `cache_economics_minimum_requests` (default 100) in the window are skipped.

**What it means:** caching is losing money on that model. Prompt text is varying just enough to miss the cache on nearly every request while still paying the cache-write premium on the way through. The usual causes are a timestamp, a session id or a random greeting injected into the system prompt — anything that makes each prompt unique defeats the cache completely while costing extra for the privilege.

Move the volatile part of the prompt after the stable part, or turn caching off for that model. The alert is per model rather than per gateway on purpose: one badly behaved workload can be net-negative while the estate overall still benefits, and an aggregate would hide exactly the case worth finding.

The premium is a single assumed figure across all models because the ledger records how many tokens were written to cache, not which rate card priced them. That is deliberate — this alert answers "is this cache worth having", which turns on the sign of a subtraction, not on a precise figure. Raise `cache_write_premium_usd_per_million` if the models behind the gateway charge more than the default assumes, or set `enable_cache_economics_alert = false` if caching is off.

### There is no variance alert

The README and [architecture §4.5](architecture.md#45-what-the-customer-actually-sees) describe an alert on estimate-versus-actual variance. **No such rule exists in `modules/cost-attribution`.** Variance is surfaced in the workbook, as the gap between the `Estimated USD` and `Allocated USD` columns of the allocation table, and it is a gap a human has to look at. Alerting on it is roadmap, and it is not a small change: the actual figure is a manually entered workbook parameter, so there is nothing for an alert rule to query until an automated Cost Management export exists.

---

## 5. Unpriced requests cost `-1`, never `0`

When the requested alias has no entry in the pricing map, the policy resolves a rate card of `{ "tier": "unpriced" }` and `estimatedCostUSD` is set to `-1.0`.

This is the single most deliberate choice in the cost model after ratio allocation itself. A zero would be absorbed silently into the monthly total. Every sum would still compute, every chart would still render, and the missing model would simply look like a model nobody used — a gap that is indistinguishable from an absence, and which nobody discovers until a reconciliation goes wrong a month later. A negative is impossible to mistake for real spend, impossible to sum accidentally into a total that looks plausible, and trivial to filter on.

Everything downstream is built around that convention:

- The workbook's headline and allocation tiles sum `iff(estimatedCostUSD > 0, estimatedCostUSD, 0.0)`, so unpriced rows contribute nothing to the money columns.
- Their **tokens still count**, so an unpriced consumer still receives an allocation share. This is the right behaviour — the tokens were really consumed — but it means an unpriced model distorts the estimate column and the allocated column in opposite directions.
- The data-quality table reports `Unpriced` and `Unpriced %` per model alias, and the workbook says in its own header text that if those are non-zero, every number above them is understated.
- `unpriced_models` fires on the first one.
- `generate_pricing_map.py` prints the same convention in its failure output, and `--fail-on-incomplete` makes it a CI failure.

To find them by hand:

```kql
traces
| where message startswith "llm.request"
| extend modelAlias = tostring(customDimensions["modelAlias"]),
         estimatedCostUSD = todouble(customDimensions["estimatedCostUSD"])
| where estimatedCostUSD < 0
| summarize Requests = count(), Tokens = sum(toint(customDimensions["totalTokens"])) by modelAlias
```

One further guard sits upstream: `enable_cost_attribution = true` with an empty `pricing_map` fails the plan, because every single request would otherwise be unpriced.

---

## 5b. Caching, and why a cache hit is not free to measure

Two different mechanisms reduce what a request costs, they work at different layers, and conflating them produces a report nobody can defend.

**Prompt caching happens inside the model.** The request still runs and still reaches a deployment. Some portion of the input was recognised as a prefix the model had already processed, so those tokens are billed at a reduced `cachedInput` rate instead of the full `input` rate. The ledger reports them as `cachedTokens`, and the saving is the spread between the two rates.

**Semantic caching happens at the gateway.** `llm-semantic-cache-lookup` finds a sufficiently similar earlier prompt and returns that response directly. No model is called. Azure bills nothing.

### The trap

A semantic cache hit is not obviously a cache hit by the time cost attribution sees it.

`llm-semantic-cache-store` keeps the backend's response body verbatim — including its `usage` block. When that body is replayed, it presents exactly the same `prompt_tokens` and `completion_tokens` as the call that originally produced it. There is no field on the response that says "this came from a cache". A cost expression reading those counters will price the request at full rate and charge a consumer for a model that never ran.

So the hit is detected from control flow instead. The `<backend>` section sets a variable:

```xml
<backend>
  <set-variable name="backendCalled" value="@(true)" />
  <forward-request ... />
</backend>
```

A semantic cache hit skips that section entirely, so in outbound the absence of the variable is the signal:

```csharp
cacheHit = !context.Variables.ContainsKey("backendCalled")
```

This is why `cacheHit` is derived where it is, and why it cannot be inferred from `usageMeasured` — a cache hit looks fully measured, because it is.

### The second trap: where the outbound section starts

The control-flow signal above is correct, but it only ever gets *evaluated* because of where one element sits.

On a semantic cache hit, API Management does not begin the outbound section at the top. It injects the cached response and **resumes execution at the `llm-semantic-cache-store` element**. Everything above the store is skipped.

Put the store in its intuitive place — last, because storing is logically the final thing you do with a response — and a cache hit skips the whole of usage extraction, the whole of the cost calculation, and the chargeback trace. Measured on a live gateway, that produced:

- the replayed response carrying the **original** request's `x-ai-estimated-cost-usd`, because that header had been captured in the stored copy;
- `x-ai-total-tokens: 0` and `x-ai-cache-hit: false`, because those are set after the store and read variables that were never assigned;
- **no ledger entry at all** for the hit.

The one request class the feature exists to measure was the one class it silently dropped — and the gateway returned `200` throughout, so nothing looked wrong.

The fix is positional. `llm-semantic-cache-store` is the **first** element of the outbound section:

```xml
<outbound>
  <base />
  <llm-semantic-cache-store duration="..." />
  <!-- usage extraction, pricing, ledger, headers -->
</outbound>
```

Two things follow. The stored copy is the backend's response *before* this gateway annotates it, so no `x-ai-*` header is ever baked into the cache. And a hit re-enters outbound at the first element, so extraction, pricing, trace and headers all run against the replayed body — a cache hit is measured exactly like a live call, which is the only way `costAvoidedUSD` can carry meaning.

Keep it an immediate child of `<outbound>`. Nesting it in a `<choose>` moves the resume point inside a conditional whose guard variables are themselves unset on a hit.

### What gets recorded

| Field | On a semantic cache hit | On a prompt-cached request |
| --- | --- | --- |
| `estimatedCostUSD` | `0` — nothing was billed | The real cost, with cached tokens at the discounted rate |
| `costAvoidedUSD` | The full modelled value of the response | `cachedTokens × (input − cachedInput)` |
| `cacheHit` | `true` | `false` |
| `usageMeasured` | `true` — the replayed body has a `usage` block | `true` |

`costAvoidedUSD` deliberately excludes cache *writes*. A write is a real premium charge and is already inside `estimatedCostUSD`; netting it off here would hide the failure mode that `cache_economics` exists to catch. Savings and the cost of producing them are kept apart so the two can be compared.

Response headers `x-ai-cache-hit` and `x-ai-cost-avoided-usd` carry the same two values back to the caller, so a team tuning prompts for cache reuse can measure the effect without waiting on a workbook.

### Consequences for reporting

Summing `estimatedCostUSD` alone across the upgrade to ledger `schemaVersion` 2 will show spend falling while usage holds steady. That is the correction working, not a data loss. To reconstruct what the traffic *would* have cost, sum `estimatedCostUSD + costAvoidedUSD`.

---

## 6. Keeping the rate card honest

[`scripts/generate_pricing_map.py`](../scripts/generate_pricing_map.py) queries the anonymous Azure Retail Prices API and emits a `pricing_map`, so rates are derived from a Microsoft-published source rather than typed from a blog post:

```bash
python scripts/generate_pricing_map.py --region eastus \
    --alias chat-small=gpt-4o-mini \
    --alias embed-small=text-embedding-3-small \
    --deployment-type global \
    --output pricing.auto.tfvars.json --review
```

Meter matching is heuristic, because Azure's meter names are inconsistent — which is why `--review` prints the meter chosen for each rate and the script tells you to read the diff before committing. `--list-meters MODEL` shows everything Azure publishes for a model, with each row labelled by how the script classified it. Two guards refuse to emit a plausible-looking wrong entry rather than shipping it: a cached rate that is not cheaper than the input rate indicates a misclassified meter, and a model with an input rate but no output rate that does not look like an embedding model is a parsing failure. Both produce no entry, which the gateway then reports as `-1` — loudly.

Rates are per 1,000,000 tokens (`TARGET_UNIT`), matching how Azure publishes them, across four buckets: `input`, `cachedInput`, `cacheWrite`, `output`. `--deployment-type` matters: global, regional and data-zone rates differ.

One thing the generator does **not** emit is a `meterName` field, despite the example in architecture §4.3 showing one. Each entry carries a `source` object (`model`, `region`, `version`, `deployment`) and an `effectiveDate`. If you want a per-meter reconciliation join, you are adding that field yourself today.

See §5 of [operations.md](operations.md#5-regenerating-the-pricing-map) for how to apply a regenerated map — there is an `ignore_changes` on the named value that will catch you out otherwise.

---

## 7. Context-length pricing and what it does to attribution

Azure prices some models by input length. GPT-5.5 doubles its input rate and raises output by half above 272,000 prompt tokens, and the whole request reprices — it is **not marginal**. A flat-rate entry under-reports such a request by roughly half while producing a number that looks entirely plausible. [ADR-0008](decisions/0008-context-length-pricing-tiers.md) has the arithmetic, checked against Azure's own worked example.

A `pricing_map` entry may carry an optional `contextTiers` array; the gateway resolves the applicable card from `promptTokens` before pricing, selecting the matching tier with the highest threshold:

```json
"gpt-5-5": {
  "unit": 1000000,
  "input": 5.0, "cachedInput": 0.5, "output": 30.0,
  "contextTiers": [
    { "name": "long", "minPromptTokens": 272001,
      "input": 10.0, "cachedInput": 1.0, "output": 45.0 }
  ],
  "effectiveDate": "2026-10-04"
}
```

Three consequences for attribution:

1. **The threshold is measured on total `promptTokens`, cached ones included.** Caching changes what a token costs, not whether the model had to carry it in context. The policy reads `promptTokens`, not `billablePromptTokens`, and that is deliberate.
2. **A tier never inherits a rate from the base entry.** A tier that omits `cachedInput` falls back to *its own* `input` rate. Inheriting would apply a short-context cached price to a long-context request — an error in the direction nobody investigates, because the bill comes out lower than expected rather than higher.
3. **The tier is recorded, not assumed.** `contextTier` is on every ledger row, so a long-context bill reads as a pricing event rather than as a usage spike, and `untiered_long_context` can find the configuration gap. Configuring a tier stays optional because a workload that never approaches the threshold is correctly priced by a flat rate.

The generator emits tiers automatically for models whose threshold is in `CONTEXT_THRESHOLDS` and **refuses to guess one it does not know**, because the Retail Prices API publishes the long-context rates but never the boundary. Supply it with `--context-threshold ALIAS=TOKENS`.

---

## 8. Running a monthly chargeback cycle

A plain-English walkthrough. It takes well under an hour once the registry is right.

**1. Close the data-quality questions first.** Open the chargeback workbook and scroll to *Data quality* before looking at any money. If `Unpriced %` or `Unmeasured %` is non-zero for a model anyone cares about, fix that first — regenerate the pricing map, or chase the streaming client — because allocating a month with a hole in it charges that hole to everybody else. Check the telemetry-completeness chart on the same screen: ledger records should track gateway requests almost exactly.

**2. Get the authoritative amount.** In Azure Cost Management, scope to the resource group holding the Foundry accounts the gateway fronts — the same scope as `budget_scope_resource_group_id` — and read actual cost for the billing period. This is a manual step and the accelerator does not automate it.

**3. Match the periods.** The workbook's time range presets are 1, 7, 30 and 90 days. Thirty days is not a calendar month. A Cost Management figure for a calendar month and a 30-day rolling workbook window do not describe the same period, and the difference is not small in a growing workload. Align them before you publish anything.

**4. Enter the figure.** Put it into the `ActualCostUSD` parameter. The `Allocated USD` column switches from the gateway's estimate to `actual × share of tokens` the moment the parameter is non-empty.

**5. Read the two money columns together.** `Estimated USD` and `Allocated USD` sit side by side on purpose. A persistent gap in the same direction, month over month, is your effective discount — or a stale rate card. A gap that suddenly changes direction or size is worth investigating before you send the report.

**6. Export and attribute.** The allocation table already carries `Cost centre`, `Owner`, `Share of tokens`, `Allocated USD` and `Budget used` per consumer and product. Export it; that is the chargeback report. If your finance system needs the raw shares instead, the module's `ledger_query` and `consumer_registry` outputs give you the same schema outside the workbook.

**7. Record what you did.** The number in the report came from a human reading Cost Management. Note which figure, which scope and which period, because the next person to be asked "where did this come from" will be you.

Chargeback is periodic and retrospective by construction: the authoritative amount only exists after Azure has billed. Anyone who wants a figure *today* is looking at the estimate, with all of its caveats. That gap is exactly what the estimate exists to fill.

---

## 9. Honest limits

**Sampling.** The ledger reaches Application Insights only because the module pins `verbosity = "verbose"` on the LLM API and defaults `diagnostic_sampling_percentage` to 100. Move either and the ledger silently reports a fraction of real usage while looking perfectly healthy — the single most common cost-tracking bug, and the reason `telemetry_gap` exists. If telemetry cost is the problem, shorten retention or use a daily cap; do not touch the sampling percentage. [ADR-0005](decisions/0005-telemetry-sink-selection.md) is the full argument, including why full fidelity has a real and growing ingestion bill.

**Retention.** Application Insights retention is whatever `log_retention_days` on the observability module sets — 30 days in the quickstart. A ledger you cannot query is a ledger you do not have, so a chargeback cycle that runs quarterly needs retention that outlives a quarter. For numbers that must survive a dispute, `enable_eventhub_audit` on the **ai-gateway** module provisions a namespace, hub, logger and RBAC, and adds a `log-to-eventhub` element that writes the same ledger record, unsampled, as one JSON object per request. It is deliberately a duplicate of the Application Insights trace rather than a replacement, so the operational dashboards and the audit stream cannot drift apart.

Two things to understand before relying on it. It lives on the gateway module, not this one, because the API policy is what writes to the hub and a policy cannot name a logger that does not exist yet — the logger therefore has to be created in the same dependency graph as the policy. And Event Hub is a buffer, not an archive: `eventhub_retention_days` defaults to 7. Land the stream in a warehouse or a storage account before the window closes, or the audit trail is theatre.

**Bypass traffic.** Any request that reaches a Foundry account without passing through the gateway appears in the invoice and not in the ledger, so it is allocated across the gateway's consumers in proportion to their shares — everyone is over-charged for traffic none of them sent. The production example's network posture, which disables public network access on the Foundry accounts, is load-bearing for the cost model and not only for security.

**Tokens are an imperfect cost key.** Covered in §1 and in [ADR-0004](decisions/0004-ratio-allocation-chargeback.md#tokens-are-a-proxy-for-cost-and-an-imperfect-one). The ledger carries the token classes a per-meter refinement would need, but the shipped default is share of total tokens, and that simplification is a real inaccuracy rather than a rounding detail. If your consumers have genuinely divergent model mixes — one doing bulk embeddings, another doing long reasoning calls — say so in the report rather than letting the single number imply a precision it does not have.

**PTU capacity breaks the per-token story at the source.** Reserved capacity is paid for whether or not anyone uses it. Ratio allocation still divides the real figure correctly, but "cost per token" for a month with idle PTU capacity is an average over an amount that was never per-token to begin with.

**The estimate still has to be maintained.** Ratio allocation is immune to pricing drift, but the variance signal that tells anyone the pricing map has gone stale is computed *from* the estimate. Letting the rates rot does not corrupt the chargeback numbers — it blinds the mechanism that was supposed to warn you.

**The `Total Tokens` metric does not know about cache hits.** `llm-emit-token-metric` is declared in the inbound section, before the request reaches — or skips — the backend, and it derives its counts from the response. A semantic cache hit replays a response complete with its `usage` block, so those tokens are likely counted in the metric even though no model processed them. The *ledger* is correct, because `cacheHit` is resolved on the outbound path where the answer is known; the metric is a near-real-time signal that cannot see the same thing in time. Practical effect: `token_burn_rate` may count cached traffic toward its ceiling. Treat the metric as "throughput through the gateway" and the ledger as "what was consumed at a model", and reconcile against the ledger whenever the two disagree.

**The cache-write premium is assumed, not measured.** `cache_economics` prices cache writes from a single configurable figure across every model, because the ledger records how many tokens were written to cache but not which rate card priced them. It is sufficient for deciding whether a cache is worth keeping; it is not a number to put in an invoice.

---

## 10. See also

- [`docs/architecture.md`](architecture.md) — the whole design, including the telemetry sink comparison.
- [`docs/operations.md`](operations.md) — day-2 runbook, including the alert response procedures.
- [`docs/policies.md`](policies.md) — what the gateway policy does, section by section.
- [ADR-0004](decisions/0004-ratio-allocation-chargeback.md), [ADR-0005](decisions/0005-telemetry-sink-selection.md), [ADR-0007](decisions/0007-entra-id-caller-authentication.md), [ADR-0008](decisions/0008-context-length-pricing-tiers.md).
- [`examples/03-cost-attribution`](../examples/03-cost-attribution) — Layer 2 onto an API Management instance you already own.
