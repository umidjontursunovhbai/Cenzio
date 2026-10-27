from copy import deepcopy
from pathlib import Path
from uuid import uuid4

from smartspend_mcp.connector_sync import reconcile, status, resolve_conflict
from smartspend_mcp.connectors import ExternalRecord, ConnectorError


def item():
    return {"id": str(uuid4()), "title": "Bus", "amount": "2500", "categoryId": str(uuid4()), "date": "2026-10-20T00:00:00.000Z"}


class Store:
    def __init__(self, path, expenses):
        self.path, self.ledger = path, str(uuid4())
        self.records = {e["id"]: {"expense": e, "archived": False, "revision": 1} for e in expenses}
        self.acks = set()
    def context(self):
        return {"ledgerId": self.ledger, "currency": "UZS"}
    def state_snapshot(self):
        return {**self.context(), "records": deepcopy(list(self.records.values()))}
    def exchange(self, request, source):
        op = request["operations"][0]
        if op["id"] not in self.acks:
            old = self.records.get(op["expenseId"])
            if op["baseRevision"] != (old["revision"] if old else 0):
                return {"acknowledgedOperationIds": []}
            self.records[op["expenseId"]] = {"expense": op["expense"] or old["expense"],
                "archived": op["kind"] == "archive", "revision": op["baseRevision"] + 1}
            self.acks.add(op["id"])
        return {"acknowledgedOperationIds": [op["id"]]}


class Adapter:
    currency = "UZS"
    def __init__(self, expenses):
        self.records = {e["id"]: ExternalRecord(deepcopy(e)) for e in expenses}
        self.writes = 0
    def fetch(self):
        return deepcopy(self.records)
    def put(self, record, expected=None):
        self.records[record.expense["id"]] = record
        self.writes += 1


def test_three_way_import_export_no_loops(tmp_path):
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([a])
    reconcile(store, provider, "sheets")
    store.records[a["id"]]["expense"]["title"] = "Metro"
    reconcile(store, provider, "sheets")
    assert provider.records[a["id"]].expense["title"] == "Metro"
    assert provider.writes == 1
    provider.records[a["id"]].expense["title"] = "Taxi"
    reconcile(store, provider, "sheets")
    assert store.records[a["id"]]["expense"]["title"] == "Taxi"
    reconcile(store, provider, "sheets")
    assert provider.writes == 1


def test_concurrent_changes_conflict_without_overwrite(tmp_path):
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([a])
    reconcile(store, provider, "sheets")
    store.records[a["id"]]["expense"]["title"] = "App edit"
    provider.records[a["id"]].expense["title"] = "Sheet edit"
    result = reconcile(store, provider, "sheets")
    assert result["conflicts"][a["id"]] == "concurrent_edits"
    assert provider.writes == 0


def test_missing_and_entire_empty_source_require_scoped_confirmation(tmp_path):
    a, b = item(), item()
    store, provider = Store(tmp_path / "store", [a, b]), Adapter([a, b])
    reconcile(store, provider, "sheets")
    provider.records.clear()
    result = reconcile(store, provider, "sheets")
    assert len(result["deletionProposals"]) == 2
    assert not any(r["archived"] for r in store.records.values())
    reconcile(store, provider, "sheets", confirmation_digest="wrong")
    assert not any(r["archived"] for r in store.records.values())
    reconcile(store, provider, "sheets", confirmation_digest=result["deletionDigest"])
    assert all(r["archived"] for r in store.records.values())


def test_unknown_outcome_persists_outbox_and_deduplicates(tmp_path):
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([])
    original = provider.put
    def fail_after_write(record, expected=None):
        original(record, expected=expected)
        raise ConnectorError("unknown outcome")
    provider.put = fail_after_write
    result = reconcile(store, provider, "sheets")
    assert a["id"] in result["pending"]
    path = str(store.path) + ".connectors.sqlite3"
    import sqlite3, json
    with sqlite3.connect(path) as conn:
        saved = status(path, "sheets")
        saved["retryAt"] = 0
        conn.execute("UPDATE connectors SET data=? WHERE id='sheets'", (json.dumps(saved),))
    provider.put = original
    result = reconcile(store, provider, "sheets")
    assert not result["pending"]
    assert provider.writes == 1


def test_explicit_single_delete_and_restore(tmp_path):
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([a])
    reconcile(store, provider, "sheets")
    provider.records[a["id"]] = ExternalRecord(a, True)
    reconcile(store, provider, "sheets")
    assert store.records[a["id"]]["archived"]
    provider.records[a["id"]] = ExternalRecord(a, False)
    reconcile(store, provider, "sheets")
    assert not store.records[a["id"]]["archived"]


def test_real_sync_store_history_and_category_validation(tmp_path):
    from smartspend_mcp.sync_store import SyncStore
    from conftest import snapshot, item as canonical_item, EXPENSE
    store = SyncStore(tmp_path / "real.sqlite3")
    store.bootstrap(snapshot())
    provider = Adapter([canonical_item()])
    reconcile(store, provider, "sheets")
    provider.records[EXPENSE].expense["title"] = "Provider edit"
    result = reconcile(store, provider, "sheets")
    assert not result["conflicts"]
    assert store.state_snapshot()["records"][0]["expense"]["title"] == "Provider edit"
    assert store.history(EXPENSE)["items"][-1]["source"] == "google_sheets"
    provider.records[EXPENSE].expense["categoryId"] = str(uuid4())
    result = reconcile(store, provider, "sheets")
    assert result["conflicts"][EXPENSE] == "canonical_revision_conflict"


def test_mass_explicit_delete_and_digest_changes_after_local_edit(tmp_path):
    a, b = item(), item()
    store, provider = Store(tmp_path / "store", [a, b]), Adapter([a, b])
    reconcile(store, provider, "sheets")
    provider.records = {key: ExternalRecord(r.expense, True) for key, r in provider.records.items()}
    result = reconcile(store, provider, "sheets")
    assert len(result["conflicts"]) == 2
    store.records[a["id"]]["revision"] += 1
    second = reconcile(store, provider, "sheets", confirmation_digest=result["deletionDigest"])
    assert second["deletionDigest"] != result["deletionDigest"]
    assert not any(r["archived"] for r in store.records.values())


def test_explicit_content_bound_conflict_resolution(tmp_path):
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([a])
    reconcile(store, provider, "sheets")
    store.records[a["id"]]["expense"]["title"] = "App edit"
    provider.records[a["id"]].expense["title"] = "Sheet edit"
    result = reconcile(store, provider, "sheets")
    digest = result["conflictDetails"][a["id"]]["digest"]
    import pytest
    with pytest.raises(ConnectorError, match="changed"):
        resolve_conflict(store, provider, "sheets", a["id"], "provider", "wrong")
    resolve_conflict(store, provider, "sheets", a["id"], "provider", digest)
    result = reconcile(store, provider, "sheets")
    assert not result["conflicts"]
    assert store.records[a["id"]]["expense"]["title"] == "Sheet edit"


def test_sidecar_symlink_cannot_read_modify_or_chmod_target(tmp_path, monkeypatch):
    import pytest
    import os
    import smartspend_mcp.connector_sync as module
    target = tmp_path / "unrelated"
    target.write_text("private unrelated content")
    target.chmod(0o644)
    path = tmp_path / "state.sqlite3"
    path.symlink_to(target)
    calls = []
    monkeypatch.setattr(module.sqlite3, "connect", lambda *a, **kw: calls.append(a))
    with pytest.raises(OSError):
        status(path, "sheets")
    assert not calls
    assert target.read_text() == "private unrelated content"
    assert os.stat(target).st_mode & 0o777 == 0o644


def test_lock_symlink_cannot_touch_target_or_contact_provider(tmp_path):
    import pytest
    import os
    a = item()
    store, provider = Store(tmp_path / "store", [a]), Adapter([a])
    target = tmp_path / "unrelated"
    target.write_text("unchanged")
    target.chmod(0o644)
    Path(str(store.path) + ".connectors.sqlite3.lock").symlink_to(target)
    def never_fetch():
        raise AssertionError("Provider must not be contacted")
    provider.fetch = never_fetch
    with pytest.raises(OSError):
        reconcile(store, provider, "sheets")
    assert target.read_text() == "unchanged"
    assert os.stat(target).st_mode & 0o777 == 0o644


def test_nonprivate_sidecar_rejected_without_chmod(tmp_path):
    import pytest
    import os
    path = tmp_path / "state.sqlite3"
    path.write_text("preserve me")
    path.chmod(0o644)
    with pytest.raises(ConnectorError):
        status(path, "sheets")
    assert path.read_text() == "preserve me"
    assert os.stat(path).st_mode & 0o777 == 0o644


def test_status_closes_every_sqlite_connection(tmp_path, monkeypatch):
    import sqlite3
    import pytest
    import smartspend_mcp.connector_sync as module
    connect, connections = module.sqlite3.connect, []
    def tracked(*args, **kwargs):
        connection = connect(*args, **kwargs)
        connections.append(connection)
        return connection
    monkeypatch.setattr(module.sqlite3, "connect", tracked)
    path = tmp_path / "state.sqlite3"
    status(path, "sheets")
    status(path, "sheets")
    for connection in connections:
        with pytest.raises(sqlite3.ProgrammingError, match="closed"):
            connection.execute("SELECT 1")
