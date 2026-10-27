"""Independent HTTP privacy/ownership checks with synthetic ledgers only."""
import secrets

from starlette.testclient import TestClient

from smartspend_mcp.device_enrollment import DeviceEnrollment
from smartspend_mcp.sync_service import SyncRepository, create_app
from conftest import key, snapshot


def enrollment(ledger=None):
    return {"installationId": key(), "ownerProof": secrets.token_urlsafe(32),
            "ledgerId": ledger or key(), "consent": True}


def auth(token):
    return {"Authorization": "Bearer " + token}


class NotionFixture:
    """Never makes real network calls or reveals a provider access token."""
    def ready_connections(self):
        return []

    def connection_status(self, ledger, connector="notion-default"):
        assert connector == "notion-default"
        return {"connected": True, "databaseId": ledger}

    def parent_pages(self, ledger, connector="notion-default"):
        assert connector == "notion-default"
        return {"pages": [{"id": ledger, "title": "private-" + ledger}], "hasMore": False}


def test_public_service_does_not_silently_enable_installation_enrollment(tmp_path):
    repository = SyncRepository(tmp_path / "private")
    app = create_app(repository, public_url="https://sync.example")
    with TestClient(app, base_url="https://sync.example") as client:
        response = client.post("/v1/device/enroll", json=enrollment())
        assert response.status_code in {403, 404, 503}
        assert "token" not in response.json()
        capabilities = client.get("/v1/connectors/capabilities")
        assert capabilities.status_code == 200
        assert capabilities.json() == {"deviceEnrollment": False, "google": False, "notion": False}
        assert capabilities.headers["cache-control"] == "no-store"


def test_http_installation_claim_retry_and_scoped_ledger_no_private_leak(tmp_path):
    repository = SyncRepository(tmp_path / "private")
    devices = DeviceEnrollment(repository.grants, repository.root)
    app = create_app(repository, public_url="https://sync.example", device_enrollment=devices)
    first, second = enrollment(), enrollment()
    with TestClient(app, base_url="https://sync.example") as client:
        registered = client.post("/v1/device/enroll", json=first)
        assert registered.status_code == 200
        token = registered.json()["token"]
        assert client.post("/v1/device/enroll", json=first).json() == registered.json()
        assert client.post("/v1/device/enroll", json={**first, "ownerProof": secrets.token_urlsafe(32)}).status_code == 403
        assert client.post("/v1/device/enroll", json=enrollment(first["ledgerId"])).status_code == 403
        other_token = client.post("/v1/device/enroll", json=second).json()["token"]
        private = snapshot(ledgerId=first["ledgerId"])
        assert client.post("/v1/sync/bootstrap", headers=auth(token), json=private).status_code == 200
        # An ambiguous bootstrap retry cannot replace canonical records.
        repeated = client.post("/v1/sync/bootstrap", headers=auth(token), json=private)
        assert repeated.status_code == 409
        assert "Lunch" not in repeated.text
        retry_snapshot = client.get("/v1/sync/snapshot", headers=auth(token))
        assert retry_snapshot.status_code == 200
        assert retry_snapshot.json()["records"][0]["expense"]["title"] == "Lunch"
        cross = client.post("/v1/sync/bootstrap", headers=auth(other_token), json=private)
        assert cross.status_code == 403
        assert "Lunch" not in cross.text
        unauthenticated = client.get("/v1/sync/snapshot")
        assert unauthenticated.status_code == 401
        assert "Lunch" not in unauthenticated.text


def test_enrollment_attempt_limit_returns_429_and_revoke_requires_ownership(tmp_path):
    repository = SyncRepository(tmp_path / "private")
    devices = DeviceEnrollment(repository.grants, repository.root, hourly_peer_limit=2)
    app = create_app(repository, public_url="https://sync.example", device_enrollment=devices)
    data = enrollment()
    with TestClient(app, base_url="https://sync.example") as client:
        response = client.post("/v1/device/enroll", json=data)
        token = response.json()["token"]
        assert client.post("/v1/device/enroll", json=data).status_code == 200
        assert client.post("/v1/device/enroll", json=data).status_code == 429
        assert client.post("/v1/device/enroll", json=data, headers={"X-Forwarded-For": "198.51.100.77"}).status_code == 429
        forged = {"installationId": data["installationId"], "ownerProof": secrets.token_urlsafe(32), "consent": True}
        assert client.post("/v1/device/revoke", json=forged).status_code == 403
        assert repository.grants.verify(token) is not None
        revoked = client.post("/v1/device/revoke", json={k: data[k] for k in ("installationId", "ownerProof", "consent")})
        assert revoked.status_code == 200
        assert repository.grants.verify(token) is None
        assert client.get("/v1/sync/context", headers=auth(token)).status_code == 401


def test_expired_installation_http_renews_with_retained_proof_only(tmp_path, monkeypatch):
    repository = SyncRepository(tmp_path / "private")
    devices = DeviceEnrollment(repository.grants, repository.root)
    app = create_app(repository, public_url="https://sync.example", device_enrollment=devices)
    data = enrollment()
    with TestClient(app, base_url="https://sync.example") as client:
        first = client.post("/v1/device/enroll", json=data).json()
        monkeypatch.setattr("smartspend_mcp.device_enrollment.time.time", lambda: first["expiresAt"] + 1)
        assert client.get("/v1/sync/context", headers=auth(first["token"])).status_code == 401
        renewed = client.post("/v1/device/enroll", json=data)
        assert renewed.status_code == 200
        assert renewed.json()["token"] != first["token"]
        assert renewed.json()["ledgerId"] == first["ledgerId"]
        # No bootstrap/upload is needed to recover the installation grant.
        assert client.get("/v1/sync/context", headers=auth(renewed.json()["token"])).status_code == 404
        forged = {**data, "ownerProof": secrets.token_urlsafe(32)}
        assert client.post("/v1/device/enroll", json=forged).status_code == 403


def test_notion_private_status_and_parent_pages_bound_to_authenticated_ledger(tmp_path):
    repository = SyncRepository(tmp_path / "private")
    first, second = key(), key()
    repository.ledger(first).bootstrap(snapshot(ledgerId=first))
    repository.ledger(second).bootstrap(snapshot(ledgerId=second))
    _, token_a = repository.grants.issue(first)
    _, token_b = repository.grants.issue(second)
    _, read_only = repository.grants.issue(first, {"ledger:read"})
    app = create_app(repository, public_url="https://sync.example", notion_oauth=NotionFixture())
    with TestClient(app, base_url="https://sync.example") as client:
        for route in ("status", "parents"):
            assert client.get("/v1/connectors/notion/" + route).status_code == 401
            own = client.get("/v1/connectors/notion/" + route + "?ledgerId=" + second, headers=auth(token_a))
            assert own.status_code == 200
            assert first in own.text
            assert second not in own.text
            other = client.get("/v1/connectors/notion/" + route, headers=auth(token_b))
            assert second in other.text
            assert first not in other.text
        for action in ("start", "select", "disconnect"):
            response = client.post("/v1/connectors/notion/" + action, headers=auth(read_only), json={"consent": True})
            assert response.status_code == 403
