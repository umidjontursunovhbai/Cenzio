"""Provider lifecycle and read-only existing-table route regression tests."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event

from starlette.testclient import TestClient

from smartspend_mcp.sync_service import SyncRepository, create_app
from conftest import LEDGER, CATEGORY, key, snapshot


def test_existing_notion_preview_uses_only_authenticated_canonical_context(tmp_path):
    class Notion:
        previews = []
        def ready_connections(self): return []
        def authorized_sources(self, ledger, connector):
            assert ledger == LEDGER and connector == "notion-default"
            return {"sources": [{"id": CATEGORY, "title": "Existing expenses", "schema": {}}], "hasMore": False}
        def preview_existing_source(self, ledger, connector, source, mapping, categories, currency, zone):
            self.previews.append((ledger, connector, source, mapping, categories, currency, zone))
            return {"readOnly": True, "canSync": False, "totalRows": 0, "samples": []}
    repository = SyncRepository(tmp_path)
    repository.ledger(LEDGER).bootstrap(snapshot())
    _, token = repository.grants.issue(LEDGER)
    notion = Notion()
    app = create_app(repository, public_url="https://sync.example", notion_oauth=notion)
    headers = {"Authorization": "Bearer " + token}
    mapping = {"title": "Expense", "amount": "Cost", "date": "When", "category": "Type", "categoryMap": {}}
    payload = {"consent": True, "dataSourceId": CATEGORY, "mapping": mapping}
    with TestClient(app, base_url="https://sync.example") as client:
        assert client.get("/v1/connectors/notion/sources").status_code == 401
        assert client.get("/v1/connectors/notion/sources", headers=headers).status_code == 200
        assert client.post("/v1/connectors/notion/preview", headers=headers, json={**payload, "currency": "USD"}).status_code == 400
        assert client.post("/v1/connectors/notion/preview", headers=headers, json={**payload, "consent": False}).status_code == 400
        response = client.post("/v1/connectors/notion/preview", headers=headers, json=payload)
        assert response.status_code == 200 and response.json()["canSync"] is False
    assert len(notion.previews) == 1
    ledger, connector, source, actual, categories, currency, zone = notion.previews[0]
    assert (ledger, connector, source, actual) == (LEDGER, "notion-default", CATEGORY, mapping)
    assert categories == repository.ledger(LEDGER).context()["categories"]
    assert (currency, zone) == ("UZS", "Asia/Tashkent")
    assert len(repository.ledger(LEDGER).state_snapshot()["records"]) == 1


def test_disconnect_waits_for_inflight_poll_and_destination_has_own_outbox(tmp_path, monkeypatch):
    class Google:
        active = True
        def ready_connections(self):
            return [{"ledgerId": LEDGER, "connectorId": "google-default"}] if self.active else []
        def connection_status(self, ledger, connector):
            return {"connected": self.active, "spreadsheetId": "synthetic-destination-one"}
        def config(self, ledger, connector):
            assert self.active
            return {"token": "synthetic-provider-value", "spreadsheetId": "synthetic-destination-one", "tab": "Sheet1"}
        def disconnect(self, ledger, connector):
            self.active = False
            return {"disconnected": True}
    started, release = Event(), Event()
    instances = []
    def reconcile(ledger, adapter, connector):
        instances.append(connector)
        started.set()
        assert release.wait(5)
    monkeypatch.setattr("smartspend_mcp.connector_sync.reconcile", reconcile)
    repository = SyncRepository(tmp_path)
    repository.ledger(LEDGER).bootstrap(snapshot())
    _, token = repository.grants.issue(LEDGER)
    manager = Google()
    app = create_app(repository, public_url="https://sync.example", google_oauth=manager)
    with TestClient(app, base_url="https://sync.example") as client, ThreadPoolExecutor() as pool:
        assert started.wait(3)
        future = pool.submit(client.post, "/v1/connectors/google/disconnect",
            headers={"Authorization": "Bearer " + token}, json={"consent": True, "connectorId": "google-default"})
        assert not future.done()
        release.set()
        assert future.result(timeout=5).status_code == 200
        assert not manager.active
    assert len(instances) == 1 and instances[0].startswith("google-default-")
    assert instances[0] != "google-default"
