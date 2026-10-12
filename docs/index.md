---
description: >-
  How to run Azure API Management as a centralised AI Gateway in front of
  Microsoft Foundry and Azure OpenAI deployments, and how to attribute token
  cost to the applications that spent it. Reference architecture, decision
  records and production-grade Terraform.
---

# Azure AI Gateway & Cost Attribution for Microsoft Foundry

Two problems show up on nearly every enterprise Azure OpenAI engagement, and they are usually solved separately and badly.

**The first is control.** Model deployments multiply across regions and subscriptions, each with its own endpoint and key. A model name ends up hard-coded into dozens of services, so upgrading from one model version to the next becomes a coordinated release across every team that calls it.

**The second is cost.** The Azure bill shows what Foundry cost. It does not show which application spent it, because every request arrives at the model with the same managed identity. Finance asks "what did each team spend on AI last month?" and there is no defensible answer.

This project is the reference architecture and Terraform for solving both, as two layers in one codebase.

---

## Layer 1 — the AI Gateway

Azure API Management as a single governed entry point for every Foundry deployment.

- **Logical model aliases.** Clients call `gpt-chat`, never `gpt-4o-eastus-prod-v3`. A model upgrade becomes a gateway change instead of forty pull requests.
- **Native backend pools** with priority groups and per-backend circuit breakers. Provisioned throughput first, automatic spillover to pay-as-you-go, automatic cross-region failover.
- **No keys.** The gateway authenticates to Foundry with its managed identity, and Foundry accounts run with local authentication disabled, so key access is not merely discouraged but impossible.
- **Entra ID caller authentication**, so the gateway knows *which application* is calling rather than only *that a valid key was presented*.
- **Token governance** — per-product rate limits and period quotas.

[Read the architecture →](architecture.md)

## Layer 2 — cost attribution and chargeback

Per-request token accounting, turned into a number finance will accept.

- Token accounting across **input, cached input, cache write, output and reasoning** classes, which are priced differently and are the usual source of quiet errors.
- Rates generated from the **Azure Retail Prices API**, versioned, rather than transcribed by hand.
- **Ratio allocation against Azure Cost Management.** Gateway telemetry decides *who*, Azure decides *how much*. The result is immune to enterprise discounts, reservations and provisioned-throughput amortisation — the three things that make naive per-token estimates wrong.

[Read the cost attribution guide →](cost-attribution.md)

---

## Documentation

| Document | What it covers |
| --- | --- |
| [Architecture](architecture.md) | Topology, request flow, network design, and an honest list of limitations |
| [Cost attribution](cost-attribution.md) | The ledger schema, allocation maths, and the reconciliation loop |
| [Policies](policies.md) | The APIM policy pipeline section by section, and the authoring rules |
| [Operations](operations.md) | Day-2: regenerating the pricing map, adding models, troubleshooting |
| [Decision records](decisions/) | Eight ADRs explaining why each trade-off was made |

## Source

The Terraform, policies and examples live on GitHub:
**[muazuisah/azure-ai-gateway-cost-attribution](https://github.com/muazuisah/azure-ai-gateway-cost-attribution)**

Three worked examples ship with it: a single-region quickstart, a production profile with private endpoints and multi-region backends, and a full chargeback deployment.

---

*This is a personal project. It is not a Microsoft product, it is not endorsed by or affiliated with Microsoft, and it carries no support commitment. Opinions here are my own and do not represent the positions, strategies, or opinions of my employer. Microsoft, Azure, Microsoft Foundry and Azure OpenAI Service are trademarks of the Microsoft group of companies.*
