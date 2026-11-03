"""Unit tests for the per-user smoke-test script, scripts/call_as_user.py.

Run with:

    python -m unittest discover -s tests -v

Offline: the tokens below are hand-built, unsigned JWTs carrying the claims Entra issues, so the
claim handling and the attribution check can be verified without signing anyone in.
"""

from __future__ import annotations

import base64
import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))

from call_as_user import (  # noqa: E402
    attribution_problem,
    decode_claims,
    describe_token,
    summarise_body,
)

OID = "7afd0f75-7bd2-4b0b-8ebf-754cf865c8f8"


def jwt(claims: dict) -> str:
    def seg(obj: dict) -> str:
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
    return f"{seg({'alg': 'none', 'typ': 'JWT'})}.{seg(claims)}.sig"


class DecodeClaims(unittest.TestCase):
    def test_round_trips_payload_without_padding(self):
        # Payload lengths that need 1, 2 and 0 padding characters once base64-encoded.
        for name in ("a", "ab", "abc"):
            self.assertEqual(decode_claims(jwt({"name": name}))["name"], name)

    def test_rejects_non_jwt(self):
        with self.assertRaises(ValueError):
            decode_claims("not-a-token")


class DescribeToken(unittest.TestCase):
    def test_delegated_v2_token(self):
        who = describe_token({"preferred_username": "alice@contoso.com", "oid": OID, "scp": "user_impersonation",
                              "azp": "04b07795-8ddb-461a-bbee-02f9e1bf7b46", "aud": "gateway", "tid": "t"})
        self.assertEqual(who["type"], "delegated")
        self.assertEqual(who["user"], "alice@contoso.com")
        self.assertEqual(who["application"], "04b07795-8ddb-461a-bbee-02f9e1bf7b46")

    def test_delegated_v1_token_prefers_upn_and_appid(self):
        who = describe_token({"upn": "alice@contoso.com", "unique_name": "other", "appid": "app-1", "scp": "x"})
        self.assertEqual(who["user"], "alice@contoso.com")
        self.assertEqual(who["application"], "app-1")

    def test_app_only_token(self):
        who = describe_token({"oid": "sp-oid", "roles": ["Gateway.Invoke"], "idtyp": "app", "azp": "app-1"})
        self.assertEqual(who["type"], "app-only")
        self.assertIsNone(who["user"])


class AttributionProblem(unittest.TestCase):
    def test_attributed_to_expected_user(self):
        self.assertIsNone(attribution_problem(OID, {"x-ai-user": OID}))

    def test_feature_disabled_or_header_missing(self):
        self.assertIn("not enabled", attribution_problem(OID, {}))
        self.assertIn("disabled", attribution_problem(OID, {"x-ai-user": "none"}))

    def test_app_only_and_unresolved_get_hints(self):
        self.assertIn("app-only", attribution_problem(OID, {"x-ai-user": "app"}))
        self.assertIn("user_claim", attribution_problem(OID, {"x-ai-user": "unresolved"}))

    def test_different_user(self):
        problem = attribution_problem(OID, {"x-ai-user": "someone-else"})
        self.assertIn("someone-else", problem)
        self.assertIn(OID, problem)


class SummariseBody(unittest.TestCase):
    def test_stream_collects_text_and_final_usage(self):
        raw = "\n".join([
            'data: {"choices":[{"delta":{"content":"Hel"}}]}',
            'data: {"choices":[{"delta":{"content":"lo"}}]}',
            'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}',
            "data: [DONE]",
        ])
        self.assertEqual(summarise_body("stream", 200, raw), "'Hello'  tokens: prompt=5 completion=2 total=7")

    def test_embeddings(self):
        raw = json.dumps({"data": [{"embedding": [0.1]}], "usage": {"prompt_tokens": 3, "total_tokens": 3}})
        self.assertEqual(summarise_body("embed", 200, raw), "1 embedding(s)  tokens: prompt=3 total=3")

    def test_error_body_is_flattened(self):
        self.assertEqual(summarise_body("chat", 401, '{"error":\n "denied"}'), '{"error":  "denied"}')


if __name__ == "__main__":
    unittest.main()
