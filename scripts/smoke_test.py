#!/usr/bin/env python3
"""Exercise a deployed AI gateway end to end and print a pass/fail table.

Why this exists
---------------
`terraform apply` finishing successfully tells you the resources exist. It does not tell you that a
request survives the trip through the policy pipeline: that the alias resolved to a deployment, that
the managed identity was accepted by Foundry, that token accounting fired, or that streaming was not
quietly buffered into a single chunk by a well-meaning policy. Those are the failures that reach an
application team as "it works but it's slow" three weeks later.

This runs the checks a human would run by hand, in order, and tells you which layer broke.

What a failure means
--------------------
    auth-required      Credential enforcement is off. The gateway is open. Stop and fix this first.
    discovery          The API is published but the catalogue is empty or unreachable.
    chat               The request did not survive the pipeline. The body of the failure is printed.
    alias-routing      The alias indirection is not working, so you cannot swap models underneath.
    streaming          Tokens are not arriving incrementally; something is buffering the response.
    token-headers      Token governance is not attached, so quotas and chargeback see nothing.

Usage
-----
    # Subscription key, flags (this is what the Terraform output prints)
    python smoke_test.py --base-url https://foo.azure-api.net/openai/v1 \\
        --api-key "$(terraform output -raw demo_subscription_key)" --model chat-small

    # Subscription key, environment
    export AI_GATEWAY_ENDPOINT=$(terraform output -raw openai_base_url)
    export AI_GATEWAY_KEY=$(terraform output -raw demo_subscription_key)
    python smoke_test.py

    # Entra ID caller authentication - borrows a token from the Azure CLI
    python smoke_test.py --base-url https://foo.azure-api.net/openai/v1 --entra

Exit status is 0 only if nothing failed. Skipped checks do not fail the run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Tuple

PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"

# Emitted by the product-scope policy (subscription-key mode) and by the gateway-scope limit
# (Entra mode) respectively. In Entra mode there is no subscription, therefore no product, therefore
# the product policy never runs - so which pair appears tells you which path you are actually on.
TOKEN_HEADERS_SUBSCRIPTION = ("x-ai-remaining-tokens", "x-ai-remaining-quota-tokens")
TOKEN_HEADERS_ENTRA = ("x-ai-tokens-remaining", "x-ai-tokens-consumed")

GOVERNANCE_HEADERS = ("x-ai-model-alias", "x-ai-deployment", "x-correlation-id")


class Result:
    def __init__(self, name: str, status: str, detail: str = "") -> None:
        self.name = name
        self.status = status
        self.detail = detail


class Gateway:
    """Minimal OpenAI-compatible client. Standard library only, on purpose: a smoke test that needs
    its own dependency tree is one more thing that can fail for reasons unrelated to the gateway."""

    def __init__(self, base_url: str, timeout: int, api_key: Optional[str] = None,
                 token: Optional[str] = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.api_key = api_key
        self.token = token

    def _headers(self, authenticated: bool = True) -> Dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if authenticated:
            if self.token:
                headers["Authorization"] = "Bearer " + self.token
            elif self.api_key:
                headers["api-key"] = self.api_key
        return headers

    def request(self, path: str, payload: Optional[Dict[str, Any]] = None, method: str = "POST",
                authenticated: bool = True, stream: bool = False
                ) -> Tuple[int, Dict[str, str], Any]:
        """Returns (status, headers, body). Body is parsed JSON, a list of streamed chunks, or raw
        text. HTTP errors are returned rather than raised - a 429 is a result, not a crash."""
        url = self.base_url + path
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method,
                                     headers=self._headers(authenticated))
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                headers = {k.lower(): v for k, v in resp.headers.items()}
                if stream:
                    return resp.status, headers, self._read_stream(resp)
                raw = resp.read().decode("utf-8", errors="replace")
                return resp.status, headers, _maybe_json(raw)
        except urllib.error.HTTPError as exc:
            headers = {k.lower(): v for k, v in exc.headers.items()} if exc.headers else {}
            raw = exc.read().decode("utf-8", errors="replace")
            return exc.code, headers, _maybe_json(raw)
        except urllib.error.URLError as exc:
            raise RuntimeError("could not reach {0}: {1}".format(url, exc.reason))

    @staticmethod
    def _read_stream(resp: Any) -> List[Tuple[float, str]]:
        """Capture each SSE chunk with the time it arrived. The timings are the point: they are what
        distinguishes real streaming from a buffered response delivered all at once."""
        start = time.monotonic()
        chunks: List[Tuple[float, str]] = []
        for line in resp:
            text = line.decode("utf-8", errors="replace").strip()
            if text.startswith("data:"):
                chunks.append((time.monotonic() - start, text[5:].strip()))
        return chunks


def _maybe_json(raw: str) -> Any:
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def _excerpt(body: Any, limit: int = 180) -> str:
    text = json.dumps(body) if isinstance(body, (dict, list)) else str(body)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit] + "..."


def _entra_token(scope: str) -> str:
    """Borrow a token from the Azure CLI rather than taking a dependency on azure-identity."""
    try:
        out = subprocess.run(
            ["az", "account", "get-access-token", "--scope", scope,
             "--query", "accessToken", "-o", "tsv"],
            capture_output=True, text=True, timeout=60,
        )
    except FileNotFoundError:
        raise RuntimeError("--entra needs the Azure CLI on PATH, or pass --token explicitly")
    except subprocess.TimeoutExpired:
        raise RuntimeError("`az account get-access-token` timed out")
    if out.returncode != 0:
        raise RuntimeError("could not get a token for {0}: {1}".format(scope, out.stderr.strip()))
    return out.stdout.strip()


# ---------------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------------

def check_auth_required(gw: Gateway, model: str) -> Result:
    """Deliberately unauthenticated. Anything other than a rejection means the gateway is open."""
    status, _, body = gw.request(
        "/chat/completions",
        {"model": model, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 1},
        authenticated=False,
    )
    if status in (401, 403):
        return Result("auth-required", PASS, "unauthenticated request rejected with {0}".format(status))
    return Result("auth-required", FAIL,
                  "expected 401/403 without a credential, got {0}. The gateway is accepting "
                  "anonymous traffic.".format(status) + " " + _excerpt(body))


def check_discovery(gw: Gateway) -> Tuple[Result, List[str]]:
    status, _, body = gw.request("/models", method="GET")
    if status != 200:
        return Result("discovery", FAIL, "GET /models returned {0}: {1}".format(
            status, _excerpt(body))), []
    entries = body.get("data", []) if isinstance(body, dict) else []
    aliases = [e.get("id") for e in entries if isinstance(e, dict) and e.get("id")]
    if not aliases:
        return Result("discovery", FAIL, "catalogue is empty; no aliases are published"), []
    return Result("discovery", PASS, "{0} alias(es): {1}".format(
        len(aliases), ", ".join(aliases))), aliases


def check_chat(gw: Gateway, model: str) -> Tuple[Result, Dict[str, str]]:
    status, headers, body = gw.request("/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
        "max_tokens": 16,
        "temperature": 0,
    })
    if status != 200:
        return Result("chat", FAIL, "HTTP {0}: {1}".format(status, _excerpt(body))), {}
    try:
        content = body["choices"][0]["message"]["content"]
        total = body["usage"]["total_tokens"]
    except (KeyError, IndexError, TypeError):
        return Result("chat", FAIL, "200 but the body is not a chat completion: {0}".format(
            _excerpt(body))), headers
    if not total:
        return Result("chat", FAIL, "usage.total_tokens is 0; token accounting is not working"), headers
    return Result("chat", PASS, "{0} tokens, said {1!r}".format(total, content.strip()[:40])), headers


def check_alias_routing(headers: Dict[str, str], model: str) -> Result:
    """The alias must resolve to a physical deployment. If the gateway echoes the alias as the
    deployment, the indirection is not real and swapping the model underneath will break callers."""
    if not headers:
        return Result("alias-routing", SKIP, "no successful chat response to inspect")
    alias = headers.get("x-ai-model-alias")
    deployment = headers.get("x-ai-deployment")
    if not alias and not deployment:
        return Result("alias-routing", FAIL,
                      "neither x-ai-model-alias nor x-ai-deployment was returned; the governance "
                      "section of the policy is not running")
    if alias and alias != model:
        return Result("alias-routing", FAIL,
                      "asked for {0!r} but the gateway reported {1!r}".format(model, alias))
    pool = headers.get("x-ai-pool")
    detail = "{0} -> {1}".format(alias or model, deployment or "?")
    if pool:
        detail += " via pool {0}".format(pool)
    return Result("alias-routing", PASS, detail)


def check_streaming(gw: Gateway, model: str) -> Result:
    status, _, chunks = gw.request("/chat/completions", {
        "model": model,
        "messages": [{"role": "user", "content": "Count slowly from one to twenty."}],
        "max_tokens": 160,
        "temperature": 0,
        "stream": True,
    }, stream=True)
    if status != 200:
        return Result("streaming", FAIL, "HTTP {0}".format(status))
    if not isinstance(chunks, list) or not chunks:
        return Result("streaming", FAIL, "no SSE chunks were received")
    payloads = [c for _, c in chunks]
    if "[DONE]" not in payloads:
        return Result("streaming", FAIL,
                      "stream ended without a [DONE] sentinel after {0} chunk(s); it was likely "
                      "truncated".format(len(chunks)))
    if len(chunks) < 3:
        return Result("streaming", FAIL,
                      "only {0} chunk(s); the response is being buffered. Check that "
                      "buffer_response is false.".format(len(chunks)))
    spread = chunks[-1][0] - chunks[0][0]
    if spread <= 0.01:
        return Result("streaming", FAIL,
                      "{0} chunks all arrived within {1:.0f}ms of each other, which means they were "
                      "buffered and released together rather than streamed".format(
                          len(chunks), spread * 1000))
    return Result("streaming", PASS, "{0} chunks over {1:.2f}s".format(len(chunks), spread))


def check_embeddings(gw: Gateway, model: Optional[str]) -> Result:
    if not model:
        return Result("embeddings", SKIP, "no embedding alias given (--embed-model)")
    status, _, body = gw.request("/embeddings", {"model": model, "input": "the quick brown fox"})
    if status != 200:
        return Result("embeddings", FAIL, "HTTP {0}: {1}".format(status, _excerpt(body)))
    try:
        vector = body["data"][0]["embedding"]
    except (KeyError, IndexError, TypeError):
        return Result("embeddings", FAIL, "200 but no embedding in the body: {0}".format(
            _excerpt(body)))
    if not isinstance(vector, list) or not vector:
        return Result("embeddings", FAIL, "the embedding is empty")
    return Result("embeddings", PASS, "{0} dimensions".format(len(vector)))


def check_token_headers(headers: Dict[str, str]) -> Result:
    if not headers:
        return Result("token-headers", SKIP, "no successful chat response to inspect")
    found = [h for h in TOKEN_HEADERS_SUBSCRIPTION + TOKEN_HEADERS_ENTRA if h in headers]
    if not found:
        return Result("token-headers", FAIL,
                      "no token-limit headers came back. Token governance is not attached, so "
                      "quotas are not being enforced and chargeback will see nothing.")
    mode = "product scope" if found[0] in TOKEN_HEADERS_SUBSCRIPTION else "gateway scope"
    return Result("token-headers", PASS, "{0} ({1})".format(
        ", ".join("{0}={1}".format(h, headers[h]) for h in found), mode))


def check_governance_headers(headers: Dict[str, str]) -> Result:
    if not headers:
        return Result("governance-headers", SKIP, "no successful chat response to inspect")
    missing = [h for h in GOVERNANCE_HEADERS if h not in headers]
    if missing:
        return Result("governance-headers", FAIL, "missing: {0}".format(", ".join(missing)))
    extra = [h for h in ("x-ai-total-tokens", "x-ai-estimated-cost-usd", "x-ai-consumer",
                         "x-gateway-environment", "x-ms-region") if h in headers]
    return Result("governance-headers", PASS, "all present; also saw {0}".format(
        ", ".join(extra) if extra else "no optional headers"))


def check_unknown_alias(gw: Gateway) -> Result:
    """The catalogue is meant to be a closed set. An unknown alias must not be passed through."""
    status, _, body = gw.request("/chat/completions", {
        "model": "definitely-not-a-real-model",
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
    })
    if 400 <= status < 500:
        return Result("unknown-alias", PASS, "rejected with {0}".format(status))
    return Result("unknown-alias", FAIL,
                  "expected a 4xx for an unpublished alias, got {0}. Requests may be reaching the "
                  "backend unvalidated. {1}".format(status, _excerpt(body)))


def check_cost_headers(headers: Dict[str, str]) -> Result:
    """Cost attribution is optional, so its absence is a skip rather than a failure. What is not
    optional, when it is on, is that the number parses - a malformed cost silently poisons every
    downstream sum."""
    if not headers:
        return Result("cost-headers", SKIP, "no successful chat response to inspect")
    raw = headers.get("x-ai-estimated-cost-usd")
    if raw is None:
        return Result("cost-headers", SKIP, "cost attribution is not enabled on this gateway")
    try:
        cost = float(raw)
    except ValueError:
        return Result("cost-headers", FAIL,
                      "x-ai-estimated-cost-usd is not a number: {0!r}".format(raw))
    # -1 is the sentinel for a request whose usage could not be measured, which is a real state and
    # deliberately not reported as zero.
    if cost == -1:
        return Result("cost-headers", PASS,
                      "cost reported as unmeasured (-1), which is the sentinel for a response that "
                      "carried no usage block")
    if cost < 0:
        return Result("cost-headers", FAIL,
                      "negative cost {0} that is not the -1 unmeasured sentinel".format(cost))
    return Result("cost-headers", PASS, "x-ai-estimated-cost-usd={0}".format(raw))


def check_semantic_cache(gw: Gateway, model: str) -> Result:
    """The one capability whose correctness cannot be read off the response body.

    llm-semantic-cache-store keeps the backend's reply verbatim, usage block and all, so a replayed
    hit presents exactly the same token counts as the call that paid for it. A gateway that bills from
    those counts charges full price for a model that never ran. This asserts the opposite: that the
    second identical prompt is marked as a hit, costs nothing, and reports what it avoided.
    """
    prompt = "Name the seven colours of the rainbow in order, {0}.".format(uuid.uuid4())
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 64,
        # Caching is suppressed above the policy's max_temperature, so a varied request would never
        # be a hit no matter how correct the gateway is.
        "temperature": 0,
    }

    status, first, _body = gw.request("/chat/completions", payload)
    if status != 200:
        return Result("semantic-cache", FAIL, "priming request failed with {0}".format(status))
    if "x-ai-cache-hit" not in first:
        return Result("semantic-cache", SKIP, "semantic caching is not enabled on this gateway")
    if first.get("x-ai-cache-hit", "").lower() != "false":
        return Result("semantic-cache", FAIL,
                      "a prompt containing a fresh GUID was reported as a cache hit, so the cache is "
                      "matching prompts it has never seen. Check score_threshold - above roughly 0.2 "
                      "it returns answers to different questions.")

    # The store happens in outbound, after the first response has been released to the client, and the
    # index is not guaranteed to be queryable the instant the body arrives.
    deadline = time.time() + 30
    second: Dict[str, str] = {}
    while time.time() < deadline:
        time.sleep(3)
        status, second, _body = gw.request("/chat/completions", payload)
        if status != 200:
            return Result("semantic-cache", FAIL, "replay request failed with {0}".format(status))
        if second.get("x-ai-cache-hit", "").lower() == "true":
            break
    else:
        return Result("semantic-cache", FAIL,
                      "an identical prompt did not hit the cache within 30s. If the cache is Azure "
                      "Cache for Redis Basic, Standard or Premium it has no RediSearch module and "
                      "will never serve a hit, which looks exactly like a cache that is merely cold.")

    cost = second.get("x-ai-estimated-cost-usd")
    if cost is None:
        return Result("semantic-cache", PASS,
                      "replay served from cache (cost attribution is off, so no cost to check)")
    try:
        cost_value = float(cost)
    except ValueError:
        return Result("semantic-cache", FAIL,
                      "cache hit reported a non-numeric cost {0!r}".format(cost))
    if cost_value != 0:
        return Result("semantic-cache", FAIL,
                      "cache hit was billed {0}. The response carries the usage block of the call "
                      "that populated the cache, so billing from it charges for a model that never "
                      "ran.".format(cost))

    avoided = second.get("x-ai-cost-avoided-usd")
    if avoided is None:
        return Result("semantic-cache", FAIL,
                      "cache hit cost 0 but reported no x-ai-cost-avoided-usd, so the saving is "
                      "invisible to chargeback")
    try:
        avoided_value = float(avoided)
    except ValueError:
        return Result("semantic-cache", FAIL,
                      "x-ai-cost-avoided-usd is not a number: {0!r}".format(avoided))
    if avoided_value <= 0:
        return Result("semantic-cache", FAIL,
                      "cache hit reported {0} avoided; a hit that saved nothing means the modelled "
                      "cost was never computed".format(avoided))

    return Result("semantic-cache", PASS,
                  "replay hit: cost {0}, avoided {1}".format(cost, avoided))


def check_failover(gw: Gateway, model: str, calls: int) -> Result:
    """Cannot force a backend to fail without breaking it, so this observes instead: repeated calls
    should show the pool distributing across members. One member is a valid topology, not a fault."""
    if calls < 2:
        return Result("failover", SKIP, "--failover-calls below 2")
    seen: Dict[str, int] = {}
    errors = 0
    for _ in range(calls):
        status, headers, _body = gw.request("/chat/completions", {
            "model": model,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 1,
            "temperature": 0,
        })
        if status != 200:
            errors += 1
            continue
        key = headers.get("x-ms-region") or headers.get("x-ai-deployment") or "unknown"
        seen[key] = seen.get(key, 0) + 1
    if errors == calls:
        return Result("failover", FAIL, "all {0} calls failed".format(calls))
    spread = ", ".join("{0} x{1}".format(k, v) for k, v in sorted(seen.items()))
    if errors:
        return Result("failover", FAIL, "{0}/{1} calls failed; served by {2}".format(
            errors, calls, spread))
    if len(seen) == 1:
        return Result("failover", PASS,
                      "{0} calls all served by {1} (single active backend - expected unless you "
                      "configured a multi-member pool)".format(calls, spread))
    return Result("failover", PASS, "{0} calls spread across {1}".format(calls, spread))


# ---------------------------------------------------------------------------------------------------

def render(results: List[Result]) -> None:
    name_w = max([len(r.name) for r in results] + [5])
    print("")
    print("  {0}  {1}  {2}".format("CHECK".ljust(name_w), "RESULT", "DETAIL"))
    print("  {0}  {1}  {2}".format("-" * name_w, "------", "-" * 50))
    for r in results:
        print("  {0}  {1}  {2}".format(r.name.ljust(name_w), r.status.ljust(6), r.detail))
    print("")
    counts = {s: len([r for r in results if r.status == s]) for s in (PASS, FAIL, SKIP)}
    print("  {0} passed, {1} failed, {2} skipped".format(
        counts[PASS], counts[FAIL], counts[SKIP]))
    print("")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Smoke-test a deployed AI gateway.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("AI_GATEWAY_ENDPOINT"),
                        help="Gateway base URL, e.g. https://foo.azure-api.net/openai/v1. "
                             "Defaults to $AI_GATEWAY_ENDPOINT.")
    parser.add_argument("--api-key", default=os.environ.get("AI_GATEWAY_KEY"),
                        help="Subscription key. Defaults to $AI_GATEWAY_KEY.")
    parser.add_argument("--token", default=os.environ.get("AI_GATEWAY_TOKEN"),
                        help="Entra ID access token. Defaults to $AI_GATEWAY_TOKEN.")
    parser.add_argument("--entra", action="store_true",
                        help="Acquire an Entra token via the Azure CLI instead of using a key.")
    parser.add_argument("--scope", default=os.environ.get("AI_GATEWAY_SCOPE"),
                        help="Scope to request with --entra, e.g. api://<app-id>/.default. "
                             "Defaults to $AI_GATEWAY_SCOPE.")
    parser.add_argument("--model", default=os.environ.get("AI_GATEWAY_MODEL"),
                        help="Chat alias to test. Defaults to the first published alias.")
    parser.add_argument("--embed-model", default=os.environ.get("AI_GATEWAY_EMBED_MODEL"),
                        help="Embedding alias to test. Skipped if absent and none can be guessed.")
    parser.add_argument("--failover-calls", type=int, default=4,
                        help="Repeat calls to observe pool distribution. Default 4.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-request timeout. Default 120.")
    parser.add_argument("--skip-cache", action="store_true",
                        help="Skip the semantic cache check. It issues repeated identical prompts and "
                             "waits for the cache to become queryable, which adds up to 30 seconds.")
    args = parser.parse_args()

    if not args.base_url:
        parser.error("--base-url is required (or set AI_GATEWAY_ENDPOINT)")

    token = args.token
    if args.entra and not token:
        if not args.scope:
            parser.error("--entra needs --scope (or $AI_GATEWAY_SCOPE)")
        try:
            token = _entra_token(args.scope)
        except RuntimeError as exc:
            print("error: {0}".format(exc), file=sys.stderr)
            return 2
    if not token and not args.api_key:
        parser.error("supply --api-key or --token/--entra (or set AI_GATEWAY_KEY)")

    gw = Gateway(args.base_url, args.timeout, api_key=args.api_key, token=token)
    print("gateway: {0}".format(gw.base_url))
    print("auth:    {0}".format("Entra ID bearer token" if token else "subscription key"))

    results: List[Result] = []
    try:
        results.append(check_auth_required(gw, args.model or "chat"))

        discovery, aliases = check_discovery(gw)
        results.append(discovery)

        model = args.model or (aliases[0] if aliases else None)
        if not model:
            results.append(Result("chat", SKIP, "no alias to test; pass --model"))
            render(results)
            return 1

        embed_model = args.embed_model or next(
            (a for a in aliases if "embed" in a.lower()), None)

        chat, headers = check_chat(gw, model)
        results.append(chat)
        results.append(check_alias_routing(headers, model))
        results.append(check_token_headers(headers))
        results.append(check_governance_headers(headers))
        results.append(check_cost_headers(headers))
        results.append(check_streaming(gw, model))
        results.append(check_embeddings(gw, embed_model))
        results.append(check_unknown_alias(gw))
        results.append(check_failover(gw, model, args.failover_calls))
        if not args.skip_cache:
            results.append(check_semantic_cache(gw, model))
    except RuntimeError as exc:
        print("error: {0}".format(exc), file=sys.stderr)
        render(results)
        return 2
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130

    render(results)
    return 1 if any(r.status == FAIL for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
