---
title: Architecture decision records
description: >-
  Why this Azure AI Gateway is built the way it is: nine architecture decision
  records covering backend pools, managed identity, cost allocation, telemetry
  sinks, alias routing, Entra ID authentication, context-length pricing and
  per-user attribution.
---

# Architecture decision records

Each record states the decision, the alternatives that were rejected, and the consequences accepted in exchange. They exist because the reasoning behind an infrastructure choice is usually more valuable than the choice itself — and is the first thing lost when a project changes hands.

| ADR | Decision |
| --- | --- |
| [0001](0001-native-backend-pools.md) | Native backend pools instead of retry-driven backend selection |
| [0002](0002-managed-identity-only.md) | Managed identity only for gateway-to-Foundry access |
| [0003](0003-azapi-for-backend-pools.md) | The `azapi` provider for backend pools |
| [0004](0004-ratio-allocation-chargeback.md) | Ratio allocation of actual spend, not gateway-estimated dollars |
| [0005](0005-telemetry-sink-selection.md) | Telemetry sink selection — custom metrics *and* a trace ledger |
| [0006](0006-alias-routing-vs-unified-model-api.md) | Alias routing on GA primitives, not the preview unified model API |
| [0007](0007-entra-id-caller-authentication.md) | Microsoft Entra ID for caller authentication and cost attribution |
| [0008](0008-context-length-pricing-tiers.md) | Context-length pricing tiers |
| [0009](0009-individual-attribution-obo.md) | Individual cost attribution from On-Behalf-Of tokens |

[← Back to documentation home](../)
