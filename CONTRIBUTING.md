# Contributing

Thanks for considering a contribution. This repository is an accelerator: people copy it into environments that bill real money and serve real users, so the bar for changes is "someone can adopt this without reading the diff."

## Getting set up

You need:

| Tool | Version | Why |
|---|---|---|
| Terraform | >= 1.9 | `required_version` across all modules |
| Python | >= 3.9 | Pricing scripts and the test suite |
| PowerShell | 5.1 or PowerShell 7+ | `scripts/check_policies.ps1` |
| Azure CLI | any recent | Only for live deployment, not for tests |

The Python test suite uses the standard library only — no virtualenv, no `pip install`. That is deliberate, and please keep it that way: a contributor should be able to clone and run the tests in one command.

```bash
git clone https://github.com/muazuisah/azure-ai-gateway-cost-attribution.git
cd azure-ai-gateway-cost-attribution
python -m unittest discover -s tests
```

## The checks

Run all four before opening a pull request. CI runs the same ones.

```bash
terraform fmt -check -recursive -diff
./scripts/check_policies.ps1          # pwsh on Linux/macOS
python -m unittest discover -s tests
tflint --recursive --minimum-failure-severity=error
```

Plus `terraform validate` in each module and example. CI iterates all eight.

### Why `check_policies.ps1` is not optional

`terraform validate` **cannot see inside your policy templates.** `templatefile()` is evaluated at plan time, so a malformed `.tftpl` validates perfectly and then fails on apply against a live APIM instance — or worse, applies a policy that does not do what you think.

`scripts/check_policies.ps1` renders every template through `terraform console` across the full matrix of feature-flag permutations and parses the result as XML. **If you touch a `.tftpl`, run it.** If you add a template variable, add it to `$llmApiBaseline` in that script.

Two failure modes bite repeatedly, and neither error message resembles its cause:

1. **A raw `<` or `>` in an attribute value** — including inside C# generics. `Dictionary<string, string>` must be written `Dictionary&lt;string, string&gt;`. Same for `&&`.
2. **An apostrophe inside a single-quoted attribute** terminates the attribute. A contraction in a code comment — `the base entry's rate` — will break the render with an error like `'s' is an unexpected token`.

Policy attributes use single-quote delimiters by convention so that the embedded C# can use ordinary double quotes. The cost of that convention is the apostrophe rule. Write "of the base entry" rather than "the base entry's".

## Pricing data

Anything touching cost must follow one rule: **never guess a number that could be wrong in the cheap direction.**

Under-reporting cost is far more damaging than reporting none, because a plausible-looking wrong number gets trusted and billed against. So:

- Unknown model → cost `-1` ("unpriced"), never `0`.
- Unknown unit of measure → `None`, never an assumed default.
- Unknown context threshold → no tier, plus a warning.
- Within a matched pricing tier, rates never inherit from the base entry. A tier that omits `cachedInput` falls back to *its own* input rate, not the base entry's cheaper cached rate.

Azure's meter names are genuinely inconsistent (`Inp`/`Inpt`/`Input`, `Outp`/`outpt`/`opt`, `cchd`/`cd`). Every parsing rule in `scripts/_pricing_meters.py` exists because a real meter broke without it, and each is pinned by a test. If you relax one, expect to explain which meter motivated it.

## Changes that need an ADR

Architecture decisions live in `docs/decisions/`. Write one when a change:

- alters the trust boundary or authentication model,
- changes how cost is calculated or attributed,
- picks between two defensible approaches where the loser has real merit,
- or constrains what adopters can do later.

Follow the existing format. The valuable part is **Consequences** — specifically what the decision costs, not just what it buys. An ADR that lists only benefits is not describing a decision.

## Pull requests

- One logical change per PR.
- Update docs in the same PR. A feature whose documentation lands later is a feature nobody finds.
- If you change module inputs or outputs, update the example that exercises them.
- Call out anything you could not verify. "I could not test the private-endpoint path" is useful; silence is not.

Commits use the imperative mood: "Add context-length pricing tiers", not "Added".

## What has not been verified

Be aware when building on this: the modules pass `validate`, the policies render, and the tests pass, but coverage ends where a real subscription begins. If you deploy and something behaves differently, that is a genuinely valuable issue to open — please include the Terraform version, provider versions, and APIM SKU.
