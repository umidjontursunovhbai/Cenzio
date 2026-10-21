import json
import sqlite3
import time
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from smartspend_mcp.connectors import ConnectorError
from smartspend_mcp.notion_oauth import NotionOAuth, VERSION

LEDGER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
PARENT = "33333333-3333-4333-8333-333333333333"
DATABASE = "44444444-4444-4444-8444-444444444444"
SOURCE = "55555555-5555-4555-8555-555555555555"
URL = "https://example.test"


def setup(tmp_path, *, failure=None, expires=3600):
    calls = []
    def handler(request):
        calls.append(request)
        assert request.headers["Notion-Version"] == VERSION
        body = json.loads(request.content)
        path = request.url.path
        if failure == path:
            raise httpx.ReadTimeout("private provider message", request=request)
        if path == "/v1/oauth/token":
            assert request.headers["Authorization"].startswith("Basic ")
            if body["grant_type"] == "authorization_code":
                assert body["redirect_uri"] == URL + "/oauth/notion/callback"
                return httpx.Response(200, json={"access_token": "private-access", "refresh_token": "private-refresh", "expires_in": expires})
            assert body == {"grant_type": "refresh_token", "refresh_token": "private-refresh"}
            return httpx.Response(200, json={"access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 3600})
        if path == "/v1/oauth/revoke":
            assert request.headers["Authorization"].startswith("Basic ")
            assert body["token"] in ("private-access", "rotated-access")
            return httpx.Response(200, json={})
        assert request.headers["Authorization"] in ("Bearer private-access", "Bearer rotated-access")
        if path == "/v1/search":
            assert body == {"filter": {"value": "page", "property": "object"}, "page_size": 100}
            return httpx.Response(200, json={"results": [
                {"object": "page", "id": PARENT, "parent": {"type": "workspace"}, "properties": {"title": {"type": "title", "title": [{"plain_text": "My budget"}]}}},
                {"object": "page", "id": OTHER, "parent": {"type": "data_source_id"}, "properties": {"Secret financial field": {"number": 5000}}}], "has_more": False})
        assert path == "/v1/databases"
        assert body["parent"] == {"type": "page_id", "page_id": PARENT}
        assert set(body["initial_data_source"]["properties"]) == {"Title", "Amount", "Date", "Deleted", "SmartSpend ID", "Category ID", "Currency"}
        return httpx.Response(200, json={"id": DATABASE, "data_sources": [{"id": SOURCE}]})
    oauth = NotionOAuth(tmp_path, "public-client", "private-client", URL, httpx.Client(transport=httpx.MockTransport(handler)))
    return oauth, calls


def state(oauth, ledger=LEDGER):
    result = oauth.start(ledger)
    assert set(result) == {"authorizationUrl"}
    url = urlsplit(result["authorizationUrl"])
    assert url.hostname == "api.notion.com"
    params = parse_qs(url.query)
    assert params["owner"] == ["user"]
    assert params["redirect_uri"] == [URL + "/oauth/notion/callback"]
    return params["state"][0]


def test_full_individual_enrollment_encryption_selection(tmp_path):
    oauth, calls = setup(tmp_path)
    browser_state = state(oauth)
    assert oauth.callback(browser_state, "private-code") == {"ledgerId": LEDGER, "connectorId": "notion-default", "needsSelection": True}
    assert oauth.connection_status(LEDGER) == {"connected": False, "pending": False, "needsSelection": True}
    assert oauth.ready_connections() == []
    assert oauth.parent_pages(LEDGER) == {"pages": [{"id": PARENT, "title": "My budget"}], "hasMore": False}
    assert all("Secret financial" not in str(v) for v in oauth.parent_pages(LEDGER).values())
    result = oauth.select_parent(LEDGER, "notion-default", PARENT)
    assert result["connected"] and result["databaseId"] == DATABASE
    assert oauth.config(LEDGER)["dataSourceId"] == SOURCE
    assert oauth.config(LEDGER)["token"] == "private-access"
    assert oauth.ready_connections() == [{"ledgerId": LEDGER, "connectorId": "notion-default"}]
    assert oauth.connection_status(OTHER)["connected"] is False
    with pytest.raises(ConnectorError, match="not found"):
        oauth.config(OTHER)
    with pytest.raises(ConnectorError, match="expired"):
        oauth.callback(browser_state, "private-code")
    for secret in (browser_state, "private-code", "private-access", "private-refresh", "private-client"):
        assert secret.encode() not in oauth._db.read_bytes()
    assert oauth._db.stat().st_mode & 0o777 == 0o600
    assert (oauth._db.parent / "owner.key").stat().st_mode & 0o777 == 0o600
    assert all(request.url.host == "api.notion.com" for request in calls)


def test_independent_users_and_no_shared_token(tmp_path):
    oauth, calls = setup(tmp_path)
    oauth.callback(state(oauth), "one")
    assert oauth.connection_status(OTHER)["needsSelection"] is False
    oauth.callback(state(oauth, OTHER), "two")
    assert oauth.connection_status(OTHER)["needsSelection"]
    oauth.disconnect(LEDGER)
    assert oauth.connection_status(OTHER)["needsSelection"]
    assert not oauth.connection_status(LEDGER)["needsSelection"]


def test_missing_encryption_key_requires_matching_backup(tmp_path):
    oauth, _ = setup(tmp_path)
    oauth.callback(state(oauth), "code")
    key_path = tmp_path / "notion-oauth/owner.key"
    key_path.unlink()
    with pytest.raises(ConnectorError, match="restore"):
        NotionOAuth(tmp_path, "client", "private-client", URL)
    assert not key_path.exists()


def test_expired_or_unknown_state_no_exchange(tmp_path):
    oauth, calls = setup(tmp_path)
    value = state(oauth)
    with sqlite3.connect(oauth._db) as db:
        db.execute("UPDATE states SET expires=?", (time.time()-1,))
    for candidate in (value, "x"*43):
        with pytest.raises(ConnectorError, match="expired"):
            oauth.callback(candidate, "code")
    assert calls == []


def test_disconnect_invalidates_outstanding_state(tmp_path):
    oauth, calls = setup(tmp_path)
    value = state(oauth)
    assert oauth.disconnect(LEDGER) == {"disconnected": True, "revoked": True}
    with pytest.raises(ConnectorError, match="expired"):
        oauth.callback(value, "code")
    assert calls == []


def test_parallel_states_cannot_overwrite_connection(tmp_path):
    oauth, calls = setup(tmp_path)
    first, second = state(oauth), state(oauth)
    oauth.callback(first, "one")
    with pytest.raises(ConnectorError, match="already exists"):
        oauth.callback(second, "two")
    assert len(calls) == 1


def test_no_arbitrary_or_row_destination(tmp_path):
    oauth, calls = setup(tmp_path)
    oauth.callback(state(oauth), "one")
    with pytest.raises(ConnectorError, match="explicitly shared"):
        oauth.select_parent(LEDGER, "notion-default", OTHER)
    assert all(request.url.path != "/v1/databases" for request in calls)


def test_ambiguous_creation_is_not_retried(tmp_path):
    oauth, calls = setup(tmp_path, failure="/v1/databases")
    oauth.callback(state(oauth), "one")
    with pytest.raises(ConnectorError, match="no automatic"):
        oauth.select_parent(LEDGER, "notion-default", PARENT)
    assert oauth.connection_status(LEDGER)["pending"]
    assert oauth.ready_connections() == []
    with pytest.raises(ConnectorError, match="reconciliation"):
        oauth.select_parent(LEDGER, "notion-default", PARENT)
    assert sum(r.url.path == "/v1/databases" for r in calls) == 1


def test_rotation_persisted_and_once(tmp_path):
    oauth, calls = setup(tmp_path, expires=30)
    oauth.callback(state(oauth), "one")
    oauth.select_parent(LEDGER, "notion-default", PARENT)
    assert oauth.config(LEDGER)["token"] == "rotated-access"
    oauth.config(LEDGER)
    assert sum(r.url.path == "/v1/oauth/token" for r in calls) == 2
    assert b"rotated-refresh" not in oauth._db.read_bytes()


def test_lost_rotation_stops_and_does_not_replay(tmp_path):
    oauth, calls = setup(tmp_path, expires=30)
    oauth.callback(state(oauth), "one")
    oauth._client = httpx.Client(transport=httpx.MockTransport(lambda r: (_ for _ in ()).throw(httpx.ReadTimeout("private"))))
    with pytest.raises(ConnectorError, match="no automatic"):
        oauth.parent_pages(LEDGER)
    assert oauth.connection_status(LEDGER)["pending"]
    with pytest.raises(ConnectorError, match="reconciliation"):
        oauth.parent_pages(LEDGER)


def test_revoke_failure_stops_local_without_deleting_database(tmp_path):
    oauth, calls = setup(tmp_path, failure="/v1/oauth/revoke")
    oauth.callback(state(oauth), "one")
    oauth.select_parent(LEDGER, "notion-default", PARENT)
    result = oauth.disconnect(LEDGER)
    assert result == {"disconnected": True, "revoked": False}
    assert oauth.ready_connections() == []
    assert not oauth.connection_status(LEDGER)["connected"]
    assert not any(r.method in ("DELETE", "PATCH") for r in calls)


def test_config_file_private_and_callback_exact(tmp_path):
    config = tmp_path / "client.json"
    config.write_text(json.dumps({"client_id": "client", "client_secret": "private", "redirect_uri": URL+"/oauth/notion/callback"}))
    config.chmod(0o600)
    oauth = NotionOAuth.from_private_file(tmp_path / "store", URL, config)
    assert oauth.redirect_uri == URL + "/oauth/notion/callback"
    oauth.close()
    config.chmod(0o644)
    with pytest.raises(ConnectorError, match="owner-only"):
        NotionOAuth.from_private_file(tmp_path / "store", URL, config)
    config.chmod(0o600)
    with pytest.raises(ConnectorError, match="exact callback"):
        NotionOAuth.from_private_file(tmp_path / "store", "https://different.test", config)


def test_storage_symlinks_rejected(tmp_path):
    target = tmp_path / "real"
    target.mkdir()
    (tmp_path / "link").symlink_to(target, target_is_directory=True)
    with pytest.raises(ConnectorError, match="symlinks"):
        NotionOAuth(tmp_path / "link", "id", "private", URL)


def test_parent_pagination_never_returns_partial_selection(tmp_path):
    oauth, _ = setup(tmp_path)
    oauth.callback(state(oauth), "one")
    count = 0
    def handler(request):
        nonlocal count
        count += 1
        body = json.loads(request.content)
        if count > 1:
            assert body["start_cursor"] == "same-cursor"
        return httpx.Response(200, json={"results": [], "has_more": True, "next_cursor": "same-cursor"})
    oauth._client = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(ConnectorError, match="Incomplete"):
        oauth.parent_pages(LEDGER)
    assert count == 2


def test_invalid_database_result_is_pending_and_cannot_duplicate(tmp_path):
    oauth, _ = setup(tmp_path)
    oauth.callback(state(oauth), "one")
    original = oauth._request
    def request(method, path, **kwargs):
        if path == "databases":
            return {"id": DATABASE, "data_sources": []}
        return original(method, path, **kwargs)
    oauth._request = request
    with pytest.raises(ConnectorError, match="outcome unknown"):
        oauth.select_parent(LEDGER, "notion-default", PARENT)
    assert oauth.connection_status(LEDGER)["pending"]
    assert oauth.ready_connections() == []


def test_unknown_token_exchange_has_single_use_code(tmp_path):
    oauth, calls = setup(tmp_path, failure="/v1/oauth/token")
    value = state(oauth)
    with pytest.raises(ConnectorError, match="no automatic"):
        oauth.callback(value, "one")
    with pytest.raises(ConnectorError, match="expired"):
        oauth.callback(value, "one")
    assert len(calls) == 1
    assert oauth.connection_status(LEDGER)["pending"]
