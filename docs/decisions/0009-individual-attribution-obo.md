# ADR-0009: Individual cost attribution from On-Behalf-Of tokens

- **Status:** Accepted
- **Date:** 2026-11-02
- **Supersedes:** nothing
- **Related:** ADR-0004 (the ratio allocation this extends to a second level), ADR-0005 (why the user is on the ledger and not on the token metric), ADR-0007 (the Entra validation this builds on)

## Context

Attribution stopped at the application. A consuming application — a claims assistant, an internal
copilot — was charged for its tokens, and that was the finest grain the ledger could express. For a
shared application with hundreds of users that is not enough: the application owner cannot tell
whether spend is broad adoption or three people running batch jobs through a chat window, and finance
cannot charge a department that uses a central application.

Three facts constrain any solution:

1. **The identity must be unforgeable.** A header such as `x-user-id` set by the application is
   whatever the application says it is. It cannot be the basis of a bill.
2. **The application identity must not be lost.** Per-user cost is a refinement of per-application
   cost, not a replacement for it. Application owners still need their own number.
3. **Streaming is the common case for user-facing applications**, and the ledger records streamed
   requests with no tokens, because the policy deliberately never buffers a stream (see §10 of the
   [policy reference](../policies.md)). A user dimension that silently omits every streamed request
   would be worse than none: it would look complete.

## Decision

**Consuming applications call the gateway with an On-Behalf-Of (OBO) token** — a delegated token the
application obtains for its signed-in user, with the gateway's API as audience. The gateway already
validates Entra tokens (ADR-0007). In a delegated token `appid`/`azp` is still the calling
application, so the existing consumer resolution is unchanged; the user is the token's `oid` and the
tenant its `tid`. One validated credential yields both levels, and neither can be spoofed.

- **Only delegated tokens name a person.** A token is delegated when it carries `scp` or declares
  `idtyp = user`. An app-only token's `oid` is a service principal; it is recorded as
  `userType = "app"` with no user rather than being charged as if it were a human.
- **The object id, never the UPN.** It is immutable, survives renames and is not contact data.
  Names, departments and cost centres are joined at reporting time from the cost-attribution
  module's `users` map.
- **The ledger moves to schema 3**, adding `requestId`, `userId`, `userTenantId` and `userType`.
  The fields are always present (`none` when the feature is off) so reports never special-case a
  missing column, and schema 2 rows simply land in an `(unattributed)` bucket.
- **Allocation is two-level.** The invoice is split across applications by token share exactly as
  ADR-0004 describes, then each application's portion across its users by their share of that
  application's tokens. Application-level numbers are identical with or without the second level.
  Traffic without a user stays with its application under an explicit `(app-only)` or
  `(unattributed)` row instead of vanishing.
- **Streamed usage is backfilled from API Management's own LLM logs.** The gateway enables
  `GatewayLlmLogs` and API-level LLM logging (token counts only, never message content). API
  Management meters the stream natively and writes `ApiManagementGatewayLlmLog` rows keyed by the
  same request id the ledger now records. The shared ledger query joins the two, fills in tokens for
  rows the policy could not measure, reprices them from the same rate card, and marks each row with
  `usageSource` = `policy`, `llmlog` or `none`. The hot path is untouched: no stream is buffered.
- **Per-user limits are optional and counted per application + user pair**, so one person cannot
  exhaust a shared application's allowance, and two application owners budget independently.
- **Rollout is staged by `require_delegated`.** Off, app-only traffic is accepted and visible as
  `(app-only)`. Once every application sends OBO tokens, turning it on refuses app-only tokens with
  `403 delegated_token_required`, so nothing can escape user attribution.

## Consequences

### Positive

- Per-user chargeback rests on a signed token, not on application-supplied metadata.
- Streaming no longer creates a blind spot, for users or for applications. `unmeasured_usage` falls
  for every consumer, not only the ones that adopt OBO, because the backfill applies to the whole
  ledger.
- The application view is unchanged, so the feature can be adopted one application at a time.

### Negative and accepted

- **Applications must adopt OBO.** That is a code change in every consuming application: exposing a
  scope on the gateway's app registration, and calling `acquire_token_on_behalf_of` (or equivalent)
  per user. See the [integration guide](../obo-integration.md).
- **Resource-specific diagnostic tables.** `GatewayLlmLogs` are only written to the resource-specific
  table, so enabling them switches the diagnostic setting to `Dedicated` mode. `GatewayLogs` move
  from `AzureDiagnostics` to `ApiManagementGatewayLogs`. Nothing in this repository queries the
  legacy table, but an operator's own queries might. `enable_llm_logs = false` keeps the old
  behaviour and forgoes the backfill.
- **The backfill is an approximation in two ways.** The LLM log reports prompt and completion
  tokens but no cached-token split, so a backfilled prompt is priced at the full input rate (an
  over-estimate when prompt caching applies, which ratio allocation then corrects in aggregate). And
  API Management documents that a broken or terminated stream may log incomplete usage.
- **User identifiers are personal data.** An object id is pseudonymous, not anonymous. Retention and
  access on the Application Insights and Log Analytics resources must be reviewed accordingly. No
  prompt or completion content is logged by this feature.
- **No user dimension on the token metric.** Same reasoning as ADR-0005: per-user cardinality would
  exhaust the custom-metric dimension limit. Per-user reporting comes from the ledger.

## Alternatives considered

**A trusted header set by the application** (`x-user-id`). Rejected: unverifiable. It reduces a
chargeback to the application's say-so, and a single misconfigured client charges the wrong person.

**Signed user assertions in a custom header.** Rejected: re-implements OBO with weaker tooling and a
second key to manage.

**Replacing the application identity with the user.** Rejected: loses the application dimension that
existing chargeback depends on, and makes app-only traffic unattributable.

**Parsing streamed responses in policy to capture usage.** Rejected: reading the body buffers the
stream, destroying time-to-first-token — the reason a client streams in the first place.

**Requiring `stream_options.include_usage` and parsing only the final chunk.** Rejected for the same
reason: the policy still has to read the body to find the chunk.
