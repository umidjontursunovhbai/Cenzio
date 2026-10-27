import json
import time
from urllib.parse import parse_qs, urlsplit

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
import httpx
import jwt
import pytest

from smartspend_mcp.identity_providers import IdentityProviderError, OIDCProvider, load_identity_providers


@pytest.fixture
def setup():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update(kid="test-key", use="sig", alg="RS256")
    claims = {"sub": "stable-provider-subject", "iss": "https://accounts.google.com", "aud": "test-client",
              "iat": int(time.time()) - 1, "exp": int(time.time()) + 300, "nonce": "transaction-nonce",
              "email": "person@example.invalid", "email_verified": True, "name": "Person"}
    calls = []
    responses = {"keys": {"keys": [jwk]}, "token": {}}

    def handler(request):
        calls.append(request)
        if "keys" in str(request.url) or "certs" in str(request.url) or "jwks" in str(request.url):
            return httpx.Response(200, json=responses["keys"])
        if "revoke" in str(request.url):
            return httpx.Response(responses.get("revoke_status", 200))
        return httpx.Response(200, json=responses["token"])

    client = httpx.Client(transport=httpx.MockTransport(handler))
    provider = OIDCProvider("google", "test-client", "synthetic-test-secret", httpx_client=client)
    return provider, key, claims, responses, calls, client


def signed(key, claims, **headers):
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-key", **headers})


def test_verified_identity_uses_signed_subject_and_caches_pinned_keys(setup):
    provider, key, claims, _, calls, _ = setup
    result = provider.verify_id_token(signed(key, claims), nonce="transaction-nonce")
    assert result.subject == "stable-provider-subject"
    assert result.email_verified is True
    assert result.display_name == "Person"
    provider.verify_id_token(signed(key, {**claims, "email": "different@example.invalid"}), nonce="transaction-nonce")
    assert len(calls) == 1
    assert str(calls[0].url) == "https://www.googleapis.com/oauth2/v3/certs"


@pytest.mark.parametrize("change", [
    {"iss": "https://evil.invalid"}, {"aud": "other-client"}, {"exp": 1}, {"iat": int(time.time()) + 300},
    {"nonce": "other-nonce"}, {"sub": ""}, {"sub": 123}, {"azp": "other-client"},
    {"aud": ["test-client", "other-client"]}, {"nonce": None},
])
def test_claim_validation_fail_closed(setup, change):
    provider, key, claims, _, _, _ = setup
    with pytest.raises(IdentityProviderError, match="Identity verification failed"):
        provider.verify_id_token(signed(key, {**claims, **change}), nonce="transaction-nonce")


@pytest.mark.parametrize("missing", ["iss", "aud", "sub", "iat", "exp", "nonce"])
def test_required_claims(setup, missing):
    provider, key, claims, _, _, _ = setup
    del claims[missing]
    with pytest.raises(IdentityProviderError):
        provider.verify_id_token(signed(key, claims), nonce="transaction-nonce")


def test_reject_bad_signature_alg_key_and_remote_header(setup):
    provider, key, claims, _, calls, _ = setup
    bad_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    for token in [signed(bad_key, claims), jwt.encode(claims, "synthetic-secret-that-is-at-least-32-bytes", algorithm="HS256", headers={"kid": "test-key"}),
                  jwt.encode(claims, key, algorithm="RS256", headers={"kid": "unknown", "jku": "https://evil.invalid/keys"}),
                  signed(key, claims, crit=["unrecognized"]), "not-a-jwt"]:
        with pytest.raises(IdentityProviderError):
            provider.verify_id_token(token, nonce="transaction-nonce")
    assert all("evil.invalid" not in str(call.url) for call in calls)


def test_google_exchange_uses_pkce_and_returns_no_access_tokens(setup):
    provider, key, claims, responses, calls, _ = setup
    responses["token"] = {"id_token": signed(key, claims), "access_token": "must-not-escape", "refresh_token": "must-not-escape"}
    identity = provider.exchange(code="synthetic-code", redirect_uri="https://sync.invalid/callback", nonce="transaction-nonce", code_verifier="server-pkce-verifier")
    assert identity.revocation_token is None
    assert "must-not-escape" not in repr(identity)
    form = parse_qs(calls[0].content.decode())
    assert form["code_verifier"] == ["server-pkce-verifier"]
    params = parse_qs(urlsplit(provider.authorization_url(state="csrf", nonce="transaction-nonce", redirect_uri="https://sync.invalid/callback", code_challenge="challenge")).query)
    assert params["scope"] == ["openid email profile"]
    assert params["code_challenge_method"] == ["S256"]
    assert "drive" not in params["scope"][0]


def test_telegram_real_oidc_basic_auth_no_phone_or_bot_permission(setup):
    _, key, claims, responses, calls, client = setup
    provider = OIDCProvider("telegram", "123456", "oidc-secret-not-bot-token", httpx_client=client)
    claims.update(iss="https://oauth.telegram.org", aud="123456")
    responses["token"] = {"id_token": signed(key, claims)}
    identity = provider.exchange(code="synthetic-code", redirect_uri="https://sync.invalid/callback", nonce="transaction-nonce", code_verifier="pkce-verifier")
    assert identity.provider == "telegram"
    assert calls[0].headers["authorization"].startswith("Basic ")
    assert "client_secret" not in parse_qs(calls[0].content.decode())
    params = parse_qs(urlsplit(provider.authorization_url(state="csrf", nonce="transaction-nonce", redirect_uri="https://sync.invalid/callback", code_challenge="challenge")).query)
    assert params["scope"] == ["openid profile"]


def apple_provider(client):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    return OIDCProvider("apple", "com.example.web", team_id="TEAM", key_id="KEY", private_key=pem, httpx_client=client), key


def test_apple_form_post_signed_client_secret_and_private_revocation(setup):
    _, key, claims, responses, calls, client = setup
    provider, secret_key = apple_provider(client)
    claims.update(iss="https://appleid.apple.com", aud="com.example.web", email_verified="true")
    responses["token"] = {"id_token": signed(key, claims), "refresh_token": "private-apple-refresh-test"}
    identity = provider.exchange(code="synthetic-code", redirect_uri="https://sync.invalid/callback", nonce="transaction-nonce", code_verifier="unused")
    assert identity.revocation_token == "private-apple-refresh-test"
    assert "private-apple-refresh-test" not in repr(identity)
    form = parse_qs(calls[0].content.decode())
    assert "code_verifier" not in form
    secret_claims = jwt.decode(form["client_secret"][0], secret_key.public_key(), algorithms=["ES256"], audience="https://appleid.apple.com")
    assert secret_claims["iss"] == "TEAM"
    assert secret_claims["sub"] == "com.example.web"
    params = parse_qs(urlsplit(provider.authorization_url(state="csrf", nonce="transaction-nonce", redirect_uri="https://sync.invalid/callback", code_challenge="unused")).query)
    assert params["response_mode"] == ["form_post"]
    provider.revoke(identity.revocation_token)
    assert str(calls[-1].url) == "https://appleid.apple.com/auth/revoke"
    assert parse_qs(calls[-1].content.decode())["token_type_hint"] == ["refresh_token"]
    responses["revoke_status"] = 500
    with pytest.raises(IdentityProviderError, match="revocation failed"):
        provider.revoke(identity.revocation_token)


def test_apple_missing_revocation_token_rejected(setup):
    _, key, claims, responses, _, client = setup
    provider, _ = apple_provider(client)
    claims.update(iss="https://appleid.apple.com", aud="com.example.web")
    responses["token"] = {"id_token": signed(key, claims)}
    with pytest.raises(IdentityProviderError):
        provider.exchange(code="code", redirect_uri="https://sync.invalid/callback", nonce="transaction-nonce", code_verifier="unused")


def test_private_config_omitted_and_exact_provider_fields(tmp_path):
    path = tmp_path / "identity.json"
    path.write_text(json.dumps({"google": {"client_id": "test-client", "client_secret": "synthetic-test-secret"}}))
    path.chmod(0o600)
    providers = load_identity_providers(path)
    assert set(providers) == {"google"}
    providers["google"].close()
    for value in [{"unknown": {}}, {"telegram": {"client_id": "123"}}, {"google": {"client_id": "x", "client_secret": "x", "token_url": "https://evil.invalid"}}, []]:
        path.write_text(json.dumps(value))
        with pytest.raises(IdentityProviderError):
            load_identity_providers(path)
    path.write_text("{}")
    path.chmod(0o644)
    with pytest.raises(IdentityProviderError):
        load_identity_providers(path)
    path.chmod(0o600)
    link = tmp_path / "link.json"
    link.symlink_to(path)
    with pytest.raises(IdentityProviderError):
        load_identity_providers(link)


@pytest.mark.parametrize("body", [{"keys": []}, {"keys": "not-a-key-set"}, {"keys": [{"kid": "test-key", "kty": "oct"}]},
                                    {"keys": [{"kid": "test-key", "kty": "RSA", "use": "enc"}]}])
def test_invalid_jwks_fails_closed(setup, body):
    provider, key, claims, responses, _, _ = setup
    responses["keys"] = body
    with pytest.raises(IdentityProviderError):
        provider.verify_id_token(signed(key, claims), nonce="transaction-nonce")


@pytest.mark.parametrize("status", [302, 400, 429, 500])
def test_provider_error_bodies_are_not_exposed_and_redirects_not_followed(status):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(status, headers={"location": "https://evil.invalid"},
                              json={"error_description": "private-provider-secret"})

    with httpx.Client(transport=httpx.MockTransport(handler)) as client:
        provider = OIDCProvider("google", "test-client", "synthetic-secret", httpx_client=client)
        with pytest.raises(IdentityProviderError) as error:
            provider.exchange(code="synthetic-code", redirect_uri="https://sync.invalid/callback", nonce="transaction-nonce", code_verifier="verifier")
        assert "private-provider-secret" not in str(error.value)
        assert len(calls) == 1


def test_verified_email_does_not_accept_numeric_truthiness(setup):
    provider, key, claims, _, _, _ = setup
    result = provider.verify_id_token(signed(key, {**claims, "email_verified": 1}), nonce="transaction-nonce")
    assert result.email_verified is False
