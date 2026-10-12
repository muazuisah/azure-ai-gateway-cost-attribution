# Policy reference

Almost everything this accelerator does that is not plain infrastructure happens
inside two Azure API Management policy documents. They are shipped as Terraform
templates and rendered at plan time:

| Template | Rendered into | Scope |
| --- | --- | --- |
| [`modules/ai-gateway/policies/llm-api.xml.tftpl`](../modules/ai-gateway/policies/llm-api.xml.tftpl) | `azurerm_api_management_api_policy` | API scope, applies to every operation of the inference API |
| [`modules/ai-gateway/policies/product.xml.tftpl`](../modules/ai-gateway/policies/product.xml.tftpl) | `azurerm_api_management_product_policy` | Product scope, applies per product |

The API-scope document is the large one — routing, identity, normalisation,
metering, cost attribution and governance headers all live there. The product
document is short and does one job: per-consumer entitlement and per-consumer
token throttling.

If you are here because a `.tftpl` edit broke your plan, skip to
[§5 Authoring rules](#5-authoring-rules). Those four rules account for most of
the ways these files bite.

---

## 1. Scope ordering is a security boundary

API Management evaluates policy in a fixed order of scopes:

```
Global  →  Product  →  API  →  Operation
```

Inbound sections run outermost-first down that chain; outbound and on-error
sections unwind in the reverse order. The practical consequence is that a
control placed at an inner scope cannot protect anything evaluated at an outer
scope, and — far more importantly here — **a control placed at the product
scope only runs if API Management can resolve a product for the request at
all.**

### Why the product scope exists

Per-consumer throttling has to be keyed on something that identifies the
consumer. The product policy keys its token bucket on
`context.Subscription.Id`:

```xml
<llm-token-limit counter-key="@(context.Subscription.Id)" ... />
```

That value is available before any of the gateway's own logic runs, it is
assigned by API Management rather than asserted by the caller, and it cannot be
spoofed by a request header. The Entra ID claims that the API-scope policy uses
for consumer identity are not yet validated at the point the product policy
executes, so they are not a safe throttling key. Keying on the subscription is
the conservative choice.

The product policy also performs an entitlement check *before* the token limit:
it verifies the requested model alias is in the product's allow-list and
returns `403 model_not_entitled` if it is not. Doing the check first means a
caller cannot consume another team's token budget by asking for a model they
were never granted.

### The failure that follows: `entra_id` mode has no product

In `caller_auth_mode = "entra_id"` the API is published with
`subscription_required = false` and callers present a bearer token instead of a
subscription key. There is no subscription on the request. API Management
therefore has **no product to associate the call with**, and so:

> **In `entra_id` mode the product-scope policy does not execute at all.**
> Not partially, not with an empty counter key — the scope is never entered.
> Both the entitlement check and the per-consumer `llm-token-limit` are
> silently absent.

This is the single most consequential thing to understand about this
repository's policy design. It is a silent failure: nothing errors, nothing
logs, the gateway just stops enforcing the two controls you most likely
believed were protecting you. Two mitigations ship in the module.

**Mitigation 1 — a gateway-wide token limit at API scope.** Section `5b` of
`llm-api.xml.tftpl` is emitted only when the Entra path is active, and places a
`llm-token-limit` at the API scope where it will always run:

```xml
<llm-token-limit counter-key="gateway-global"
                 tokens-per-minute="..."
                 estimate-prompt-tokens="false"
                 ... />
```

It is a blunt instrument. It is one bucket shared by every caller, so it
protects the *backend* from aggregate overload but does nothing to stop one
noisy consumer from starving the others. `estimate-prompt-tokens` is `false`,
so the limit is enforced on usage reported by the model after the fact rather
than on a pre-flight estimate; that is more accurate but means a single very
large request can overshoot the bucket before it is counted.

Because that limit is the only backstop, `tokens_per_minute` is a **required**
variable in `entra_id` mode. The module will not let you deploy without it.

**Mitigation 2 — a plan-time guard.** `modules/ai-gateway/main.tf` computes
`local.inert_product_controls` and fails the plan with a precondition if you
have configured product-scope controls — allow-lists or per-product token
limits — in a mode where they can never run. The intent is that you discover
this at `terraform plan`, not six weeks later while reading a bill.

The design trade-off is recorded in
[ADR-0007](decisions/0007-entra-id-caller-authentication.md). If per-consumer
throttling matters more to you than token-based authentication, use
`caller_auth_mode = "both"`: callers present both a subscription key and a
bearer token, products resolve normally, and the product policy runs.

---

## 2. Walking `llm-api.xml.tftpl`

The file is organised into numbered, banner-commented sections. They are
described below in execution order. Sections that are conditional on a feature
flag are marked as such — the Terraform template emits nothing at all for them
when the flag is off, which keeps the rendered document small and the hot path
cheap.

### §1 — Identity and correlation

Establishes the variables the rest of the document depends on: a correlation
identifier, the API Management subscription id (`consumerSubscription`, taken
from `context.Subscription.Id`), and the product id where one exists. These are
set once, early, so that every later section — including `<on-error>` — can
read them without re-deriving anything.

### §1b — Entra ID validation (conditional)

Emitted only when `caller_auth_mode` is `entra_id` or `both`. A
`validate-azure-ad-token` element checks the bearer token against the tenant,
the configured `audiences` and, where supplied, `client_application_ids`. The
module requires at least one of those two to be set in an Entra mode; a token
validated against nothing useful is not validation.

After validation the policy extracts consumer identity from the claims into
three variables — `consumerId`, `consumerType` and `consumerName` — using a
precedence order that prefers an application identity over a user identity.
`consumerId` is what the cost ledger later records as the consumer, falling
back to the subscription id when it is empty. That fallback is what makes the
ledger work identically in all three auth modes; see
[cost-attribution.md](cost-attribution.md).

This section contains the `Dictionary&lt;string, string&gt;` declaration that
rule 2 below exists to explain.

### §2 — Model discovery

A short-circuit for `GET /models`. The gateway answers it itself from the
rendered route table rather than proxying to a backend, so clients can discover
which aliases exist without a model deployment having to be reachable. The
response is produced with `return-response`, which means nothing downstream of
this point runs for that operation.

### §3 — Request body parsing

Reads the request body once (preserving it for the backend) and extracts the
`model` field into `requestedModel`. A request with no model is rejected with
`400 missing_model` here rather than being forwarded and failing confusingly at
the backend.

### §3b — Alias resolution

Resolves `requestedModel` against the route table named value into
`targetPool` and `targetDeployment`. An unrecognised alias is rejected with
`400 unknown_model`, and the error body lists the aliases that *are* available
— a small kindness that removes an entire category of support ticket.

> Note: two consecutive banner comments in the template are both numbered `3`.
> It is cosmetic, but if you are counting sections, that is why your count
> disagrees with the labels.

### §4 — Body normalisation

Rewrites the outbound body so that the alias is replaced by the real deployment
name, and forces `stream_options.include_usage` on for streaming requests.
Without it a streamed response carries no usage block at all, and
`llm-emit-token-metric` has nothing to publish — so streaming traffic disappears
from the token metrics entirely.

Note what this does **not** do. It does not put streamed requests in the
chargeback ledger. The ledger is built in §10 from a parsed JSON response body,
and a streamed response is `text/event-stream`, so §10 skips it and records the
request as `usageMeasured = false`. That is deliberate — see §10 — and it means
streamed traffic is counted in the metrics but reported as *unmeasured*, not as
zero, in the ledger. Unmeasured is visible and alertable; zero would silently
under-bill every streaming consumer.

### §5 — Token metric emission

`llm-emit-token-metric` publishes token counts to the `aigateway` custom metric
namespace with four dimensions: Product ID, Operation ID, ModelAlias and
Environment. These four were chosen deliberately and the ceiling they sit under
is explained in [§4 Metric cardinality](#4-metric-cardinality-is-a-hard-ceiling).

### §5b — Gateway-wide token limit (conditional)

Described in §1 above. Emitted only in the Entra modes.

### §6 — Content safety (conditional)

`llm-content-safety` against an Azure AI Content Safety resource, on the
inbound path. It is excluded for the `create-embedding` operation — running a
text-moderation check over an embedding request costs latency and tells you
nothing.

Two things about this policy are worth knowing before you enable it, both found
by deploying it (see [validation](validation.md)).

**It authenticates as the caller's request.** `llm-content-safety` forwards
whatever `Authorization` header is on the request when it runs. The gateway
therefore acquires its managed-identity token in §5b, *before* this policy,
rather than just before routing. Attach it later and the screening call goes out
unauthenticated, Content Safety answers `401`, and API Management reports that to
the client as a flat `403 Request failed content safety check` — identical to a
genuine moderation block, for a prompt that was never assessed. Embeddings keep
working throughout, because they skip this section, so the gateway looks like it
is moderating correctly rather than like it is misconfigured.

**It caps prompt length at 10,000 characters.** That is the most Azure AI Content
Safety will assess in a single call, and an over-length prompt fails the same
misleading way. The gateway measures the prompt first and refuses anything longer
with `413 ContentSafetyInputTooLong`, naming the real limit and the actual
length, so the caller shortens or chunks the input instead of hunting for
offending words that were never there. `content_safety_max_characters` can lower
the bound but not raise it past what the service accepts.

The practical consequence: **with content safety enabled, prompts never get large
enough to reach a long-context rate card**, so `contextTier` stays on `base`.
Tiered pricing applies only where screening is off.

### §7 — Semantic cache lookup (conditional)

`azure-openai-semantic-cache-lookup` paired with a store on the outbound path.
It is deliberately narrow: streaming requests, embedding requests and requests
with a high `temperature` all bypass the cache. A cached answer to a request
that explicitly asked for variability is a bug, not an optimisation. The cache
varies by model alias and product, so one product cannot read another's cached
responses.

Semantic caching is off by default. It is the one component here that can
change the *answers* your users receive, which is why
[architecture.md](architecture.md) treats it as opt-in.

A cache hit leaves no mark on the response. The stored body is replayed
verbatim, `usage` block included, so a hit carries the same token counts as the
call that populated it and is indistinguishable from a real completion by
inspection alone. Billing from those counts would charge for a model that never
ran, so the hit is detected from control flow instead — see §9.

### §5b — Backend authentication

`authentication-managed-identity` acquires a token for the Cognitive Services
audience using the API Management instance's identity and attaches it as the
`Authorization` header.

This sits early, ahead of content safety and the semantic cache, because both of
those call Azure services themselves and reuse the header that is on the request
at the time. Acquiring the token once up front covers all three callers — the
moderation call, the cache's embeddings call, and the model call. Tokens are
cached by the runtime, so there is no cost to doing it early, and there is a very
confusing failure (see §6) in doing it late.

### §8 — Stripping caller credentials

The policy **deletes** both the `api-key` and `Ocp-Apim-Subscription-Key` headers
before forwarding. The deletion is not incidental: it ensures a caller's gateway
credential is never forwarded to the model backend, and that the only thing the
backend ever sees is the gateway's own managed identity.

### §9 — Routing

`set-backend-service` points at the resolved backend pool, and `rewrite-uri`
constructs the upstream path. The `<backend>` section contains a single
`forward-request` with `fail-on-error-status-code="false"` so that a non-2xx
response from the model is returned to the caller through the normal outbound
path — including the metering and cost sections — rather than being diverted
into `<on-error>`.

It also sets one variable:

```xml
<backend>
  <set-variable name="backendCalled" value="@(true)" />
  <forward-request ... />
</backend>
```

This is the cache-hit detector. A semantic cache hit skips the whole `<backend>`
section, so the variable is absent on the outbound path and
`!context.Variables.ContainsKey("backendCalled")` is a reliable, well-defined
signal that no model was called. The alternatives — timing heuristics, response
header sniffing — are guesses; this is a fact about the path the request took.
It is what lets §11 charge zero for a cache hit rather than full price. Anything
added inside `<backend>` must leave this in place.

### §10 — Usage extraction

On the outbound path, reads token counts out of the response. It handles both
the Chat Completions shape and the Responses API shape, because the two report
usage under different field names. Cached and reasoning token counts are picked
up here where the model supplies them.

**The body read is wrapped in a `<choose>` on `isStreaming`, and that is load
bearing.** An expression that reads `context.Response.Body` causes API
Management to buffer the entire response before outbound policy runs — even if
that expression returns early without ever touching the body. An earlier
revision of this policy guarded on `Content-Type`, which meant a streamed
response (`text/event-stream`, never `application/json`) provably never reached
the body read. API Management buffered it anyway. Measured against a live
deployment: Foundry streamed 50 chunks over 0.80 s while the gateway released
all 50 within 1 ms. The buffering decision is made from the policy document, not
from the path taken through it, so the element itself has to be skipped.

Nothing is lost by skipping it. Because of that same `Content-Type` guard, a
streamed request never produced usage here in the first place — the buffering
was pure cost. Streamed requests are recorded `usageMeasured = false` and their
token counts come from `llm-emit-token-metric`, which reads the final SSE chunk
natively.

The general rule, if you extend this policy: **anything that inspects the
response body must be skipped for streaming requests, not merely guarded inside
the expression.**

### §11 — Cost attribution

The arithmetic. The pricing map named value is parsed once per request into
`resolvedRates`, cloned (`DeepClone`) before mutation so that the parsed
document is not corrupted for the context, and used to compute an estimated
cost. Three details are worth knowing:

* An unknown model yields a cost of **`-1.0`**, never `0`. Zero is a plausible
  cost; `-1` is not, so unpriced traffic is detectable by a simple filter
  rather than silently diluting your averages. See
  [cost-attribution.md](cost-attribution.md).
* Numbers are serialised with `ToString("R", InvariantCulture)` so the value
  round-trips exactly and does not acquire a comma decimal separator on a
  differently-localised gateway.
* The section writes the ledger: a `<trace source="ai-gateway">` entry whose
  metadata fields are the schema every alert and the workbook derive from, and
  a response header `x-ai-estimated-cost-usd` formatted `F8`.

When `enable_eventhub_audit` is set, the section closes by writing the **same
record a second time** through `<log-to-eventhub>`, as one compact JSON object
per request. The duplication is deliberate. The trace is sampled and bounded by
the workspace's retention, which is right for operating a gateway and
disqualifying for a number somebody will dispute; the Event Hub copy has
neither constraint. Emitting one from the other, rather than two independently
assembled records, is what stops the dashboards and the audit stream from
disagreeing about what happened.

Remember that Event Hub is a buffer and not an archive — `eventhub_retention_days`
defaults to 7. Land it somewhere durable or the audit trail is theatre.

If you change what the trace emits, you must change **three** things together:
the `<trace>` metadata, the `<log-to-eventhub>` body beside it, and
`local.ledger_query` in `modules/cost-attribution/main.tf`. Miss the third and
the alerts quietly query columns that no longer exist; miss the second and the
audit stream silently drifts from the record everyone else is reading.

### §12 — Governance headers and scrubbing

Adds the `x-ai-*` response headers the operator and the caller use (model
alias, token counts, remaining quota, estimated cost) and deletes three
upstream headers — `x-ms-region`, `azureml-model-session` and
`apim-request-id` — that leak backend topology to the caller.

### `<on-error>`

The error path re-emits as much of the governance envelope as it can. Every
read of a context variable in this section is guarded with `ContainsKey`,
because `<on-error>` can be entered *before* the variable was set — a backend
DNS failure, for example, happens after §1 but an authentication failure may
not. An unguarded read here turns a clean upstream error into an opaque policy
exception, which is a much worse debugging experience than the original fault.

---

## 3. What changes per auth mode

`caller_auth_mode` takes three values. The table below is the whole of the
difference as far as policy is concerned.

| | `subscription_key` | `both` | `entra_id` |
| --- | --- | --- | --- |
| `subscription_required` on the API | true | true | **false** |
| §1b Entra validation emitted | no | yes | yes |
| Product scope evaluated | yes | yes | **no** |
| Product entitlement allow-list enforced | yes | yes | **no** |
| Per-consumer `llm-token-limit` | yes | yes | **no** |
| §5b gateway-wide limit emitted | no | yes | yes |
| `tokens_per_minute` required | no | yes | yes |
| Ledger `consumer` resolves to | subscription id | Entra claim | Entra claim |
| `x-ai-product` response header present | yes | yes | **no** |

That last row is a useful field diagnostic. If you believe you are in `both`
mode but responses carry no `x-ai-product` header, the product scope is not
running and you are effectively in `entra_id` mode.

Internally the module derives two flags —
`local.entra_enabled` (mode is not `subscription_key`) and
`local.subscription_required` (mode is not `entra_id`) — and the template
branches on those rather than on the mode string.

---

## 4. Metric cardinality is a hard ceiling

`llm-emit-token-metric` sits under Azure Monitor custom-metric limits:

* **5 dimensions** maximum per metric
* **100 unique values** per dimension
* **1,000 time series** per metric namespace

The failure mode is the dangerous kind: exceeding any of these causes the
metric data to be **silently discarded**. There is no error, no throttling
response, no entry in a log. Your dashboards simply stop being complete, and
you find out when a number looks wrong weeks later.

The constraint that bites first is the third one, and it is a *product*, not a
sum. Four dimensions with 10 distinct values each is 10,000 series — ten times
over the limit — even though no individual dimension is near its own cap. Do
the multiplication before you add a dimension, using the realistic cardinality
of each existing one in your environment.

This is why the per-consumer identifier is **never** a metric dimension. A
consumer id is unbounded by construction: every new team, application or
service principal adds a value, and the number only ever goes up. Per-consumer
figures come from the trace-based ledger in Log Analytics instead, which has no
cardinality ceiling — it costs ingestion volume rather than silently dropping
data. That split is the subject of
[ADR-0005](decisions/0005-telemetry-sink-selection.md): metrics for cheap,
bounded, alertable aggregates; logs for high-cardinality attribution.

---

## 5. Authoring rules

These four rules are not style preferences. Each one corresponds to a specific
failure that has to be rediscovered painfully if it is not written down.

### Rule 1 — an apostrophe inside a single-quoted attribute terminates it

By convention every policy expression attribute in these templates is delimited
with **single quotes**, so that the embedded C# inside can use ordinary double
quotes for its own string literals:

```xml
<set-variable name='targetPool' value='@(context.Variables.GetValueOrDefault&lt;string&gt;("pool", ""))' />
```

The cost of that convention is that an apostrophe anywhere inside such an
attribute — *including inside a C# comment* — closes the attribute early. A
comment reading

```
// the base entry's rate
```

ends the attribute at `entry`, leaving `s rate` as stray markup. The XML parser
then reports something like:

```
's' is an unexpected token. The expected token is '>' or '/>'.
```

which bears no resemblance to the cause, and points at a line that may be some
distance from the real apostrophe. Write **"of the base entry"** instead. Avoid
possessives and contractions entirely inside attribute values; it costs you a
slightly stiffer comment and saves an afternoon.

### Rule 2 — raw `<`, `>` and `&&` are illegal in attribute values

This is ordinary XML, and it applies to C# generics just as much as to prose.
A declaration must be written entity-escaped:

```xml
Dictionary&lt;string, string&gt;
```

`&&` must be written `&amp;&amp;`. The pragmatic alternative, where the
expression allows it, is to avoid the construct — `var` instead of an explicit
generic, or nested `if` instead of `&&` — but escaping is always available and
is what the existing template does.

### Rule 3 — `terraform validate` cannot see these files

`templatefile()` is evaluated at **plan** time. `terraform validate` never
renders the templates, so it cannot parse the resulting XML and will happily
pass a document that is catastrophically malformed. Neither will `fmt`. A
broken template is discovered either at `plan` — if the breakage happens to be
a Terraform-level error — or at `apply`, by Azure, in the least convenient
place possible.

[`scripts/check_policies.ps1`](../scripts/check_policies.ps1) is the only check
in this repository that catches it. It renders each template through
`terraform console` across a set of representative variable combinations —
full, minimal, Entra-and-both, Entra-only, product and unrestricted-product —
and parses each result with `XmlDocument`, printing the offending line and
hints about apostrophes and unescaped angle brackets when parsing fails.

> **Run `scripts/check_policies.ps1` after every `.tftpl` edit.** It is also
> wired into CI as the `policies` job, so a skipped local run becomes a failed
> pull request rather than a broken deployment — but the local run is seconds
> and the CI round trip is not.

One maintenance obligation comes with it. The script builds its render
expressions from `$llmApiBaseline`, an ordered hashtable of every template
variable. If you introduce a new variable to the template, **add it to
`$llmApiBaseline`** — the script throws `Unknown llm-api template variable` for
anything it does not recognise, which is the good outcome; the bad outcome is
a variable that is in the baseline but no longer in the template, which renders
fine and quietly tests nothing.

### Rule 4 — `indent()` does not indent the first line

Terraform's `indent(n, string)` adds `n` spaces to every line **except the
first**. That is correct behaviour for its intended use — splicing into a line
that already has its prefix — but it means a multi-line literal spliced in with
`indent(12, ...)` must carry its own leading twelve spaces on line one, inside
the literal. If the rendered output has one line sitting oddly at column zero,
this is why.

The practical advice: after changing anything that uses `indent()`, read the
rendered output rather than trusting the template. `check_policies.ps1` can
print it.

---

## 6. `product.xml.tftpl`

Short, and does two things in a deliberate order.

**Entitlement first.** The policy checks the resolved model alias against the
product's allow-list and returns `403 model_not_entitled` if it is absent.
Running this before the token limit means an unentitled request is rejected
without touching the token bucket.

**Then the limit.** `llm-token-limit` keyed on `context.Subscription.Id`, with
the product's configured tokens-per-minute. Note that in API Management's v2
tiers rate-limit counters are scoped per gateway unit and per region: with
multiple units or a multi-region deployment the effective ceiling is the
configured value multiplied by the number of counters, not the configured value
globally. Size accordingly, and treat the number as a guard-rail rather than a
precise budget.

The outbound path adds an `x-ai-product` header. As noted in §3, the absence of
that header is the quickest way to confirm that the product scope did not run.

An "unrestricted" product — one with no allow-list — renders without the
entitlement block entirely; `check_policies.ps1` covers that case separately
because it is a different document, not merely a different value.

---

## 7. Extending the policy safely

A few habits that keep changes from becoming incidents.

**Put configuration in named values, not in the template.** Route tables and
the pricing map are named values precisely so that changing a model price does
not require re-rendering and re-applying a policy document. Several of them are
base64-encoded: raw JSON embedded in the policy would contain double quotes
that terminate the surrounding C# string literal, so the policy decodes at
runtime instead. Keep that pattern for anything JSON-shaped.

**Keep the hot path cheap.** Every element here runs on every request. §11
parses the pricing map in a single pass and clones rather than re-parsing for
exactly this reason. Prefer one pass over a dictionary to repeated lookups, and
prefer a `set-variable` computed once over the same expression repeated in
three attributes.

**Gate new optional components behind a flag, and add the flag to the
baseline.** Follow the pattern of content safety and semantic caching: the
template emits nothing when the feature is off, and `check_policies.ps1` has a
case that exercises both states.

**Never let an optional component fail a request.** An observability or
governance feature that returns 500 when its dependency is unavailable has
converted a nice-to-have into a hard dependency. Guard reads, tolerate missing
fields, and prefer emitting an obviously-wrong sentinel — the `-1` cost is the
model to copy — over throwing.

**Do the cardinality arithmetic before adding a metric dimension.** See §4. The
penalty is silent.

**Keep the trace and `local.ledger_query` in step.** The ledger schema is
defined in exactly one place in `modules/cost-attribution/main.tf` and consumed
by every alert and the workbook. Adding a trace field that the query does not
project means nobody will ever see it; removing one the query does project
breaks all of them at once.

**Re-run `check_policies.ps1`, then read the plan diff.** A policy change shows
up as a replacement of the policy resource body. Reading that diff is the last
opportunity to notice that your edit rendered differently from how you read it.

---

## See also

* [architecture.md](architecture.md) — where these policies sit in the whole design
* [cost-attribution.md](cost-attribution.md) — what §11 produces and what to do with it
* [operations.md](operations.md) — day-2 runbooks, including policy changes that fail to apply
* [ADR-0001 — native backend pools](decisions/0001-native-backend-pools.md)
* [ADR-0005 — telemetry sink selection](decisions/0005-telemetry-sink-selection.md)
* [ADR-0007 — Entra ID caller authentication](decisions/0007-entra-id-caller-authentication.md)
* [`modules/ai-gateway/README.md`](../modules/ai-gateway/README.md) — module inputs and outputs
