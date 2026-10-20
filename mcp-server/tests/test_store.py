from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor

import pytest

from smartspend_mcp.store import LedgerStore
from smartspend_mcp.validation import LedgerError, amount_text, date_text, fingerprint

from conftest import CATEGORY, EXPENSE, LEDGER, item, key, snapshot


def test_persistence_decimal_summary_and_timezone(store):
    new_item = item(id=key(), amount="0.10", date="2026-10-19T20:00:00+00:00")
    store.create(new_item, key())
    store.create(item(id=key(), amount="0.2", date="2026-10-20T01:00:00+05:00"), key())
    reopened = LedgerStore(store.path)
    result = reopened.summary("2026-10-20T00:00:00+05:00", "2026-10-21T00:00:00+05:00")
    assert result["total"] == "15800.3"
    assert result["count"] == 3
    assert result["byDay"] == [{"date": "2026-10-20", "total": "15800.3"}]
    assert os.stat(store.path).st_mode & 0o777 == 0o600


def test_create_retry_is_idempotent_across_restart(store):
    expense, action = item(id=key()), key()
    first = store.create(expense, action)
    second = LedgerStore(store.path).create(expense, action)
    assert second["idempotentReplay"] is True
    assert first["operationId"] == second["operationId"]
    assert store.context()["activeExpenseCount"] == 2
    assert store.context()["pendingOperationCount"] == 1
    with pytest.raises(LedgerError, match="different arguments"):
        store.create({**expense, "amount": "55"}, action)


def test_pending_limit_matches_app_and_retries_still_work(store, monkeypatch):
    monkeypatch.setattr("smartspend_mcp.store.MAX_PENDING_OPERATIONS", 1)
    expense, action = item(id=key()), key()
    first = store.create(expense, action)
    assert store.create(expense, action)["operationId"] == first["operationId"]
    with pytest.raises(LedgerError, match="Pending operation limit"):
        store.create(item(id=key()), key())
    assert len(store.export_operations()["operations"]) == 1


def test_empty_app_can_initialize_with_no_categories(tmp_path):
    ledger = LedgerStore(tmp_path / "empty.sqlite3")
    ledger.import_snapshot(snapshot(expenses=[], categories=[]))
    assert ledger.context()["activeExpenseCount"] == 0
    assert ledger.categories()["categories"] == []


def test_concurrent_retries_only_create_once(store):
    expense, action = item(id=key()), key()
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda _: store.create(expense, action), range(12)))
    assert len({result["operationId"] for result in results}) == 1
    assert store.context()["pendingOperationCount"] == 1


def test_revision_conflict_is_atomic(store):
    result = store.update(EXPENSE, 1, item(amount="30000"), key())
    assert result["expense"]["revision"] == 2
    before = store.context()
    with pytest.raises(LedgerError, match="Revision conflict"):
        store.update(EXPENSE, 1, item(amount="100"), key())
    assert store.get_expense(EXPENSE)["expense"]["amount"] == "30000"
    assert store.context() == before


def test_archive_restore_and_no_hard_delete(store):
    archived = store.archive(EXPENSE, 1, key())
    assert archived["expense"]["archived"] is True
    assert store.list_expenses()["expenses"] == []
    assert store.list_expenses(archived=True)["expenses"][0]["id"] == EXPENSE
    with pytest.raises(LedgerError, match="archived"):
        store.update(EXPENSE, 2, item(title="Edited"), key())
    with pytest.raises(LedgerError, match="already exists"):
        store.create(item(), key())
    restored = store.restore(EXPENSE, 2, key())
    assert restored["expense"]["archived"] is False
    assert restored["expense"]["revision"] == 3
    assert len(store.history(EXPENSE)["history"]) == 3


def test_auditable_undo_and_stale_undo_refusal(store):
    changed = store.update(EXPENSE, 1, item(amount="99"), key())
    undone = store.undo(changed["operationId"], 2, key())
    assert undone["expense"]["amount"] == "15800"
    assert store.history(EXPENSE)["history"][-1]["action"] == f"undo:{changed['operationId']}"
    with pytest.raises(LedgerError, match="changed since"):
        store.undo(changed["operationId"], 3, key())


def test_undo_create_archives_and_undo_archive_restores(store):
    created = store.create(item(id=key()), key())
    expense_id = created["expense"]["id"]
    undone = store.undo(created["operationId"], 1, key())
    assert undone["kind"] == "archive"
    restored = store.undo(undone["operationId"], 2, key())
    assert restored["kind"] == "restore"
    assert restored["expense"]["id"] == expense_id


def test_undo_rejects_intervening_aba_edits(store):
    first = store.update(EXPENSE, 1, item(amount="12"), key())
    store.update(EXPENSE, 2, item(amount="14"), key())
    store.update(EXPENSE, 3, item(amount="12"), key())
    with pytest.raises(LedgerError, match="changed since"):
        store.undo(first["operationId"], 4, key())


def test_export_chain_has_exact_fingerprints_and_does_not_clear(store):
    changed = item(title="Taxi\nТашкент 🚕", amount="12.50", date="2026-10-20T12:30:00+05:00")
    store.update(EXPENSE, 1, changed, key())
    store.archive(EXPENSE, 2, key())
    operations = store.export_operations()
    assert operations == store.export_operations()
    assert operations["ledgerId"] == LEDGER
    assert operations["operations"][0]["baseFingerprint"] == fingerprint(item())
    assert operations["operations"][1]["baseFingerprint"] == fingerprint(changed)
    assert operations["operations"][0]["expense"]["date"] == "2026-10-20T07:30:00.000Z"
    assert operations["operations"][0]["expense"]["amount"] == "12.5"
    assert store.context()["pendingOperationCount"] == 2


def test_reimport_requires_revision_and_all_pending_receipts(store):
    result = store.update(EXPENSE, 1, item(amount="25"), key())
    document = snapshot(expenses=[item(amount="25")])
    with pytest.raises(LedgerError, match="expected-revision"):
        store.import_snapshot(document)
    with pytest.raises(LedgerError, match="Unacknowledged"):
        store.import_snapshot(document, expected_revision=2)
    document["appliedOperationIds"] = [result["operationId"]]
    store.import_snapshot(document, expected_revision=2)
    assert store.export_operations()["operations"] == []
    assert store.get_expense(EXPENSE)["expense"]["amount"] == "25"


def test_snapshot_deletion_retains_tombstone_and_history(store):
    store.import_snapshot(snapshot(expenses=[]), expected_revision=1)
    assert store.get_expense(EXPENSE)["expense"]["archived"] is True
    assert len(store.history(EXPENSE)["history"]) == 2
    assert store.context()["pendingOperationCount"] == 0


@pytest.mark.parametrize("change", [
    {"ledgerId": "not-a-uuid"}, {"currency": "BTC"}, {"currency": "USD"},
    {"schemaVersion": True}, {"schemaVersion": 2}, {"timeZone": "Mars/Test"},
    {"expenses": [item(), item()]}, {"expenses": [item(categoryId=key())]},
    {"archivedExpenses": [item()]}, {"expenses": [item(amount="NaN")]},
])
def test_invalid_snapshot_cannot_partially_mutate(store, change):
    before = store.context()
    with pytest.raises(LedgerError):
        store.import_snapshot(snapshot(**change), expected_revision=1)
    assert store.context() == before
    assert store.get_expense(EXPENSE)["expense"]["amount"] == "15800"


@pytest.mark.parametrize("amount", ["0", "-1", "1,000", "1e3", "NaN", "Infinity", "01", " 1", 1.2, "1000000000000", "0.1234567", "123456789012.1234"])
def test_invalid_money(amount):
    with pytest.raises(LedgerError):
        amount_text(amount)


@pytest.mark.parametrize("date", ["2026-10-20", "2026-10-20T12:00:00", "2026-02-30T01:00:00Z", "2026-10-20T12:00:00.1234Z", "2300-01-01T00:00:00Z"])
def test_invalid_dates(date):
    with pytest.raises(LedgerError):
        date_text(date)


def test_category_ownership_and_currency_scope(store):
    with pytest.raises(LedgerError, match="Unknown category"):
        store.create(item(id=key(), categoryId=key()), key())
    with pytest.raises(LedgerError, match="mismatch"):
        store.import_snapshot(snapshot(ledgerId=key()), expected_revision=1)


def test_pagination_is_bounded_stable_and_invalidates_on_write(store):
    for index in range(5):
        store.create(item(id=key(), title=f"ТАКСИ {index}"), key())
    first = store.list_expenses(query="такси", limit=2)
    second = store.list_expenses(query="такси", limit=2, cursor=first["nextCursor"])
    assert len(first["expenses"]) == len(second["expenses"]) == 2
    assert not ({item["id"] for item in first["expenses"]} & {item["id"] for item in second["expenses"]})
    with pytest.raises(LedgerError, match="filters changed"):
        store.list_expenses(query="Food", limit=2, cursor=first["nextCursor"])
    store.create(item(id=key()), key())
    with pytest.raises(LedgerError, match="ledger changed"):
        store.list_expenses(query="такси", limit=2, cursor=first["nextCursor"])
    with pytest.raises(LedgerError):
        store.list_expenses(limit=1000)
    with pytest.raises(LedgerError):
        store.list_expenses(cursor="rubbish")


def test_half_open_range_and_literal_search(store):
    assert store.summary("2026-10-20T07:30:00Z", "2026-10-20T07:30:01Z")["count"] == 1
    assert store.summary("2026-10-20T00:00:00Z", "2026-10-20T07:30:00Z")["count"] == 0
    assert store.list_expenses(query="%' OR 1=1 --")["expenses"] == []
    with pytest.raises(LedgerError):
        store.summary("2026-10-20T07:30:00Z", "2026-10-20T07:30:00Z")


def test_fingerprint_canonicalization_and_ambiguity():
    assert fingerprint(item()) == "8e0ab1778172f498ce9077aa7d916ba18b6f2b4cd831718933a4930acd9633f2"
    assert fingerprint({"id": "00000000-0000-0000-0000-000000000001", "title": "Кофе / ☕", "amount": "12.5", "categoryId": "00000000-0000-0000-0000-000000000002", "date": "2026-10-20T12:34:56.789Z"}) == "17411ead3adf7a874dc472b2316bd124c1a16454e141fd10c8c3480513fe28e7"
    assert fingerprint(item(amount="15800.00", date="2026-10-20T12:30:00+05:00")) == fingerprint(item())
    assert fingerprint(item(title="a\nb")) != fingerprint(item(title="a\nb\n"))
    assert len(fingerprint(item())) == 64
