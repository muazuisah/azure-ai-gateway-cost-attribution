# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report privately through [GitHub Security Advisories](https://github.com/muazuisah/azure-ai-gateway-cost-attribution/security/advisories/new). Include the affected module or policy, what an attacker gains, and a reproduction if you have one.

Expect an acknowledgement within 5 working days and an assessment within 10.

This is a community accelerator, not a supported Microsoft product. It carries no SLA and is not covered by the Microsoft Security Response Center process. If you believe you have found a vulnerability in **Azure API Management or Microsoft Foundry themselves** — rather than in this Terraform — report it to [MSRC](https://msrc.microsoft.com/create-report) instead, where it will be handled under Microsoft's disclosure policy.

## Scope

In scope:

- Policy logic that could allow authentication or authorisation bypass.
- Terraform that provisions resources materially less secure than documented.
- Secret or token leakage into logs, traces, telemetry, or response headers.
- Cost-attribution logic a caller could manipulate to misattribute their own usage.

Out of scope:

- Vulnerabilities in Azure services themselves (report to MSRC).
- Findings that require subscription Owner rights to exploit.
- Static-analysis output with no demonstrated impact.

## What this accelerator assumes

Adopters should understand these properties, because several are deliberate trade-offs rather than oversights.

**Authentication.** Three caller modes are supported: `subscription_key`, `entra_id`, and `both`. Subscription keys are bearer credentials — possession is authorisation, they do not expire, and they carry no identity beyond the subscription. They are appropriate for service-to-service traffic inside a trust boundary, and weak for anything facing users. Prefer `entra_id` where you can.

In `entra_id` mode the module **requires** at least one of `audiences` or `client_application_ids`. Validating only the tenant and signature accepts any token Entra issued for any application in that tenant, including one the caller obtained for an unrelated resource — a confused-deputy vulnerability. The Terraform refuses to plan without one of these set.

**Policy evaluation order is a security boundary.** APIM evaluates Global → Product → API → Operation. In `entra_id` mode there is no subscription, so APIM cannot resolve a product, so **product-scope policy does not execute at all.** Per-product token limits and model entitlement are therefore unavailable in that mode; the module applies a gateway-wide limit instead and fails the plan if products declare controls that would be silently ignored. Do not assume a product policy is enforcing something it cannot reach.

**Rate-limit counter keys must derive from an already-authenticated principal.** In `both` mode, rate limiting keys on the subscription and attribution keys on the Entra identity. Keying a limit on a claim from a not-yet-validated token would let an attacker inflate another identity's counter and deny them service.

**Backend credentials.** The gateway authenticates to Foundry with managed identity. No model-provider API keys are stored in Terraform state or in APIM named values.

**Cost figures are estimates.** `estimatedCostUSD` is computed from a pricing map against retail list prices. It is for attribution and chargeback signal, not for invoicing. Reconcile against Cost Management before billing anyone.

**Telemetry.** Prompt and completion *content* is not emitted by default. If you enable content logging, you are moving potentially sensitive data into Application Insights — review retention, access, and regional requirements before you do.

## Secrets

`.gitignore` excludes `*.tfvars`, `*.tfstate`, and plan files, because all three routinely contain tenant identifiers, resource names, and secrets. Only `*.tfvars.example` is tracked.

Terraform state contains secrets in plaintext regardless of how carefully variables are handled. Use a remote backend with encryption at rest and access control. Never commit state.

If you believe a secret has been committed, treat it as disclosed: rotate it first, then clean history.
