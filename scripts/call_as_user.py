#!/usr/bin/env python3
"""Call the AI gateway as a signed-in user and check that the call is attributed to that user.

Use this to confirm per-user attribution end to end without writing a consuming application. The
Azure CLI plays the consuming application: it holds your user sign-in and asks Entra for a delegated
token whose audience is the gateway. That is the same kind of token an On-Behalf-Of exchange gives a
real application, so the gateway treats the request as "Azure CLI, acting for you".

What it does
------------
1. Gets a delegated token for the gateway from the Azure CLI (or uses --token).
2. Decodes the token locally and prints who it is for: user, object id, application, audience.
   Nothing is verified here - the gateway does that - this only shows you what you are sending.
3. Sends a chat request, a streamed chat request and an embeddings request (choose with --calls).
4. Prints the gateway's x-ai-* response headers and checks that x-ai-user equals your object id.

Exit status is 0 only if every call succeeded and was attributed to the user in the token.
Ledger rows reach Application Insights within a few minutes; streamed rows are backfilled from the
LLM log, which can take 5-10 minutes. Then open the workbook's "Allocation by individual" section.

Testing as several people
-------------------------
Each --az-config-dir is a separate Azure CLI profile, so you can sign in as another user without
signing out of your own CLI session. Use a device code and open the sign-in page in a private
browser window, so the browser does not reuse the account you are already signed in with:

    python scripts/call_as_user.py --az-config-dir ~/.uca/alice --login --device-code --tenant <tenant-id>
    python scripts/call_as_user.py --az-config-dir ~/.uca/alice --brief       # reuses her sign-in

Test accounts that must satisfy MFA but have no method registered can sign in with a Temporary
Access Pass (Entra admin centre > user > Authentication methods).

Usage
-----
    export AI_GATEWAY_ENDPOINT=https://<apim>.azure-api.net/<path>/openai/v1
    export AI_GATEWAY_KEY=<subscription key>            # needed when caller auth mode is "both"
    export AI_GATEWAY_APP_ID=<gateway app registration client id>
    az login                                            # once, as the user you want to test as
    python scripts/call_as_user.py

    # PowerShell
    $env:AI_GATEWAY_ENDPOINT = "https://<apim>.azure-api.net/<path>/openai/v1"
    $env:AI_GATEWAY_KEY      = "<subscription key>"
    $env:AI_GATEWAY_APP_ID   = "<gateway app registration client id>"
    python scripts/call_as_user.py --calls chat,stream --repeat 3

The Azure CLI's application id must be allowed by the gateway (caller_client_application_ids, if
set), and the gateway's audiences must include the bare app id, because that is what a v2 token
carries in "aud".

Standard library only.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

CALLS = ("chat", "stream", "embed")
PROMPTS = (
    "In one sentence, what is an API gateway?",
    "Give me one tip for writing clear commit messages.",
    "Name one benefit of chargeback for shared cloud services.",
    "In one sentence, why do language models count tokens?",
)


def decode_claims(token: str) -> Dict[str, Any]:
    """Return the JWT payload without verifying it. For display only; the gateway does the checking."""
    parts = token.split(".")
    if len(parts) < 2:
        raise ValueError("not a JWT")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode()))


def describe_token(claims: Dict[str, Any]) -> Dict[str, Optional[str]]:
    """Summarise the claims the gateway reads for attribution."""
    delegated = "scp" in claims or claims.get("idtyp") == "user"
    return {
        "user": claims.get("upn") or claims.get("preferred_username") or claims.get("unique_name"),
        "name": claims.get("name"),
        "oid": claims.get("oid"),
        "tenant": claims.get("tid"),
        "application": claims.get("appid") or claims.get("azp"),
        "audience": claims.get("aud"),
        "type": "delegated" if delegated else "app-only",
        "expires": time.strftime("%H:%M:%S", time.localtime(claims["exp"])) if "exp" in claims else None,
    }


def attribution_problem(expected_oid: Optional[str], headers: Dict[str, str]) -> Optional[str]:
    """Return why a response was not attributed to the expected user, or None if it was."""
    user = headers.get("x-ai-user")
    if user is None:
        return "no x-ai-user header: user attribution is not enabled on this gateway"
    if user == expected_oid:
        return None
    hints = {
        "none": "user attribution is disabled on the gateway",
        "app": "the gateway saw an app-only token, not a user token",
        "unresolved": "the token has no user claim the gateway is configured to read (user_claim)",
    }
    return f"x-ai-user is {user!r}, expected {expected_oid!r}" + (f" ({hints[user]})" if user in hints else "")


def az(args: List[str], config_dir: Optional[str], interactive: bool = False) -> str:
    exe = shutil.which("az") or shutil.which("az.cmd")
    if not exe:
        raise RuntimeError("the Azure CLI (az) is not on PATH; install it or pass --token")
    env = dict(os.environ)
    if config_dir:
        os.makedirs(config_dir, exist_ok=True)
        env["AZURE_CONFIG_DIR"] = config_dir
        # On Windows the sign-in broker (WAM) would quietly reuse the account signed in to Windows,
        # which defeats a separate profile meant for another user.
        env["AZURE_CORE_ENABLE_BROKER_ON_WINDOWS"] = "false"
    if interactive:
        subprocess.run([exe] + args, env=env, check=True)
        return ""
    proc = subprocess.run([exe] + args, env=env, capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"az {' '.join(args)} failed")
    return proc.stdout.strip()


def get_token(args: argparse.Namespace) -> str:
    if args.token:
        return args.token
    if not args.app_id:
        raise RuntimeError("pass --app-id (or set AI_GATEWAY_APP_ID): the gateway app registration's client id")
    if args.login:
        login = ["login", "--allow-no-subscriptions", "--only-show-errors", "-o", "none"]
        if args.tenant:
            login += ["--tenant", args.tenant]
        if args.device_code:
            login.append("--use-device-code")
        az(login, args.az_config_dir, interactive=True)
    try:
        return az(["account", "get-access-token", "--resource", args.app_id,
                   "--query", "accessToken", "-o", "tsv"], args.az_config_dir)
    except RuntimeError as exc:
        hint = " Run with --login to sign in." if "az login" in str(exc) else ""
        raise RuntimeError(f"could not get a token from the Azure CLI: {exc}.{hint}") from None


def post(base_url: str, path: str, body: Dict[str, Any], token: str, key: Optional[str],
         timeout: int) -> Tuple[int, Dict[str, str], str]:
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    if key:
        headers["api-key"] = key
    req = urllib.request.Request(base_url.rstrip("/") + path, data=json.dumps(body).encode(),
                                 headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
        status = resp.status
    except urllib.error.HTTPError as err:
        resp, status = err, err.code
    hdrs = {k.lower(): v for k, v in resp.headers.items()}
    return status, hdrs, resp.read().decode(errors="replace")


def tokens(usage: Optional[Dict[str, Any]]) -> str:
    if not usage:
        return "usage: not reported"
    return "tokens: " + " ".join(f"{k.replace('_tokens', '')}={usage[k]}"
                                 for k in ("prompt_tokens", "completion_tokens", "total_tokens") if k in usage)


def summarise_body(call: str, status: int, raw: str) -> str:
    if status >= 400:
        return raw.strip().replace("\n", " ")[:300]
    if call == "stream":
        text, usage = [], None
        for line in raw.splitlines():
            if not line.startswith("data:") or line[5:].strip() == "[DONE]":
                continue
            try:
                chunk = json.loads(line[5:])
            except ValueError:
                continue
            for choice in chunk.get("choices") or []:
                text.append((choice.get("delta") or {}).get("content") or "")
            usage = chunk.get("usage") or usage
        return f"{''.join(text)[:100]!r}  {tokens(usage)}"
    try:
        body = json.loads(raw)
    except ValueError:
        return raw[:200]
    if call == "embed":
        return f"{len(body.get('data') or [])} embedding(s)  {tokens(body.get('usage'))}"
    return f"{body['choices'][0]['message']['content'][:100]!r}  {tokens(body.get('usage'))}"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default=os.environ.get("AI_GATEWAY_ENDPOINT"),
                   help="Gateway OpenAI base URL ending in /openai/v1 (env AI_GATEWAY_ENDPOINT).")
    p.add_argument("--api-key", default=os.environ.get("AI_GATEWAY_KEY"),
                   help="Subscription key, sent as api-key (env AI_GATEWAY_KEY). Omit in Entra-only mode.")
    p.add_argument("--app-id", default=os.environ.get("AI_GATEWAY_APP_ID"),
                   help="Client id of the gateway's app registration; the token audience (env AI_GATEWAY_APP_ID).")
    p.add_argument("--token", default=os.environ.get("AI_GATEWAY_TOKEN"),
                   help="Use this bearer token instead of asking the Azure CLI (env AI_GATEWAY_TOKEN).")
    p.add_argument("--az-config-dir", help="Separate Azure CLI profile, so you can test as another user.")
    p.add_argument("--login", action="store_true", help="Run 'az login' in that profile first.")
    p.add_argument("--device-code", action="store_true", help="With --login, sign in with a device code.")
    p.add_argument("--tenant", help="With --login, the tenant to sign in to.")
    p.add_argument("--calls", default=",".join(CALLS), help="Comma-separated: chat,stream,embed.")
    p.add_argument("--repeat", type=int, default=1, help="Send each call this many times.")
    p.add_argument("--chat-model", default="chat", help="Chat model alias (default: chat).")
    p.add_argument("--embed-model", default="embed", help="Embeddings model alias (default: embed).")
    p.add_argument("--max-tokens", type=int, default=200, help="max_completion_tokens for chat calls.")
    p.add_argument("--timeout", type=int, default=180)
    p.add_argument("--brief", action="store_true", help="One line per call; hide headers and replies.")
    args = p.parse_args()

    calls = [c.strip() for c in args.calls.split(",") if c.strip()]
    unknown = [c for c in calls if c not in CALLS]
    if unknown or not args.base_url:
        p.error(f"unknown call(s): {unknown}" if unknown else "--base-url (or AI_GATEWAY_ENDPOINT) is required")

    try:
        token = get_token(args)
        who = describe_token(decode_claims(token))
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print("Token")
    for k, v in who.items():
        print(f"  {k:<12} {v}")
    if who["type"] != "delegated":
        print("  warning: this is not a user token, so the gateway cannot attribute it to a person")
    print()

    failures, n = 0, 0
    for i in range(args.repeat):
        for call in calls:
            n += 1
            prompt = PROMPTS[(n - 1) % len(PROMPTS)]
            if call == "embed":
                path, body = "/embeddings", {"model": args.embed_model, "input": prompt}
            else:
                path = "/chat/completions"
                body = {"model": args.chat_model, "max_completion_tokens": args.max_tokens,
                        "messages": [{"role": "user", "content": prompt}]}
                if call == "stream":
                    body["stream"] = True
            status, hdrs, raw = post(args.base_url, path, body, token, args.api_key, args.timeout)
            problem = f"HTTP {status}" if status >= 400 else attribution_problem(who["oid"], hdrs)
            failures += problem is not None
            print(f"[{'OK ' if problem is None else 'ERR'}] {call:<6} HTTP {status}  "
                  f"user={hdrs.get('x-ai-user', '-')}  app={hdrs.get('x-ai-consumer', '-')}"
                  + (f"  tokens={hdrs.get('x-ai-tokens-consumed', '-')}" if args.brief else ""))
            if not args.brief:
                for h in sorted(hdrs):
                    if h.startswith("x-ai-") and h not in ("x-ai-user", "x-ai-consumer"):
                        print(f"       {h}: {hdrs[h]}")
            if not args.brief or status >= 400:
                print(f"       {summarise_body(call, status, raw)}")
            if problem and status < 400:
                print(f"       {problem}")

    print(f"\n{n - failures}/{n} calls succeeded and were attributed to {who['user'] or who['oid']}.")
    if not failures:
        print("Ledger rows appear in Application Insights within a few minutes (streamed rows: 5-10).")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
