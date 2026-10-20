import hashlib
import json
import os
import sqlite3
import time
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from smartspend_mcp.connectors import ConnectorError, HEADERS
from smartspend_mcp.google_oauth import GoogleOAuth, SCOPE

LEDGER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
URL = "https://example.test"


def setup(tmp_path, *, expires=3600, fail_create=False, scope=SCOPE):
    calls = []
    def handler(request):
        calls.append(request)
        if request.url.host == "oauth2.googleapis.com":
            form = parse_qs(request.content.decode())
            assert form["client_secret"] == ["secret-client"]
            if form["grant_type"] == ["refresh_token"]:
                assert form["refresh_token"] == ["refresh-private"]
                return httpx.Response(200, json={"access_token": "access-refreshed", "expires_in": 3600, "scope": scope})
            assert form["code_verifier"]
            return httpx.Response(200, json={"access_token": "access-private", "refresh_token": "refresh-private", "expires_in": expires, "scope": scope})
        assert request.headers["Authorization"] == "Bearer access-private"
        if request.method == "POST":
            if fail_create:
                raise httpx.ReadTimeout("unsafe-provider-detail", request=request)
            return httpx.Response(200, json={"spreadsheetId": "sheet-new"})
        assert json.loads(request.content)["values"] == [list(HEADERS)]
        return httpx.Response(200, json={"updatedRows": 1})
    client = httpx.Client(transport=httpx.MockTransport(handler))
    oauth = GoogleOAuth(tmp_path, "client", "secret-client", URL, client)
    return oauth, calls


def start(oauth):
    result = oauth.start(LEDGER, "google")
    assert set(result) == {"authorizationUrl"}
    params = parse_qs(urlsplit(result["authorizationUrl"]).query)
    assert params["scope"] == [SCOPE]
    assert params["code_challenge_method"] == ["S256"]
    assert params["redirect_uri"] == [URL + "/oauth/google/callback"]
    assert params["access_type"] == ["offline"]
    return params["state"][0]


def test_enroll_refresh_and_secrets_encrypted(tmp_path):
    oauth, calls = setup(tmp_path, expires=30)
    state = start(oauth)
    result = oauth.callback(state, "code-private")
    assert result == {"ledgerId": LEDGER, "connectorId": "google", "spreadsheetId": "sheet-new", "tab": "Sheet1"}
    assert len(calls) == 3
    config = oauth.config(LEDGER, "google")
    assert config["token"] == "access-refreshed"
    assert config["provider"] == "google_sheets"
    assert len(calls) == 4
    assert oauth.config(LEDGER, "google") == config
    assert len(calls) == 4
    data = oauth._db.read_bytes()
    for secret in (state, "code-private", "refresh-private", "access-private", "access-refreshed", "secret-client"):
        assert secret.encode() not in data
    assert oauth._db.stat().st_mode & 0o777 == 0o600
    assert (oauth._db.parent / "owner.key").stat().st_mode & 0o777 == 0o600
    with pytest.raises(ConnectorError, match="not found"):
        oauth.config(OTHER, "google")
    with pytest.raises(ConnectorError, match="expired"):
        oauth.callback(state, "code-private")
    assert len(calls) == 4


def test_unknown_state_and_expired_state_never_exchange(tmp_path):
    oauth, calls = setup(tmp_path)
    state = start(oauth)
    with sqlite3.connect(oauth._db) as db:
        db.execute("UPDATE states SET expires=?", (time.time() - 1,))
    for value in (state, "x" * 43):
        with pytest.raises(ConnectorError, match="expired"):
            oauth.callback(value, "code")
    assert calls == []


def test_unknown_creation_does_not_duplicate_or_retry_code(tmp_path):
    oauth, calls = setup(tmp_path, fail_create=True)
    state = start(oauth)
    with pytest.raises(ConnectorError, match="no automatic"):
        oauth.callback(state, "code")
    with pytest.raises(ConnectorError, match="expired"):
        oauth.callback(state, "code")
    with pytest.raises(ConnectorError, match="reconciliation"):
        oauth.start(LEDGER, "google")
    with pytest.raises(ConnectorError, match="reconciliation"):
        oauth.config(LEDGER, "google")
    assert len(calls) == 2


def test_parallel_states_cannot_create_two_sheets(tmp_path):
    oauth, calls = setup(tmp_path)
    first, second = start(oauth), start(oauth)
    oauth.callback(first, "first-code")
    with pytest.raises(ConnectorError, match="reconciliation"):
        oauth.callback(second, "second-code")
    assert len(calls) == 3


def test_extra_scope_fails_closed(tmp_path):
    oauth, calls = setup(tmp_path, scope=SCOPE + " https://www.googleapis.com/auth/drive")
    with pytest.raises(ConnectorError, match="file-only"):
        oauth.callback(start(oauth), "code")
    assert len(calls) == 1


def test_pkce_is_bound_and_not_stored_plaintext(tmp_path):
    oauth, calls = setup(tmp_path)
    url = oauth.start(LEDGER, "google")["authorizationUrl"]
    params = parse_qs(urlsplit(url).query)
    state = params["state"][0]
    oauth.callback(state, "code")
    verifier = parse_qs(calls[0].content.decode())["code_verifier"][0]
    import base64
    assert params["code_challenge"] == [base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")]
    assert verifier.encode() not in oauth._db.read_bytes()


def test_private_client_file_and_callback_validation(tmp_path):
    config = tmp_path / "client.json"
    config.write_text(json.dumps({"web": {"client_id": "client", "client_secret": "secret", "redirect_uris": [URL + "/oauth/google/callback"]}}))
    config.chmod(0o600)
    oauth = GoogleOAuth.from_private_file(tmp_path / "data", URL, config)
    assert oauth.redirect_uri == URL + "/oauth/google/callback"
    with pytest.raises(ConnectorError, match="callback"):
        GoogleOAuth.from_private_file(tmp_path / "other", "https://other.test", config)
    config.chmod(0o644)
    with pytest.raises(ConnectorError, match="owner-only"):
        GoogleOAuth.from_private_file(tmp_path / "other", URL, config)
    link = tmp_path / "link.json"
    link.symlink_to(config)
    with pytest.raises(ConnectorError):
        GoogleOAuth.from_private_file(tmp_path / "other", URL, link)


def test_storage_symlink_refused(tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "link"
    link.symlink_to(target)
    with pytest.raises(ConnectorError, match="symlink"):
        GoogleOAuth(link, "client", "secret", URL)


def test_reopen_encrypted_connection(tmp_path):
    oauth, _ = setup(tmp_path)
    oauth.callback(start(oauth), "code")
    reopened, calls = setup(tmp_path)
    assert reopened.config(LEDGER, "google")["spreadsheetId"] == "sheet-new"
    assert not calls


def test_scheduler_and_public_status_never_return_credentials(tmp_path):
    oauth, calls = setup(tmp_path)
    assert oauth.ready_connections() == []
    assert oauth.connection_status(LEDGER) == {"connected": False, "pending": False}
    oauth.callback(start(oauth), "code")
    assert oauth.ready_connections() == [{"ledgerId": LEDGER, "connectorId": "google"}]
    assert oauth.connection_status(LEDGER, "google") == {"connected": True, "pending": False, "spreadsheetId": "sheet-new"}
    assert oauth.connection_status(OTHER, "google") == {"connected": False, "pending": False}
    # Status does not call Google or attempt a token refresh.
    assert len(calls) == 3


def test_pending_connections_excluded_from_scheduler(tmp_path):
    oauth, _ = setup(tmp_path, fail_create=True)
    with pytest.raises(ConnectorError):
        oauth.callback(start(oauth), "code")
    assert oauth.ready_connections() == []
    assert oauth.connection_status(LEDGER, "google") == {"connected": False, "pending": True}


def test_close_does_not_close_injected_client(tmp_path):
    oauth, _ = setup(tmp_path)
    oauth.close()
    assert not oauth._client.is_closed
    owned = GoogleOAuth(tmp_path / "other", "client", "secret", URL)
    owned.close()
    assert owned._client.is_closed


def test_database_handles_closed_after_context(tmp_path):
    oauth, _ = setup(tmp_path)
    with oauth._connect() as db:
        assert db.execute("SELECT 1").fetchone() == (1,)
    with pytest.raises(sqlite3.ProgrammingError, match="closed"):
        db.execute("SELECT 1")
