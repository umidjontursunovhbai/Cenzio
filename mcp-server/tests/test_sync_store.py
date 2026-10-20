from concurrent.futures import ThreadPoolExecutor
import os
import sqlite3

import pytest

from smartspend_mcp.sync_store import SyncStore
from smartspend_mcp.validation import LedgerError
from conftest import CATEGORY, EXPENSE, LEDGER, item, key, snapshot


@pytest.fixture
def sync(tmp_path):
    store = SyncStore(tmp_path / "sync.sqlite3")
    store.bootstrap(snapshot())
    return store


def operation(kind="update", revision=1, expense_id=EXPENSE, **changes):
    return {"id":key(),"kind":kind,"expenseId":expense_id,"baseRevision":revision,
            "expense":item(id=expense_id,**changes) if kind in ("create","update") else None}


def request(*ops, **changes):
    return {"schemaVersion":1,"ledgerId":LEDGER,"currency":"UZS","clientId":key(),
            "afterSequence":0,"operations":list(ops),**changes}


def test_bootstrap_is_once_no_snapshot_replacement(sync):
    before = sync.state_snapshot()
    with pytest.raises(LedgerError,match="Already initialized"):
        sync.bootstrap(snapshot(expenses=[]))
    assert sync.state_snapshot() == before


def test_empty_source_does_not_delete(sync):
    result = sync.exchange(request())
    assert len(result["changes"]) == 1
    assert result["changes"][0]["source"] == "bootstrap"
    assert not sync.state_snapshot()["records"][0]["archived"]


def test_idempotent_update_across_restart(sync):
    op = operation(amount="20.00")
    result = sync.exchange(request(op))
    reopened = SyncStore(sync.path)
    second = reopened.exchange(request(op))
    assert second["acknowledgedOperationIds"] == result["acknowledgedOperationIds"]
    assert len(second["changes"]) == 2
    assert reopened.state_snapshot()["records"][0]["expense"]["amount"] == "20"
    op["expense"]["title"] = "Different"
    with pytest.raises(LedgerError,match="different arguments"):
        reopened.exchange(request(op))


def test_conflicting_operation_stays_conflicting_even_after_revision_changes(sync):
    stale = operation(revision=2,amount="1")
    first = sync.exchange(request(stale))["conflicts"]
    sync.exchange(request(operation(amount="50")))
    assert SyncStore(sync.path).exchange(request(stale))["conflicts"] == first
    assert sync.state_snapshot()["records"][0]["expense"]["amount"] == "50"


def test_two_clients_offline_cas(sync):
    a,b = operation(title="A"),operation(title="B")
    assert sync.exchange(request(a))["acknowledgedOperationIds"] == [a["id"]]
    result = sync.exchange(request(b))
    assert result["conflicts"][0]["reason"] == "revision_conflict"
    assert result["conflicts"][0]["current"]["expense"]["title"] == "A"
    assert sync.state_snapshot()["records"][0]["revision"] == 2


def test_parallel_same_operation_exactly_once(sync):
    op = operation()
    with ThreadPoolExecutor(max_workers=4) as pool:
        result = list(pool.map(lambda _:sync.exchange(request(op)),range(8)))
    assert all(r["acknowledgedOperationIds"] == [op["id"]] for r in result)
    assert len(sync.history(EXPENSE)["items"]) == 2


def test_explicit_archive_and_restore_preserves_record(sync):
    sync.exchange(request(operation("archive")))
    archived = sync.state_snapshot()["records"][0]
    assert archived["archived"] and archived["revision"] == 2
    assert sync.exchange(request(operation(revision=2)))["conflicts"][0]["reason"] == "archived"
    sync.exchange(request(operation("restore",revision=2)))
    assert not sync.state_snapshot()["records"][0]["archived"]
    hist = sync.history(EXPENSE)["items"]
    assert [h["kind"] for h in hist] == ["create","archive","restore"]
    assert hist[1]["before"]["expense"] == hist[1]["after"]["expense"]


def test_restore_history_appends_cas_and_retry(sync):
    initial = sync.history(EXPENSE)["items"][0]
    sync.exchange(request(operation(title="Updated")),source="mcp")
    op_id = key()
    result = sync.restore_version(EXPENSE,initial["sequence"],2,op_id)
    assert result["acknowledged"] and result["current"]["revision"] == 3
    assert result["current"]["expense"]["title"] == "Lunch"
    assert sync.restore_version(EXPENSE,initial["sequence"],2,op_id) == result
    stale = sync.restore_version(EXPENSE,initial["sequence"],2,key())
    assert stale["reason"] == "revision_conflict"
    assert len(sync.history(EXPENSE)["items"]) == 3


def test_restore_archived_version_retains_tombstone(sync):
    sync.exchange(request(operation("archive")))
    sequence = sync.history(EXPENSE)["items"][-1]["sequence"]
    sync.exchange(request(operation("restore",revision=2)))
    restored = sync.restore_version(EXPENSE,sequence,3,key())
    assert restored["current"]["archived"]


def test_history_pagination_no_gaps(sync):
    sync.exchange(request(operation(),operation(revision=2),operation(revision=3)))
    a = sync.history(EXPENSE,limit=2)
    b = sync.history(EXPENSE,after_sequence=a["nextSequence"],limit=2)
    assert a["hasMore"] and not b["hasMore"]
    assert [r["sequence"] for r in a["items"]+b["items"]] == [1,2,3,4]


def test_change_pagination_200(sync):
    for _ in range(3):
        sync.exchange(request(*(operation("create",revision=0,expense_id=key()) for _ in range(90))))
    page = sync.exchange(request())
    assert len(page["changes"]) == 200 and page["hasMore"]
    rest = sync.exchange(request(afterSequence=page["nextSequence"]))
    assert len(rest["changes"]) == 71 and not rest["hasMore"]


def test_category_validation_is_durable_conflict(sync):
    op = operation(categoryId=key())
    assert sync.exchange(request(op))["conflicts"][0]["reason"] == "unknown_category"
    assert len(sync.history(EXPENSE)["items"]) == 1


@pytest.mark.parametrize("changes",[{"currency":"USD"},{"ledgerId":key()},
    {"afterSequence":2},{"afterSequence":-1},{"afterSequence":True},{"schemaVersion":True},
    {"operations":[{}]*101},{"clientId":"bad"}])
def test_invalid_request_no_mutation(sync,changes):
    before = sync.state_snapshot()
    with pytest.raises(LedgerError):
        sync.exchange(request(**changes))
    assert before == sync.state_snapshot()


def test_invalid_second_op_rolls_back_entire_batch(sync):
    with pytest.raises(LedgerError):
        sync.exchange(request(operation(),{"id":"invalid"}))
    assert len(sync.history(EXPENSE)["items"]) == 1


def test_source_validation(sync):
    with pytest.raises(LedgerError):
        sync.exchange(request(operation()),source="x'; DROP TABLE sync_meta; --")
    assert sync.context()["ledgerId"] == LEDGER


def test_backup_private_consistent_reopen_original_unchanged(sync,tmp_path):
    path = tmp_path / "backup.sqlite3"
    result = sync.backup(path)
    assert result["ledgerId"] == LEDGER
    assert os.stat(path).st_mode & 0o777 == 0o600
    restored = SyncStore(path)
    assert restored.state_snapshot() == sync.state_snapshot()
    restored.exchange(request(operation(title="Backup only")))
    assert sync.state_snapshot()["records"][0]["expense"]["title"] == "Lunch"
    assert sync.validate_backup(path)["revision"] == 2


def test_backup_refuses_existing_symlink_original_and_invalid(sync,tmp_path):
    existing = tmp_path / "existing"
    existing.write_text("keep")
    link = tmp_path / "link"
    link.symlink_to(existing)
    for target in (existing,link,sync.path):
        with pytest.raises((FileExistsError,LedgerError)):
            sync.backup(target)
    assert existing.read_text() == "keep"
    with pytest.raises(LedgerError):
        sync.validate_backup(existing)
    with pytest.raises(LedgerError):
        SyncStore(link)


def test_history_is_stored_separately_from_materialized_state(sync):
    sync.exchange(request(operation(title="New")))
    with sqlite3.connect(sync.path) as db:
        assert db.execute("SELECT COUNT(*) FROM sync_history").fetchone()[0] == 2
        assert db.execute("SELECT COUNT(*) FROM sync_operations").fetchone()[0] == 1


def test_initial_archived_records_and_empty_new_ledger(tmp_path):
    store = SyncStore(tmp_path / "archived.sqlite3")
    store.bootstrap(snapshot(expenses=[],archivedExpenses=[item()]))
    change = store.exchange(request())["changes"][0]
    assert change["archived"] and change["revision"] == 1
    empty = SyncStore(tmp_path / "empty.sqlite3")
    empty.bootstrap(snapshot(expenses=[],categories=[]))
    assert empty.state_snapshot()["nextSequence"] == 0
    assert empty.exchange(request())["changes"] == []


def test_conflict_payload_mismatch_refused(sync):
    op = operation(revision=10)
    sync.exchange(request(op))
    op["baseRevision"] = 1
    with pytest.raises(LedgerError,match="different arguments"):
        sync.exchange(request(op))


def test_operation_identity_includes_trusted_source(sync):
    op = operation()
    sync.exchange(request(op),source="notion")
    with pytest.raises(LedgerError,match="different arguments"):
        sync.exchange(request(op),source="google_sheets")


def test_bootstrap_validation_rolls_back_all(tmp_path):
    store = SyncStore(tmp_path / "invalid.sqlite3")
    with pytest.raises(LedgerError,match="Unknown category"):
        store.bootstrap(snapshot(expenses=[item(categoryId=key())]))
    store.bootstrap(snapshot())
    assert len(store.state_snapshot()["records"]) == 1


def test_partial_or_tampered_backup_rejected(sync,tmp_path):
    path = tmp_path / "backup.sqlite3"
    sync.backup(path)
    with sqlite3.connect(path) as db:
        db.execute("DROP TABLE sync_operations")
    with pytest.raises(LedgerError,match="Invalid sync backup"):
        sync.validate_backup(path)
    path2 = tmp_path / "tampered.sqlite3"
    sync.backup(path2)
    with sqlite3.connect(path2) as db:
        db.execute("UPDATE sync_records SET data=replace(data,'Lunch','Bad')")
    with pytest.raises(LedgerError,match="integrity"):
        sync.validate_backup(path2)
    assert sync.state_snapshot()["records"][0]["expense"]["title"] == "Lunch"


def test_history_restore_cannot_target_different_expense(sync):
    with pytest.raises(LedgerError,match="not found"):
        sync.restore_version(key(),1,1,key())
    assert len(sync.history(EXPENSE)["items"]) == 1


def test_category_cas_upsert_retains_referenced_missing_categories(sync):
    new_id = key()
    updated = sync.upsert_categories([{"id":new_id,"name":"Transport"}],1)
    assert updated["revision"] == 2 and len(updated["categories"]) == 2
    assert CATEGORY in [c["id"] for c in updated["categories"]]
    assert sync.upsert_categories([],2) == updated
    assert sync.state_snapshot()["nextSequence"] == 1
    assert sync.exchange(request(operation(categoryId=new_id)))["acknowledgedOperationIds"]
    with pytest.raises(LedgerError,match="revision conflict"):
        sync.upsert_categories([{"id":new_id,"name":"Stale"}],2)
    assert next(c for c in sync.context()["categories"] if c["id"]==new_id)["name"] == "Transport"


def test_category_rename_audited_atomic_and_backup(sync,tmp_path):
    renamed = sync.upsert_categories([{"id":CATEGORY,"name":"Ovqat"}],1,source="owner")
    assert renamed["categories"][0]["name"] == "Ovqat"
    with sqlite3.connect(sync.path) as db:
        row = db.execute("SELECT beforeState,afterState,source FROM sync_catalog_history").fetchone()
        assert "Food" in row[0] and "Ovqat" in row[1] and row[2] == "owner"
    backup = tmp_path / "catalog.sqlite3"
    sync.backup(backup)
    assert SyncStore(backup).context() == renamed


@pytest.mark.parametrize("categories",[None,{},[{}],[{"id":CATEGORY,"name":" "}],
    [{"id":CATEGORY,"name":"A"},{"id":CATEGORY,"name":"B"}]])
def test_malformed_catalog_no_partial_mutation(sync,categories):
    before = sync.context()
    with pytest.raises(LedgerError):
        sync.upsert_categories(categories,1)
    assert sync.context() == before
