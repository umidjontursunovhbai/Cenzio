import json
import os
import secrets
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit

import pytest
from starlette.testclient import TestClient

from smartspend_mcp.account_auth import AccountAuth, AccountAuthError, AccountDeletionError, AccountRateLimitError, challenge
from smartspend_mcp.sync_service import SyncRepository, create_app


@dataclass
class Identity:
    provider: str = "google"
    subject: str = "stable-subject"
    email: str = "synthetic@example.test"
    email_verified: bool = True
    display_name: str = "Synthetic User"
    revocation_token: str | None = None


class Provider:
    def __init__(self, identity=None):
        self.identity = identity or Identity()
        self.received = None
        self.failure = False
        self.revoked = None

    def authorization_url(self, **kwargs):
        self.received = kwargs
        return "https://identity.example/authorize?state=" + kwargs["state"]

    def exchange(self, **kwargs):
        assert kwargs["nonce"] == self.received["nonce"]
        assert challenge(kwargs["code_verifier"]) == self.received["code_challenge"]
        if self.failure:
            raise ValueError("PRIVATE PROVIDER ERROR")
        return self.identity

    def revoke(self, token):
        if self.failure:
            raise ValueError("PRIVATE REVOCATION ERROR")
        self.revoked = token


@pytest.fixture
def setup(tmp_path):
    provider = Provider()
    return AccountAuth(tmp_path, "https://sync.example", {"google": provider}), provider


def started(service, provider="google"):
    verifier, state = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    result = service.start({"provider": provider, "codeChallenge": challenge(verifier), "state": state}, peer="test-peer")
    oauth_state = parse_qs(urlsplit(result["authorizationURL"]).query)["state"][0]
    return verifier, state, oauth_state


def login(service, provider="google"):
    verifier, state, oauth_state = started(service, provider)
    callback = service.callback(provider, {"state": oauth_state, "code": "synthetic-provider-code"})
    query = parse_qs(urlsplit(callback).query)
    return service.exchange({"code": query["code"][0], "state": state, "codeVerifier": verifier})


def test_pkce_state_callback_and_completion_replay(setup):
    service, provider = setup
    verifier, state, oauth_state = started(service)
    with pytest.raises(AccountAuthError):
        service.callback("telegram", {"state": oauth_state, "code": "synthetic"})
    callback = service.callback("google", {"state": oauth_state, "code": "synthetic"})
    with pytest.raises(AccountAuthError):
        service.callback("google", {"state": oauth_state, "code": "synthetic"})
    query = parse_qs(urlsplit(callback).query)
    assert callback.startswith("smartspend://account/callback?")
    assert query["state"] == [state]
    request = {"code": query["code"][0], "state": state, "codeVerifier": verifier}
    for changes in ({"state": secrets.token_urlsafe(32)}, {"codeVerifier": secrets.token_urlsafe(32)}):
        with pytest.raises(AccountAuthError):
            service.exchange({**request, **changes})
    result = service.exchange(request)
    assert result["account"]["provider"] == "google"
    assert "subject" not in result["account"]
    with pytest.raises(AccountAuthError):
        service.exchange(request)


def test_sessions_revocation_restart_email_never_links_and_deletion(setup, tmp_path):
    service, provider = setup
    first = login(service)
    second = login(service)
    assert first["account"]["id"] == second["account"]["id"]
    reopened = AccountAuth(tmp_path, "https://sync.example", {"google": provider})
    assert reopened.current(first["accessToken"])["account"] == first["account"]
    provider.identity = Identity(subject="another-subject")
    other = login(service)
    assert other["account"]["id"] != first["account"]["id"]
    service.logout(first["accessToken"])
    with pytest.raises(PermissionError):
        service.current(first["accessToken"])
    assert service.current(second["accessToken"])
    service.delete(second["accessToken"])
    with pytest.raises(PermissionError):
        service.current(second["accessToken"])
    assert service.current(other["accessToken"])
    contents = service.path.read_bytes()
    assert first["accessToken"].encode() not in contents
    assert os.stat(service.path).st_mode & 0o777 == 0o600


def test_expired_pending_completions_sessions_and_provider_failure(setup, monkeypatch):
    service, provider = setup
    verifier, state, oauth_state = started(service)
    with service._db() as db:
        db.execute("UPDATE pending SET expires=0")
    with pytest.raises(AccountAuthError):
        service.callback("google", {"state": oauth_state, "code": "synthetic"})
    verifier, state, oauth_state = started(service)
    provider.failure = True
    callback = service.callback("google", {"state": oauth_state, "code": "synthetic"})
    assert "sign_in_failed" in callback and "PRIVATE" not in callback
    provider.failure = False
    result = login(service)
    with service._db() as db:
        db.execute("UPDATE sessions SET expires=0")
    with pytest.raises(PermissionError):
        service.current(result["accessToken"])
    verifier, state, oauth_state = started(service)
    callback = service.callback("google", {"state": oauth_state, "code": "synthetic"})
    code = parse_qs(urlsplit(callback).query)["code"][0]
    with service._db() as db:
        db.execute("UPDATE completions SET expires=0")
    with pytest.raises(AccountAuthError):
        service.exchange({"code": code, "state": state, "codeVerifier": verifier})


def test_apple_revocation_encrypted_and_required_before_deletion(tmp_path):
    secret = secrets.token_urlsafe(32)
    provider = Provider(Identity(provider="apple", revocation_token=secret))
    service = AccountAuth(tmp_path, "https://sync.example", {"apple": provider})
    first = login(service, "apple")
    assert secret.encode() not in service.path.read_bytes()
    assert "revocation" not in json.dumps(first)
    provider.failure = True
    with pytest.raises(AccountDeletionError):
        service.delete(first["accessToken"])
    assert service.current(first["accessToken"])
    provider.failure = False
    service.delete(first["accessToken"])
    assert provider.revoked == secret
    with pytest.raises(PermissionError):
        service.current(first["accessToken"])


def test_http_disabled_validation_apple_form_and_no_ledger_authority(tmp_path):
    repository = SyncRepository(tmp_path / "repository")
    with TestClient(create_app(repository, public_url="https://sync.example"), base_url="https://sync.example") as client:
        assert all(not p["available"] for p in client.get("/v1/account/providers").json()["providers"])
        assert client.post("/v1/account/start", json={}).status_code == 503
    provider = Provider(Identity(provider="apple", revocation_token=secrets.token_urlsafe(32)))
    service = AccountAuth(tmp_path, "https://sync.example", {"apple": provider})
    with TestClient(create_app(repository, public_url="https://sync.example", account_auth=service), base_url="https://sync.example", follow_redirects=False) as client:
        assert client.post("/v1/account/start", json={"provider": "apple", "redirectURI": "https://evil.example"}).status_code == 400
        verifier, native_state = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        result = client.post("/v1/account/start", json={"provider": "apple", "state": native_state, "codeChallenge": challenge(verifier)}).json()
        state = parse_qs(urlsplit(result["authorizationURL"]).query)["state"][0]
        assert client.get("/oauth/account/apple/callback?state=" + state + "&state=" + state).status_code == 400
        response = client.post("/oauth/account/apple/callback", data={"state": state, "code": "synthetic"})
        assert response.status_code == 303 and response.headers["cache-control"] == "no-store"
        code = parse_qs(urlsplit(response.headers["location"]).query)["code"][0]
        login_result = client.post("/v1/account/exchange", json={"code": code, "state": native_state, "codeVerifier": verifier}).json()
        auth = {"Authorization": "Bearer " + login_result["accessToken"]}
        assert client.get("/v1/account/me", headers=auth).status_code == 200
        assert client.get("/v1/sync/state", headers=auth).status_code == 401
        assert client.delete("/v1/account/me", headers=auth).json() == {"deleted": True}
        assert client.get("/v1/account/me", headers=auth).status_code == 401


def test_limits_and_private_storage_fail_closed(setup, tmp_path):
    service, _ = setup
    for _ in range(30):
        started(service)
    with pytest.raises(AccountRateLimitError):
        started(service)
    os.chmod(service.path, 0o644)
    with pytest.raises(AccountAuthError):
        AccountAuth(tmp_path, "https://sync.example", {})


def test_no_unverified_email_in_profile(setup):
    service, provider = setup
    provider.identity.email_verified = False
    assert login(service)["account"]["email"] is None
