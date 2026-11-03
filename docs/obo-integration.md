# Per-user attribution with On-Behalf-Of tokens

The gateway attributes cost to the **application** that called it. With user attribution enabled it
also attributes cost to the **person** the application was acting for, provided the application
calls with an Entra **On-Behalf-Of (OBO)** token. This page is the integration guide for the teams
that own consuming applications, and the rollout checklist for the team that owns the gateway.

The reasoning behind the design is in [ADR-0009](decisions/0009-individual-attribution-obo.md).

---

## 1. How the identity is read

An OBO token is a *delegated* token: it is issued to the application, for the gateway's API, on
behalf of a signed-in user. The gateway validates it exactly as in [ADR-0007](decisions/0007-entra-id-caller-authentication.md)
and then reads two levels from the same signature:

| Level | Claim | Ledger field |
| --- | --- | --- |
| Application | `appid` / `azp` (unchanged) | `consumerId` |
| User | `oid` (configurable) | `userId` |
| User's tenant | `tid` | `userTenantId` |

A token is treated as delegated when it carries `scp` or `idtyp = user`. An app-only
(client-credentials) token is recorded as `userType = "app"`; its `oid` belongs to a service
principal and is deliberately not treated as a user.

The gateway never reads a user identity from a header the application controls. An `x-user-id`
header would be whatever the application says it is.

## 2. Gateway owner: expose the API

1. On the gateway's app registration (the one whose Application ID URI is in
   `caller_authentication.audiences`), **expose a delegated scope**, for example
   `api://ai-gateway/Models.Invoke`.
2. On each consuming application's registration, **add that scope as an API permission** and grant
   admin consent (or let users consent, if your tenant allows it).
3. Keep the application role used for app-only access if any workload still calls without a user.

## 3. Application owner: call with an OBO token

The application already holds the user's token for *its own* API. It exchanges that token for one
whose audience is the gateway.

**Python (MSAL)**

```python
import msal
from openai import AzureOpenAI

cca = msal.ConfidentialClientApplication(
    client_id=APP_CLIENT_ID,
    authority=f"https://login.microsoftonline.com/{TENANT_ID}",
    client_credential=APP_SECRET_OR_CERT,  # prefer a certificate or federated credential
)

def gateway_client(user_assertion: str) -> AzureOpenAI:
    result = cca.acquire_token_on_behalf_of(
        user_assertion=user_assertion,               # the incoming user's access token
        scopes=["api://ai-gateway/Models.Invoke"],
    )
    if "access_token" not in result:
        raise RuntimeError(result.get("error_description"))
    return AzureOpenAI(
        azure_endpoint=GATEWAY_URL,
        api_version="2024-10-21",
        azure_ad_token=result["access_token"],
        default_headers={"Ocp-Apim-Subscription-Key": SUBSCRIPTION_KEY},  # only in "both" mode
    )
```

**.NET (Microsoft.Identity.Web)**

```csharp
// Program.cs
builder.Services.AddMicrosoftIdentityWebApiAuthentication(builder.Configuration)
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

// In a controller or service, for the current user:
string token = await _tokenAcquisition.GetAccessTokenForUserAsync(
    new[] { "api://ai-gateway/Models.Invoke" });
```

MSAL caches the exchanged token per user, so this is one token request per user per hour, not one
per model call. Do **not** exchange once and reuse the token across users: every request would be
charged to the first user.

A single-page or native application that signs the user in directly can request the gateway scope
itself; that token is delegated too and needs no OBO step.

### Verify

Every response carries `x-ai-user`:

| Value | Meaning |
| --- | --- |
| an object id | Delegated token; this request is charged to that user. |
| `app` | App-only token; charged to the application only. |
| `unresolved` | Delegated token without the configured user claim. Check `user_claim`. |
| `none` | User attribution is not enabled on the gateway. |

With a per-user limit configured, `x-ai-user-tokens-remaining` shows that user's remaining
allowance. A `429` that carries it is a per-user limit, not an application one.

## 4. Gateway owner: rollout

1. **Enable attribution without enforcement.**

   ```hcl
   caller_authentication = {
     mode      = "both"
     tenant_id = "<tenant-guid>"
     audiences = ["api://ai-gateway"]
     user_attribution = {
       enabled           = true
       require_delegated = false
     }
   }
   ```

   Pass `log_analytics_workspace_id` to the cost-attribution module so streamed requests are
   backfilled (section 6).

2. **Migrate applications one at a time.** The workbook's *Individual attribution coverage by
   application* table shows, per application, the share of tokens attributed to a person, app-only
   and unattributed, so progress is visible.

3. **Watch `unattributed_users`.** The alert fires when an application that has started sending
   delegated tokens still sends more than `unattributed_user_threshold_percent` of its requests
   without a user — the typical sign of a code path that was missed, such as a background job.

4. **Enforce.** When every application is migrated, set `require_delegated = true`. App-only tokens
   are then refused with `403 delegated_token_required`. Leave it off if some workloads genuinely run
   without a user; their cost stays with the application.

5. **Optionally add per-user limits and alerts.**

   ```hcl
   user_attribution = {
     enabled                    = true
     tokens_per_minute_per_user = 20000
     token_quota_per_user       = 2000000
     token_quota_period         = "Daily"
   }
   ```

   The counter is per application + user, so a user's activity in one application does not consume
   their allowance in another. Set `daily_user_spend_threshold_usd` on the cost-attribution module
   to be alerted when any individual's estimated daily spend, across all applications, exceeds it.

## 5. Naming people in reports

The ledger stores object ids only. To show names, departments and cost centres, populate the
cost-attribution module's `users` map:

```hcl
users = {
  "11111111-1111-1111-1111-111111111111" = {
    display_name = "Ada Lovelace"
    department   = "Claims"
    cost_centre  = "CC-1234"
  }
}
```

It is joined at reporting time, so a rename never rewrites history and anyone not listed is still
attributed by object id. The map is embedded in the workbook definition: keep it to what finance
needs. Generate it from Microsoft Graph (`/users?$select=id,displayName,department`) rather than by
hand.

## 6. Streaming

The policy never buffers a streamed response, so it cannot see the usage figures at the end of the
stream; those requests reach the ledger with no tokens. With `enable_llm_logs` on the gateway (the
default when diagnostics are enabled) API Management meters the stream itself and writes
`ApiManagementGatewayLlmLog`. The ledger query joins on the request id and fills in the tokens. Each
ledger row carries `usageSource`:

| `usageSource` | Meaning |
| --- | --- |
| `policy` | Measured by the gateway policy (non-streamed). |
| `llmlog` | Backfilled from the LLM log (typically streamed). |
| `none` | No usage from either source — a failed call, or a broken stream. |

Backfilled prompts carry no cached-token split, so they are priced at the full input rate.

## 7. Privacy

- Only the object id and tenant id are recorded — not the UPN, name or email.
- No prompt or completion content is logged by this feature. The LLM log diagnostic is configured
  without request or response message logging.
- An object id is still personal data. Review retention and access on the Application Insights and
  Log Analytics resources before enabling, and tell users their usage is attributed.

## 8. First-deployment checks

Each of these was verified against a live deployment of `examples/03-cost-attribution`, called by a
regular member user with a delegated token (results in
[validation §3b](validation.md#3b-per-user-attribution)). Re-run them on every new environment:

1. **LLM log rows exist.** After a streamed call, `ApiManagementGatewayLlmLog | take 10` in the
   workspace returns rows with `PromptTokens` and `CompletionTokens`. Allow 5–10 minutes.
2. **The join key matches.** For one call, the ledger's `requestId` equals the LLM log's
   `CorrelationId`. If it does not, `usageSource` stays `none` for streamed rows. (Verified: the
   streamed row was backfilled with `usageSource = "llmlog"` and the same 31 tokens as the
   equivalent non-streamed call.)
3. **The diagnostic setting applied cleanly.** If an existing diagnostic setting already sends
   `GatewayLogs` to the same workspace, Azure may reject a second one for the same category; remove
   or import the existing setting.
4. **Alerts evaluate.** The ledger alerts are scoped to Application Insights and use a
   cross-resource `workspace()` query; confirm the rules show as healthy in Azure Monitor.
5. **`x-ai-user` and the workbook agree.** The object id in the header appears in the
   workbook's *Allocation by individual* section under the right application.
6. **The audience matches.** A v2 access token carries the gateway application's client id (a bare
   GUID) in `aud`, not the `api://` URI. List both in `caller_authentication.audiences`, or every
   delegated call fails `401`.

For a quick smoke test without writing an application, sign in as an ordinary user and use the
Azure CLI as the consuming application. [`scripts/call_as_user.py`](../scripts/call_as_user.py)
does this for you: it gets the delegated token, shows whose it is, sends chat, streamed and
embedding calls, and fails unless every response's `x-ai-user` is the signed-in user:

```bash
export AI_GATEWAY_ENDPOINT=https://<apim>.azure-api.net/<path>/openai/v1
export AI_GATEWAY_KEY=<subscription-key>          # omit in Entra-only mode
export AI_GATEWAY_APP_ID=<gateway-app-client-id>
az login
python scripts/call_as_user.py

# As someone else, without signing yourself out: a separate CLI profile per person.
python scripts/call_as_user.py --az-config-dir ~/.uca/alice --login --device-code --tenant <tenant-id>
python scripts/call_as_user.py --az-config-dir ~/.uca/alice --repeat 3 --brief
```

Open the device-code page in a private browser window so it does not sign you in as yourself.
The script needs only Python and the Azure CLI, and exits non-zero on any failed or
mis-attributed call. The same check by hand:

```bash
az login
TOKEN=$(az account get-access-token --resource <gateway-app-client-id> --query accessToken -o tsv)
curl https://<apim>.azure-api.net/<path>/openai/v1/chat/completions \
  -H "api-key: <subscription-key>" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"chat","messages":[{"role":"user","content":"hello"}]}' -i
```

The response's `x-ai-user` is your object id and `x-ai-consumer` is the Azure CLI's application id.
