<#
.SYNOPSIS
    Renders the API Management policy templates and checks that the result is well-formed XML.

.DESCRIPTION
    `terraform validate` does not evaluate templatefile(), so a policy template can be syntactically
    invalid XML and still pass validation - the failure only appears at apply time, as an opaque
    rejection from API Management. This script closes that gap and is wired into CI.

    The usual offenders are C# expressions inside XML attributes: `<`, `&&` and nested double quotes
    are all illegal in attribute values and must be escaped or re-delimited.
#>
[CmdletBinding()]
param(
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'

if (-not $ModulePath) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
    # Build the path segment by segment: a literal '..\modules\ai-gateway'
    # resolves as one oddly-named file on Linux CI runners.
    $ModulePath = Join-Path (Join-Path (Split-Path -Parent $root) 'modules') 'ai-gateway'
}
$module = (Resolve-Path $ModulePath).Path
$temp = [System.IO.Path]::GetTempPath()

if (-not (Test-Path (Join-Path $module '.terraform'))) {
    Write-Host 'Initialising provider schemas...'
    Push-Location $module
    terraform init -backend=false -no-color | Out-Null
    Pop-Location
}

# The llm-api template has enough independent feature flags that spelling every argument out per case
# is unreadable and drifts the moment a variable is added. Cases override a baseline instead, so a new
# template variable is declared once.
$llmApiBaseline = [ordered]@{
    environment_name                     = '"dev"'
    environment_named_value              = '"env"'
    routes_named_value                   = '"routes"'
    pricing_named_value                  = '"pricing"'
    metric_namespace                     = '"aigateway"'
    backend_auth_resource                = '"https://cognitiveservices.azure.com"'
    forward_timeout_seconds              = '240'
    buffer_response                      = 'false'
    enable_cost_attribution              = 'true'
    enable_content_safety                = 'true'
    content_safety_backend_id            = '"content-safety"'
    content_safety_shield_prompt         = 'true'
    content_safety_max_characters        = '10000'
    content_safety_threshold_hate        = '4'
    content_safety_threshold_self_harm   = '4'
    content_safety_threshold_sexual      = '4'
    content_safety_threshold_violence    = '4'
    enable_semantic_cache                = 'true'
    semantic_cache_max_temperature       = '0.3'
    semantic_cache_score_threshold       = '0.05'
    semantic_cache_max_message_count     = '10'
    semantic_cache_duration_seconds      = '3600'
    semantic_cache_embeddings_backend_id = '"foundry-eastus"'
    entra_enabled                        = 'false'
    entra_tenant_id                      = '"organizations"'
    entra_header_name                    = '"Authorization"'
    entra_failed_httpcode                = '401'
    entra_audiences                      = '[]'
    entra_client_application_ids         = '[]'
    entra_required_claims                = '[]'
    entra_claim_order                    = '["appid","azp","oid","sub"]'
    entra_consumer_names                 = '{}'
    entra_gateway_token_limit            = 'null'
    enable_eventhub_audit                = 'true'
    audit_logger_name                    = '"audit-logger"'
}

function New-LlmApiExpr {
    param([hashtable]$Override = @{})

    # OrderedDictionary has no Clone(), and a shallow copy is needed so cases cannot leak into
    # each other.
    $templateVars = [ordered]@{}
    foreach ($key in $llmApiBaseline.Keys) { $templateVars[$key] = $llmApiBaseline[$key] }
    foreach ($key in $Override.Keys) {
        if (-not $templateVars.Contains($key)) {
            throw "Unknown llm-api template variable '$key'. Add it to `$llmApiBaseline first."
        }
        $templateVars[$key] = $Override[$key]
    }

    $pairs = ($templateVars.Keys | ForEach-Object { "$_ = $($templateVars[$_])" }) -join ', '
    return 'base64encode(templatefile("${path.module}/policies/llm-api.xml.tftpl", { ' + $pairs + ' }))'
}

$cases = @(
    @{
        Name = 'llm-api'
        Expr = New-LlmApiExpr
    },
    @{
        # Every optional feature off. Catches template blocks that depend on a variable only set by
        # another feature's branch.
        Name = 'llm-api-minimal'
        Expr = New-LlmApiExpr @{
            enable_cost_attribution              = 'false'
            enable_content_safety                = 'false'
            content_safety_backend_id            = '""'
            content_safety_shield_prompt         = 'false'
            enable_semantic_cache                = 'false'
            semantic_cache_embeddings_backend_id = '""'
            enable_eventhub_audit                = 'false'
        }
    },
    @{
        # Cost attribution on, audit stream off. The log-to-eventhub element is nested inside the
        # cost-attribution block, so this is the permutation that catches an unbalanced directive
        # between the two.
        Name = 'llm-api-cost-no-audit'
        Expr = New-LlmApiExpr @{
            enable_eventhub_audit = 'false'
        }
    },
    @{
        # Cost attribution on, semantic caching off. Cache-hit detection and the savings calculation
        # live in the cost block but are fed by a variable the semantic-cache branch defines, so this
        # is the permutation where that variable has to come from the fallback instead.
        Name = 'llm-api-cost-no-cache'
        Expr = New-LlmApiExpr @{
            enable_semantic_cache                = 'false'
            semantic_cache_embeddings_backend_id = '""'
        }
    },
    @{
        # mode = "both": Entra validation on, subscription still required, no gateway-wide limit.
        Name = 'llm-api-entra-both'
        Expr = New-LlmApiExpr @{
            entra_enabled                = 'true'
            entra_tenant_id              = '"00000000-0000-0000-0000-000000000001"'
            entra_audiences              = '["api://ai-gateway"]'
            entra_client_application_ids = '["00000000-0000-0000-0000-000000000002"]'
            entra_consumer_names         = '{ "00000000-0000-0000-0000-000000000002" = "claims-assistant" }'
        }
    },
    @{
        # mode = "entra_id": no subscription, so the gateway-wide token limit and required-claims
        # rendering both have to be exercised.
        Name = 'llm-api-entra-only'
        Expr = New-LlmApiExpr @{
            entra_enabled             = 'true'
            entra_tenant_id           = '"00000000-0000-0000-0000-000000000001"'
            entra_header_name         = '"X-Gateway-Token"'
            entra_failed_httpcode     = '403'
            entra_audiences           = '["api://ai-gateway"]'
            entra_required_claims     = '[{ name = "roles", match = "any", separator = null, values = ["Gateway.Invoke"] }, { name = "groups", match = "all", separator = " ", values = ["g1","g2"] }]'
            entra_claim_order         = '["appid","oid"]'
            entra_gateway_token_limit = '200000'
        }
    },
    @{
        Name = 'product'
        Expr = @'
base64encode(templatefile("${path.module}/policies/product.xml.tftpl", { product_key = "gold", allowed_models = ["gpt-chat","embed"], tokens_per_minute = 100000, token_quota = 5000000, token_quota_period = "Monthly", estimate_prompt_tokens = true }))
'@
    },
    @{
        Name = 'product-unrestricted'
        Expr = @'
base64encode(templatefile("${path.module}/policies/product.xml.tftpl", { product_key = "free", allowed_models = [], tokens_per_minute = 1000, token_quota = null, token_quota_period = "Monthly", estimate_prompt_tokens = true }))
'@
    }
)

Push-Location $module
$failed = 0
foreach ($case in $cases) {
    $b64 = ($case.Expr | terraform console -no-color 2>&1) -join '' 
    $b64 = $b64.Trim().Trim('"')

    if ($b64 -notmatch '^[A-Za-z0-9+/=]+$') {
        Write-Host "[FAIL] $($case.Name): template did not render" -ForegroundColor Red
        Write-Host $b64
        $failed++
        continue
    }

    $xml = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    $out = Join-Path $temp "$($case.Name).rendered.xml"
    [System.IO.File]::WriteAllText($out, $xml, [System.Text.UTF8Encoding]::new($false))

    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xml)
        $sections = ($doc.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { $_.Name }) -join ', '

        # Well-formed XML is necessary but nowhere near sufficient. API Management only allows a
        # restricted set of .NET types inside policy expressions and rejects the entire document if
        # one is used, with an error that never reaches the Terraform output:
        #
        #   Usage of type 'System.Globalization.CultureInfo' is not supported within expressions
        #
        # That rejection arrives from the service, so it surfaces only during apply - and only for
        # the feature permutations that actually render the offending element, which is how an
        # InvariantCulture argument sat in the cost-attribution path while every quickstart deploy
        # passed. Catching the known-banned types by name here costs milliseconds and turns a
        # three-quarter-hour round trip into an immediate failure.
        $bannedTypes = @(
            'System.Globalization',
            'System.Reflection',
            'System.IO',
            'System.Threading',
            'System.Diagnostics',
            'System.Environment',
            'System.AppDomain'
        )
        # Scan the policy with comments removed. A comment that explains why a type is banned names
        # that type, and matching it would fail the very document that documents the rule. Each
        # comment is replaced by the newlines it spanned so reported line numbers still line up with
        # the rendered file on disk.
        $stripped = [regex]::Replace($xml, '(?s)<!--.*?-->', {
                param($m)
                "`n" * ([regex]::Matches($m.Value, "`n").Count)
            })
        $strippedLines = $stripped -split "`n"

        $hits = foreach ($banned in $bannedTypes) {
            if ($stripped -match [regex]::Escape($banned)) { $banned }
        }
        if ($hits) {
            Write-Host "[FAIL] $($case.Name): uses .NET types API Management forbids in expressions" -ForegroundColor Red
            foreach ($hit in $hits) {
                for ($i = 0; $i -lt $strippedLines.Count; $i++) {
                    if ($strippedLines[$i].Contains($hit)) {
                        Write-Host "       $hit on line $($i + 1): $($strippedLines[$i].Trim())" -ForegroundColor Red
                        break
                    }
                }
            }
            Write-Host "       rendered output written to $out"
            Write-Host "       the allowed list is at https://learn.microsoft.com/azure/api-management/api-management-policy-expressions#CLR-types" -ForegroundColor DarkGray
            Write-Host "       for invariant number formatting just drop the culture argument - policy" -ForegroundColor DarkGray
            Write-Host "       expressions already format with the invariant culture." -ForegroundColor DarkGray
            $failed++
            continue
        }

        # Every context.Variables[...] read must have a matching writer somewhere in the SAME rendered
        # document. This is a per-permutation check by necessity: the template is a web of feature
        # flags, and it is easy to place a reader outside the conditional block that defines what it
        # reads. The full-feature render then looks perfect while a narrower flag combination emits a
        # policy that throws at runtime - and it throws per request, in outbound, after the model has
        # already been paid for, which is close to the worst place to discover it.
        #
        # Writers are not only set-variable: several built-in policies declare a variable through their
        # own attributes, so those count too.
        $readNames = [regex]::Matches($stripped, 'context\.Variables\[\s*"([^"]+)"\s*\]') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $writtenNames = @(
            [regex]::Matches($stripped, '<set-variable\s+name\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches($stripped, 'output-token-variable-name\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches($stripped, '\bvariable-name\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        ) | Sort-Object -Unique

        # ContainsKey is the sanctioned way to probe for a variable that legitimately may not exist,
        # so a name reached only that way is not a missing writer.
        $probedNames = [regex]::Matches($stripped, 'context\.Variables\.ContainsKey\(\s*"([^"]+)"\s*\)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $undefined = $readNames | Where-Object { $_ -notin $writtenNames -and $_ -notin $probedNames }
        if ($undefined) {
            Write-Host "[FAIL] $($case.Name): reads policy variables that this permutation never sets" -ForegroundColor Red
            foreach ($name in $undefined) {
                $line = ($strippedLines | Select-String -SimpleMatch "context.Variables[`"$name`"]" | Select-Object -First 1)
                Write-Host "       $name$(if ($line) { ": $($line.Line.Trim())" })" -ForegroundColor Red
            }
            Write-Host "       rendered output written to $out"
            Write-Host "       the reader is probably outside the %{ if } block that defines it - either" -ForegroundColor DarkGray
            Write-Host "       gate the reader the same way, or give the variable a fallback in an else." -ForegroundColor DarkGray
            $failed++
            continue
        }

        # A backend section accepts exactly one policy. Well-formed XML and every variable resolved is
        # not enough to know that: the rule is API Management's, not the schema's, so a second element
        # here renders cleanly, passes every check above, and is then refused by the service with
        # "backend section allows only one policy to be specified" - at apply time, against a gateway
        # that has already been built. Wrap the extra statements in a single <choose> instead.
        $backendNode = $doc.SelectSingleNode('/policies/backend')
        if ($backendNode) {
            $backendChildren = @($backendNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
            if ($backendChildren.Count -gt 1) {
                Write-Host "[FAIL] $($case.Name): backend section has $($backendChildren.Count) policies; API Management allows one" -ForegroundColor Red
                foreach ($child in $backendChildren) {
                    Write-Host "       <$($child.Name)>" -ForegroundColor Red
                }
                Write-Host "       rendered output written to $out"
                Write-Host "       wrap them in a single <choose><when condition='@(true)'> ... </when></choose>," -ForegroundColor DarkGray
                Write-Host "       which is one policy to the validator and leaves execution order unchanged." -ForegroundColor DarkGray
                $failed++
                continue
            }
        }

        Write-Host "[ OK ] $($case.Name): $($xml.Length) chars, sections: $sections" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAIL] $($case.Name): $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       rendered output written to $out"

        # Point at the offending line, and name the two mistakes that cause almost all of these.
        # Policy attributes here are delimited with single quotes so C# can use double quotes, which
        # means an apostrophe in a code comment silently terminates the attribute - and the parser
        # error it produces ("'s' is an unexpected token") does not resemble the cause at all.
        if ($_.Exception.Message -match 'Line (\d+), position (\d+)') {
            $lineNo = [int]$Matches[1]
            $lines = $xml -split "`n"
            if ($lineNo -le $lines.Count) {
                Write-Host "       line $lineNo : $($lines[$lineNo - 1].Trim())" -ForegroundColor DarkYellow
            }
        }
        Write-Host "       usual causes: an apostrophe inside a single-quoted attribute (write 'does" -ForegroundColor DarkGray
        Write-Host "       not' as 'does not'), or a raw <, > or && in an attribute value - these need" -ForegroundColor DarkGray
        Write-Host "       &lt; &gt; &amp;&amp;, including inside C# generics such as Dictionary&lt;string, string&gt;." -ForegroundColor DarkGray
        $failed++
    }
}
Pop-Location

if ($failed -gt 0) {
    Write-Host "`n$failed policy template(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll policy templates render to well-formed XML." -ForegroundColor Green
