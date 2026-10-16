# Operations guide

This is the day-2 document: what to do after the first `terraform apply`, what
each alert means when it wakes someone, and how to carry out the handful of
routine changes — a new model, a new consumer, a refreshed rate card — without
breaking the gateway for everyone else.

It assumes the design described in [architecture.md](architecture.md) and the
policy behaviour described in [policies.md](policies.md).

---

## 1. Deploying

The modules are ordinary Terraform. The examples under
[`examples/`](../examples/03-cost-attribution) show the composition: a
gateway module, optionally a cost-attribution module reading its outputs.

Two things about timing are worth knowing before you start.

**API Management takes a long time to create.** A first `apply` into an empty
resource group commonly runs for anything from roughly fifteen minutes to the
better part of an hour, depending on SKU and region. This is Azure, not
Terraform; there is nothing to tune. Plan the change window accordingly and do
not interrupt it. Subsequent applies against an existing instance are fast
unless they change the SKU or the network configuration.

**The default SKU is `StandardV2_1`.** The Consumption tier is explicitly
rejected by the module, because the LLM policy elements this accelerator
depends on are not available there. If you change `apim_sku_name`, check that
your target tier supports `llm-token-limit`, `llm-emit-token-metric` and the
semantic-cache elements before you plan.

### The state file is a secret store

The gateway module exposes `subscription_keys` as a sensitive output. Sensitive
outputs are redacted in the console, not in state. **Treat the Terraform state
file as a secret**: remote backend, encryption at rest, access restricted to
the people who are allowed to call the gateway as any consumer. If that is not
acceptable in your environment, use `caller_auth_mode = "entra_id"` — and read
[policies.md §1](policies.md#1-scope-ordering-is-a-security-boundary) first,
because that mode removes per-consumer throttling.

---

## 2. What to verify after a deployment

Work down this list in order. Each step depends on the previous one, so the
first failure tells you where to look.

**The outputs exist and look right.** `gateway_url` and `openai_base_url` are
the two a caller needs; `model_aliases` should list exactly the aliases you
configured; `backend_pool_ids` should have one entry per pool.

**Model discovery answers.** A `GET /models` against `openai_base_url` is
served by the gateway itself — §2 of the policy short-circuits it — so a
correct response proves the API, the policy and the rendered route table are
all in place, without a model deployment having to be reachable. If the alias
list here disagrees with your configuration, the route table named value did
not update; see [§9 Troubleshooting](#9-troubleshooting).

**A real completion succeeds.** Call one alias with a small request. Then
inspect the response headers. The `x-ai-*` family is the gateway's governance
envelope and each header proves a different part of the chain:

| Header | What its presence proves |
| --- | --- |
| `x-ai-estimated-cost-usd` | §11 ran and found a rate for this model |
| `x-ai-product` | the product scope was evaluated (absent in `entra_id` mode — expected) |
| `x-ai-model-alias`, `x-ai-pool`, `x-ai-deployment` | alias resolution picked the route you intended |
| `x-ai-total-tokens`, `x-ai-tokens-consumed` | §10 extracted usage from the response |
| `x-ai-remaining-tokens` / `x-ai-remaining-quota-tokens` | the token limit is counting |
| `x-ai-cache-hit`, `x-ai-cost-avoided-usd` | cache-hit detection ran and priced what it saved. Both are absent when the semantic cache is disabled, which is how a caller tells "no cache here" from "asked and missed" |

A cost header of `-1` means the request was **unpriced** — the model is not in
the rate card. That is a configuration gap, not a failure; see
[cost-attribution.md](cost-attribution.md).

A cost header of `0.00000000` alongside `x-ai-cache-hit: true` is a semantic
cache hit: no model was called, so there is nothing to charge. The value of what
it saved is in `x-ai-cost-avoided-usd`. Sending the same prompt twice in quick
succession with caching enabled is the fastest way to confirm the cache is
working end to end — the second response should return the pair above.

**Backend topology is not leaking.** `x-ms-region`, `azureml-model-session` and
`apim-request-id` should all be absent from the response. §12 deletes them. If
you see them, the policy in effect is not the one you think you deployed.

**Ledger rows are arriving.** Within a few minutes, the query in
`local.ledger_query` (exposed as the `ledger_query` output of the
cost-attribution module) should return your test requests. If the completion
succeeded but no row appears, the problem is the telemetry path, not the
gateway — again, [§9](#9-troubleshooting).

**Streaming is measured.** Make one *streaming* request and confirm it produces
a ledger row with non-zero tokens. §4 of the policy forces
`stream_options.include_usage`; if that is not working, streaming traffic is
invisible to every number in this accelerator, and the symptom is simply
missing rows rather than an error.

---

## 3. Alert runbooks

Six alert rules ship in `modules/cost-attribution`. The five scheduled query
rules are created only when `enable_alerts` is true **and** `action_group_id`
is set — an alert with nowhere to go is worse than no alert, so the module
declines to create one. The sixth, the token burn-rate metric alert, is off by
default and only created when you give it a threshold.

All five query alerts read the same ledger schema, so a problem with the
telemetry path tends to make several of them go quiet together. That is what
the telemetry-gap alert exists to catch.

### `unpriced_models` — severity 3, hourly

**Means:** at least one request (default threshold `1`) was served for a model
with no entry in the pricing map, and recorded a cost of `-1`.

**Check:** which alias, from the ledger. Usually it is a model someone added to
`model_routes` without regenerating the rate card, or a deployment whose model
name or version differs from what the generator priced.

**Do:** regenerate the pricing map for that model — [§5](#5-regenerating-the-pricing-map).
Until you do, every request to that alias is missing from your cost figures
entirely. The threshold is deliberately `1`: there is no acceptable level of
unpriced traffic, because you cannot bill what you cannot see.

### `untiered_long_context` — severity 3

**Means:** requests whose prompt exceeded `long_context_review_threshold`
(default 200,000 tokens) were priced against a model that has **no long-context
tier** defined, and the count passed `untiered_long_context_threshold`
(default 25).

**Check:** the model, and whether the provider actually charges a higher rate
above a context threshold for it. [ADR-0008](decisions/0008-context-length-pricing-tiers.md)
explains the mechanism.

**Do:** if a higher tier exists, regenerate that model's entry with a
`--context-threshold` so the tier is priced. If it genuinely has no tier, the
alert is a false positive for that model and you can raise the threshold. What
you should not do is ignore it, because the failure direction is
**under-billing**: those requests are being charged at the base rate when the
provider is charging you more.

### `unmeasured_usage` — severity 3

**Means:** more than `unmeasured_usage_threshold_percent` (default 5%) of
requests produced no usable token counts.

**Check:** whether the affected requests are streaming. The usual cause is a
request path where `stream_options.include_usage` did not take effect, or a
response shape §10 does not recognise.

**Do:** reproduce one of the affected calls and inspect the raw upstream
response. If a new API surface is returning usage under a field name §10 does
not read, that is a policy change — see
[policies.md §7](policies.md#7-extending-the-policy-safely).

### `cache_economics` — severity 3, hourly over a one-day window

**Means:** for one model alias, caching cost more than it saved. The tokens
written to the prompt cache, priced at `cache_write_premium_usd_per_million`
(default 0.25), exceeded the total `costAvoidedUSD` that caching returned.
Models under `cache_economics_minimum_requests` (default 100) are ignored.

**Check:** the token-efficiency table in the workbook, for that alias. The shape
to look for is a high **Cache writes** column next to a low **Cache hit rate**
and a low **Prompt cache share** — paying to populate a cache that is never
read.

**Do:** look at what varies between prompts for that workload. A timestamp, a
session id, a user name or a randomised greeting near the start of the system
prompt makes every prompt unique, which defeats both cache layers while still
incurring the write premium. Moving the volatile content *after* the stable
content usually fixes it outright, because caching matches on prefixes.

If the prompts are genuinely all different — ad-hoc analysis, free-text search —
then caching cannot help this workload and the honest answer is to turn it off
for that model rather than keep paying for it. A cold cache after a deployment
will trip this once and then clear itself; the minimum-request floor exists to
stop that being a page.

### `product_spend` — severity 2, hourly over a one-day window

**Means:** estimated spend for a product passed `daily_spend_threshold_usd`
(default 100).

**Check:** the workbook, filtered to that product. Is it a step change or a
ramp? A step change is usually a new workload or a loop; a ramp is usually
organic growth.

**Do:** this is a budget conversation, not an incident, unless the step change
is unexplained. If a consumer is genuinely running away, the lever is the
product token limit — and note that in `entra_id` mode that lever does not
exist, which is itself worth knowing before you need it.

### `telemetry_gap` — severity 2

**Means:** the proportion of requests arriving without usable telemetry crossed
5%, evaluated hourly over a six-hour window and requiring two of three failing
periods before it fires. The tolerance is deliberate: a single sampled hour
should not page anyone.

**Check:** Application Insights sampling first — it is the most common cause
and it is a *configuration* problem, not an outage. Then ingestion delay, then
whether the policy is still emitting the trace.

**Do:** if sampling is the cause, reduce or disable it for the gateway's
Application Insights resource. Note what this means while it is firing: **every
other number in this accelerator is understated**, because they all derive from
the same ledger. Treat a persistent telemetry gap as invalidating the month's
chargeback, not merely as a monitoring nuisance.

### `token_burn_rate` — metric alert, optional

**Means:** the `Total Tokens` metric in the `aigateway` namespace crossed your
threshold, evaluated every minute over a five-minute window.

This is the fast one. The query alerts run hourly and read Log Analytics, which
has ingestion latency measured in minutes; this reads the metric pipeline and
can tell you about a runaway loop in single-digit minutes. It has no default
threshold because a sensible value is entirely dependent on your traffic — set
it once you have a week of baseline.

### Alerts that are described but not shipped

Be aware of two gaps, so you do not assume cover you do not have:

* **There is no variance alert.** The README and
  [architecture.md §4.5](architecture.md#45-what-the-customer-actually-sees)
  describe one; the module does not create it. Variance between estimated and
  allocated cost appears as adjacent columns in the workbook and must be read
  by a human.
* **There is no circuit-breaker alert.** Architecture §9 and
  [ADR-0001](decisions/0001-native-backend-pools.md) both suggest breaker trips
  should be alerted on; no such rule exists in the repository. Treat it as
  roadmap, and in the meantime watch backend health through APIM's own
  diagnostics.

---

## 4. Consumers and credentials

### Onboarding

A consumer needs two things: a way in, and a place in the registry.

The way in depends on `caller_auth_mode`. In `subscription_key` or `both`, add
an entry to `var.subscriptions` naming the product it belongs to; the module
creates the API Management subscription and the key appears in the
`subscription_keys` output. In `entra_id`, there is no subscription to create —
you grant the application access to the audience or add its client id to
`client_application_ids`, and the consumer identity comes from the token.

The place in the registry is `var.consumers` on the cost-attribution module:
cost centre, owner, business unit and monthly budget. Without an entry the
consumer still appears in the ledger, but unattributed — the workbook joins the
registry with a left outer join precisely so that an unregistered consumer
shows up rather than disappearing.

> **Mind the registry key.** The variable description says the key should match
> the API Management subscription display name, but the join is against the
> ledger's `consumer` value — which is the Entra claim where one exists and
> `context.Subscription.Id` otherwise. Use whatever actually appears in the
> ledger for that caller. Make one test call and look.

### Offboarding

Set the subscription's `state` to `suspended` to stop traffic while keeping the
record, or `cancelled` to close it. Suspending is almost always the right first
move: it is instantly reversible, and it preserves the subscription id, which
means historical ledger rows remain attributable to a named consumer rather
than becoming an orphaned GUID.

Leave the `var.consumers` entry in place after offboarding. Removing it breaks
attribution for every past month, not just the current one.

### Rotating credentials

There is no key-regeneration operation exposed by the module. The available
mechanism is to replace the subscription resource:

```
terraform apply -replace='module.<name>.azurerm_api_management_subscription.this["<key>"]'
```

That issues new primary and secondary keys. It is a hard cutover — the old keys
stop working when the apply completes — so coordinate with the consumer, or
stage the change by issuing a second subscription, migrating the caller, then
removing the first.

The gateway's own credential to the model backends is a managed identity (§8 of
the policy). There is nothing to rotate there, which is most of the reason it
was chosen.

---

## 5. Regenerating the pricing map

The rate card is produced by
[`scripts/generate_pricing_map.py`](../scripts/generate_pricing_map.py), which
queries the Azure retail prices API and emits a JSON map keyed by model alias.
It normalises every rate to a per-million-token unit and understands the four
rate buckets — input, cached input, cache write and output.

Run it per model, with the region, alias and deployment type that match your
actual deployment. `--review` prints what it found for inspection, and
`--list-meters` is the tool to reach for when a model produces no match and you
need to see what meter names actually exist. `--fail-on-incomplete` is the flag
to use in any automated path.

The generator refuses to guess. It will reject a cached-input rate that is not
lower than the input rate, refuse a non-embedding model with no output rate,
reject a long-context tier that does not exceed the base rate, and refuse to
invent a context threshold it was not given. Those refusals are the point: a
wrong number here propagates silently into every cost figure downstream.

### What to check in the diff

Read the diff before you apply it.

* **Did any rate move in the wrong direction?** A sudden order-of-magnitude
  change is nearly always a meter-matching error, not a price change.
* **Did a model lose a bucket it previously had?** A disappearing `cachedInput`
  or `cacheWrite` is a matching failure, and it will quietly over-bill cached
  traffic.
* **Did `contextTiers` survive?** Regenerating without `--context-threshold`
  drops the long-context tier and reverts you to flat pricing. See
  [ADR-0008](decisions/0008-context-length-pricing-tiers.md).
* **Is the effective date what you expect?** Each entry carries one, and the
  payload the module builds also injects a `_meta` entry with a generation
  timestamp.
* **Are new aliases present and retired ones removed?** An alias in
  `model_routes` with no pricing entry is an unpriced model and will fire the
  alert.

### The gotcha: the named value ignores changes

The pricing named value in `modules/ai-gateway/main.tf` carries
`lifecycle { ignore_changes = [value] }`. That is there so that an out-of-band
price correction applied directly to the named value is not reverted by the
next unrelated `apply` — but it has a consequence you must plan for:

> **Updating `pricing_map` in Terraform will not update the deployed named
> value.** The plan will show no change. The gateway keeps using the old rates.

To actually roll out a new rate card, either replace the resource explicitly:

```
terraform apply -replace='module.<name>.azurerm_api_management_named_value.pricing'
```

or apply the new value out of band through the portal or CLI. Verify either way
by making a request and checking `x-ai-estimated-cost-usd` against a hand
calculation. Do not assume a clean `apply` means the rates shipped.

---

## 6. Adding a model or a deployment

Adding a model is three coordinated changes, and skipping any one of them
produces a different, confusing symptom.

1. **Deploy the model** in Foundry, in every account that backs the pool you
   intend to route it to.
2. **Add the alias** to `model_routes`, pointing at that pool and deployment.
3. **Price it** — [§5](#5-regenerating-the-pricing-map) — before you let real
   traffic at it.

Skip step 3 and the model works but is unpriced, costs `-1`, and is excluded
from every chargeback figure.

### Deployment-name parity

A backend pool distributes requests across multiple Foundry endpoints. The
gateway resolves an alias to **one** deployment name and sends it to whichever
pool member is selected. If the members do not all host a deployment with that
exact name, requests succeed or fail depending on which member they land on —
an intermittent 404 that correlates with nothing a caller can see, and one of
the more unpleasant failure modes available in this architecture.

The module computes `local.parity_violations` and, when
`enforce_deployment_parity` is on, fails the plan rather than letting you
deploy that configuration. Leave it on. If you turn it off, you are taking
responsibility for keeping deployment names identical across every member of
every pool by hand.

A pool holds at most 30 backends, and each backend carries its own circuit
breaker rule.

---

## 7. Circuit breakers and failover

Each backend in a pool has a circuit breaker. The defaults are five failures
within `PT1M`, a trip duration of `PT1M`, status codes 429 through 599 counted
as failures, and `Retry-After` honoured when the backend supplies one. A
tripped backend is removed from the pool for the trip duration and traffic goes
to the remaining members; see
[ADR-0001](decisions/0001-native-backend-pools.md) for why this is done with
native pools rather than in policy.

**What a trip looks like in telemetry.** Not as much as you would like. The
ledger records the *pool*, not the individual endpoint that served the request,
so a trip does not show up as a change in the ledger's routing column. What you
will see is a burst of upstream errors immediately before the trip, then a
quiet period, then recovery — and, if the remaining members cannot absorb the
load, a rise in 429s. Per-endpoint attribution needs API Management's own
backend diagnostics rather than the cost ledger.

As noted in §3, no alert ships for breaker trips. If backend health matters to
you operationally, that is the first alert to add yourself.

**Honour `Retry-After`.** Leaving `accept_retry_after` on means the gateway
respects the backend's own guidance about when it will be ready, which is
nearly always better than a fixed trip duration guessed in advance.

---

## 8. Capacity, token limits and quota exhaustion

There are three distinct limits in play and they fail differently.

**The per-consumer product limit** (`llm-token-limit` at product scope) returns
**429** with `Retry-After` when a consumer exhausts its tokens-per-minute. This
is the one you tune per consumer. Remember from
[policies.md](policies.md#1-scope-ordering-is-a-security-boundary) that it does
not exist in `entra_id` mode.

**The gateway-wide limit** (§5b, Entra modes only) also returns 429, but it is
shared across all callers — so a 429 from this limit means *someone* was noisy,
not necessarily the caller who received it.

**Product entitlement** returns **403 `model_not_entitled`**, which is not a
capacity problem at all. If you are triaging and see 403s, stop looking at
quota and look at the product allow-list.

Counters in the v2 tiers are per gateway unit and per region. With multiple
units the effective aggregate ceiling is higher than the configured number, so
treat configured limits as a guard-rail against runaway consumption rather than
an exact budget.

The `x-ai-remaining-tokens` and `x-ai-remaining-quota-tokens` response headers
let a well-behaved client back off before it is throttled, and
`x-ai-tokens-consumed` tells it what the last call actually cost it. It is
worth telling consumers those headers exist.

Backend-side capacity is separate: Foundry's own quota can return 429 regardless
of what the gateway allows. `forward_timeout_seconds` (default 240, bounded 10
to 300) governs how long the gateway waits for a model response — raise it for
long reasoning workloads, but understand that a longer timeout holds a gateway
connection open for the duration.

---

## 9. Troubleshooting

### A request came back unpriced (`x-ai-estimated-cost-usd` is `-1`)

The model alias has no entry in the pricing map. Confirm the exact alias from
the response headers or the ledger, check whether it is present in the deployed
named value, and if it is not, go to [§5](#5-regenerating-the-pricing-map) —
including the `ignore_changes` gotcha, which is the most common reason a rate
card that *is* in your Terraform is not the one the gateway is using.

### Variance between estimated and allocated cost is persistently high

Variance is the workbook's side-by-side comparison of the gateway's estimate
against the allocated share of real spend. Persistent, one-directional variance
usually has one of four causes, in rough order of likelihood:

1. **Stale rates** — the deployed pricing map is older than the prices.
2. **Bypass traffic** — something is calling the Foundry accounts directly, not
   through the gateway. Real spend includes it; the ledger does not. Lock the
   accounts down to the gateway's identity.
3. **Unpriced models** diluting the estimate.
4. **A model mix the token key handles poorly** — see
   [ADR-0004](decisions/0004-ratio-allocation-chargeback.md#tokens-are-a-proxy-for-cost-and-an-imperfect-one).

Remember that the allocated side is only as good as the figure an operator
typed into the `ActualCostUSD` parameter. Check that before you go looking for
anything subtler.

### Telemetry gap

Symptoms: rows missing from the ledger, several alerts quiet at once, the
workbook's completeness tile unhappy. Check in this order: Application Insights
**sampling** (by far the most common cause), then ingestion latency, then
workspace retention if the gap is in older data, then whether the policy is
still emitting the `<trace source="ai-gateway">` entry at all. A policy edit
that removed or renamed a trace field will break the shared ledger query for
every consumer of it simultaneously — which is a useful diagnostic, because a
total, instantaneous gap points at the policy and a partial one points at
sampling.

### A policy change did not take effect

Three possibilities, in order of frequency.

**It never rendered the way you read it.** `terraform validate` does not render
`templatefile()` output. Run
[`scripts/check_policies.ps1`](../scripts/check_policies.ps1) and read the
rendered document. See [policies.md §5](policies.md#5-authoring-rules).

**It rendered but Terraform saw no change.** Named-value-backed configuration —
routes, pricing — can be governed by `ignore_changes`, or the input may simply
be identical after rendering. Read the plan output rather than assuming.

**It applied but you are testing the wrong scope.** A change to the product
policy has no effect in `entra_id` mode, because the product scope does not
execute. Check for the `x-ai-product` response header: if it is absent, you are
not exercising the product policy at all.

### Model discovery lists the wrong aliases

`GET /models` is served from the rendered route table. A stale answer means the
routes named value in the gateway did not update, or the API policy in effect
is an older render. Compare the `model_aliases` output against what the
endpoint returns.

---

## 10. Upgrading the modules

Upgrade one module at a time and read the plan — properly, not by skimming for
a destroy.

Pay particular attention to anything that touches the policy resources. A
policy upgrade appears as a replacement of the policy body, and the only way to
know what actually changed is to render both versions with
`check_policies.ps1` and compare. If the new version adds template variables,
your own local copy of the baseline in that script will need them too.

Two Terraform-level behaviours to keep in mind across upgrades:

* The pricing named value carries `ignore_changes = [value]`, so an upgrade that
  ships new default rates will **not** apply them. Replace the resource
  deliberately — [§5](#5-regenerating-the-pricing-map).
* The budget resource carries `ignore_changes = [time_period]`, so an existing
  budget's window is preserved rather than being rolled forward on every apply.

After any upgrade, re-run the verification list in
[§2](#2-what-to-verify-after-a-deployment). It is short, and it checks the
things that break quietly.

---

## See also

* [architecture.md](architecture.md) — the design and its honest caveats
* [policies.md](policies.md) — policy reference and authoring rules
* [cost-attribution.md](cost-attribution.md) — the chargeback cycle
* [`modules/ai-gateway/README.md`](../modules/ai-gateway/README.md) — module inputs and outputs
* [`modules/cost-attribution/main.tf`](../modules/cost-attribution/main.tf) — alert rules and the ledger query
* [ADR index](decisions/) — the decision record
