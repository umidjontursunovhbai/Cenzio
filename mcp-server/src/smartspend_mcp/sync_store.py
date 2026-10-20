"""Canonical incremental ledger; explicit mutations, CAS and immutable history.

Authentication selects the database outside this module. A client can never select
a ledger by supplying a filesystem path or overwrite state with a new snapshot.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from .validation import (CURRENCIES, LedgerError, bounded_text, expense_data,
                         fingerprint, json_text, uuid_text, zone_text)


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _integer(value, field, minimum=0, maximum=2**63-1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise LedgerError(f"{field} must be an integer between {minimum} and {maximum}")
    return value


def _source(value):
    if value not in ("app", "mcp", "google_sheets", "notion", "bootstrap", "owner"):
        raise LedgerError("Unsupported mutation source")
    return value


def _categories(values):
    if not isinstance(values, list) or len(values) > 1000:
        raise LedgerError("Expected at most 1000 categories")
    parsed = {}
    for category in values:
        if not isinstance(category, dict):
            raise LedgerError("Category must be an object")
        item = {"id":uuid_text(category.get("id")),
                "name":bounded_text(category.get("name"), "Category name", 100)}
        for field in ("iconSystemName", "colorName"):
            if category.get(field) is not None:
                item[field] = bounded_text(category[field],field,100)
        if item["id"] in parsed:
            raise LedgerError("Duplicate category")
        parsed[item["id"]] = item
    return parsed


class SyncStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser().absolute()
        if self.path.is_symlink():
            raise LedgerError("Ledger path cannot be a symlink")
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Reserve privately before SQLite opens it; never follows a final symlink.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        os.chmod(self.path, 0o600)
        with self.connection(write=True) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS sync_meta (
                  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                  ledgerId TEXT NOT NULL, currency TEXT NOT NULL,
                  timeZone TEXT NOT NULL, revision INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS sync_categories (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sync_records (id TEXT PRIMARY KEY, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sync_history (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  operationId TEXT UNIQUE NOT NULL, kind TEXT NOT NULL,
                  expenseId TEXT NOT NULL, beforeState TEXT, afterState TEXT NOT NULL,
                  source TEXT NOT NULL, createdAt TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS sync_history_expense ON sync_history(expenseId,sequence);
                CREATE TABLE IF NOT EXISTS sync_operations (
                  id TEXT PRIMARY KEY, requestHash TEXT NOT NULL, result TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sync_catalog_history (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT, revision INTEGER NOT NULL,
                  beforeState TEXT NOT NULL, afterState TEXT NOT NULL,
                  source TEXT NOT NULL, createdAt TEXT NOT NULL);
            """)

    @contextmanager
    def connection(self, *, write=False):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA busy_timeout=10000")
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _context(db):
        row = db.execute("SELECT * FROM sync_meta WHERE singleton=1").fetchone()
        if row is None:
            raise LedgerError("Sync ledger is not initialized")
        return {**{k: row[k] for k in ("ledgerId", "currency", "timeZone", "revision")},
                "categories": [json.loads(r[0]) for r in db.execute("SELECT data FROM sync_categories ORDER BY id")]}

    def context(self):
        with self.connection() as db:
            return self._context(db)

    @staticmethod
    def _record(db, expense_id):
        row = db.execute("SELECT data FROM sync_records WHERE id=?", (expense_id,)).fetchone()
        return json.loads(row[0]) if row else None

    @staticmethod
    def _append(db, operation_id, kind, item, archived, before, source):
        revision = before["revision"] + 1 if before else 1
        after = {"expense": item, "archived": archived, "revision": revision,
                 "fingerprint": fingerprint(item), "modifiedAt": _now()}
        db.execute("INSERT INTO sync_records VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                   (item["id"], json_text(after)))
        db.execute("INSERT INTO sync_history(operationId,kind,expenseId,beforeState,afterState,source,createdAt) VALUES(?,?,?,?,?,?,?)",
                   (operation_id, kind, item["id"], json_text(before) if before else None,
                    json_text(after), source, after["modifiedAt"]))
        db.execute("UPDATE sync_meta SET revision=revision+1 WHERE singleton=1")
        return after

    def bootstrap(self, snapshot: dict):
        if not isinstance(snapshot, dict) or type(snapshot.get("schemaVersion")) is not int or snapshot["schemaVersion"] != 1:
            raise LedgerError("Expected snapshot schemaVersion 1")
        ledger_id = uuid_text(snapshot.get("ledgerId"))
        currency = snapshot.get("currency")
        if not isinstance(currency, str) or currency not in CURRENCIES:
            raise LedgerError("Unsupported currency")
        time_zone = zone_text(snapshot.get("timeZone", "UTC"))
        parsed = _categories(snapshot.get("categories"))
        records = {}
        for field, archived in (("expenses", False), ("archivedExpenses", True)):
            values = snapshot.get(field, [] if archived else None)
            if not isinstance(values, list) or len(values) > 100_000:
                raise LedgerError("Expected bounded expense array")
            for raw in values:
                item = expense_data(raw)
                if item["categoryId"] not in parsed:
                    raise LedgerError("Unknown category")
                if item["id"] in records:
                    raise LedgerError("Duplicate expense")
                records[item["id"]] = (item, archived)
        with self.connection(write=True) as db:
            if db.execute("SELECT 1 FROM sync_meta").fetchone():
                raise LedgerError("Already initialized; snapshot replacement is forbidden")
            db.execute("INSERT INTO sync_meta VALUES(1,?,?,?,0)", (ledger_id, currency, time_zone))
            db.executemany("INSERT INTO sync_categories VALUES(?,?)", [(k,json_text(v)) for k,v in parsed.items()])
            for item, archived in records.values():
                self._append(db, str(uuid4()), "create", item, archived, None, "bootstrap")
            return self._context(db)

    def upsert_categories(self, categories, expected_revision, source="app"):
        """CAS catalog update. Missing IDs are never interpreted as deletion."""
        parsed = _categories(categories)
        expected_revision = _integer(expected_revision, "expected_revision")
        source = _source(source)
        with self.connection(write=True) as db:
            before = self._context(db)
            if before["revision"] != expected_revision:
                raise LedgerError("Category revision conflict; fetch current context before retrying")
            merged = {c["id"]:c for c in before["categories"]}
            merged.update(parsed)
            if len(merged) > 1000:
                raise LedgerError("Catalog cannot exceed 1000 categories")
            after_categories = sorted(merged.values(),key=lambda c:c["id"])
            if after_categories == before["categories"]:
                return before
            db.executemany("INSERT INTO sync_categories VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                           [(k,json_text(v)) for k,v in parsed.items()])
            db.execute("UPDATE sync_meta SET revision=revision+1 WHERE singleton=1")
            after = self._context(db)
            db.execute("INSERT INTO sync_catalog_history(revision,beforeState,afterState,source,createdAt) VALUES(?,?,?,?,?)",
                       (after["revision"],json_text(before["categories"]),json_text(after_categories),source,_now()))
            return after

    def _operation(self, db, raw, source):
        if not isinstance(raw, dict):
            raise LedgerError("Operation must be an object")
        op_id, expense_id = uuid_text(raw.get("id")), uuid_text(raw.get("expenseId"))
        kind = raw.get("kind")
        if kind not in ("create", "update", "archive", "restore", "restore_version"):
            raise LedgerError("Unknown operation kind")
        base = _integer(raw.get("baseRevision"), "baseRevision")
        item = expense_data(raw.get("expense")) if kind in ("create", "update", "restore_version") else None
        if item and item["id"] != expense_id:
            raise LedgerError("Expense UUID mismatch")
        if kind in ("archive", "restore") and raw.get("expense") is not None:
            raise LedgerError("Archive/restore cannot carry expense data")
        canonical = {"id": op_id,"expenseId":expense_id,"kind":kind,"baseRevision":base,"expense":item,"source":source}
        if kind == "restore_version":
            canonical["historySequence"] = raw["historySequence"]
            canonical["archived"] = raw["archived"]
        digest = hashlib.sha256(json_text(canonical).encode()).hexdigest()
        prior = db.execute("SELECT * FROM sync_operations WHERE id=?", (op_id,)).fetchone()
        if prior:
            if prior["requestHash"] != digest:
                raise LedgerError("Operation ID reused with different arguments")
            return json.loads(prior["result"])
        current = self._record(db, expense_id)
        reason = None
        if kind == "create":
            if base != 0 or current is not None:
                reason = "already_exists" if current else "revision_conflict"
        elif current is None:
            reason = "not_found"
        elif current["revision"] != base:
            reason = "revision_conflict"
        elif kind == "update" and current["archived"]:
            reason = "archived"
        elif kind == "archive" and current["archived"]:
            reason = "already_archived"
        elif kind == "restore" and not current["archived"]:
            reason = "not_archived"
        if item and not db.execute("SELECT 1 FROM sync_categories WHERE id=?", (item["categoryId"],)).fetchone():
            reason = "unknown_category"
        if reason:
            result = {"operationId":op_id,"expenseId":expense_id,"reason":reason,"current":current}
        else:
            archived = kind == "archive" or (kind == "restore_version" and raw["archived"])
            after = self._append(db, op_id, kind, item or current["expense"], archived, current, source)
            result = {"operationId":op_id,"acknowledged":True,"current":after}
        db.execute("INSERT INTO sync_operations VALUES(?,?,?)", (op_id,digest,json_text(result)))
        return result

    def exchange(self, request: dict, source="app"):
        source = _source(source)
        if not isinstance(request, dict) or type(request.get("schemaVersion")) is not int or request["schemaVersion"] != 1:
            raise LedgerError("Expected sync schemaVersion 1")
        uuid_text(request.get("clientId"))
        ledger_id = uuid_text(request.get("ledgerId"))
        cursor = _integer(request.get("afterSequence"), "afterSequence")
        operations = request.get("operations")
        if not isinstance(operations, list) or len(operations) > 100:
            raise LedgerError("Expected at most 100 operations")
        if any(isinstance(op,dict) and op.get("kind") == "restore_version" for op in operations):
            raise LedgerError("Use restore_version to restore history")
        with self.connection(write=True) as db:
            ctx = self._context(db)
            if ledger_id != ctx["ledgerId"] or request.get("currency") != ctx["currency"]:
                raise LedgerError("Ledger/currency mismatch")
            maximum = db.execute("SELECT COALESCE(MAX(sequence),0) FROM sync_history").fetchone()[0]
            if cursor > maximum:
                raise LedgerError("Cursor is ahead of this ledger")
            results = [self._operation(db, op, source) for op in operations]
            rows = db.execute("SELECT * FROM sync_history WHERE sequence>? ORDER BY sequence LIMIT 201", (cursor,)).fetchall()
            page = rows[:200]
            return {"schemaVersion":1,"ledgerId":ctx["ledgerId"],"currency":ctx["currency"],
                    "changes":[self._change(r) for r in page],
                    "nextSequence":page[-1]["sequence"] if page else cursor,"hasMore":len(rows)>200,
                    "conflicts":[r for r in results if "reason" in r],
                    "acknowledgedOperationIds":[r["operationId"] for r in results if r.get("acknowledged")]}

    @staticmethod
    def _change(row):
        after = json.loads(row["afterState"])
        return {"sequence":row["sequence"],"operationId":row["operationId"],"kind":row["kind"],
                "expenseId":row["expenseId"],"expense":after["expense"],"archived":after["archived"],
                "revision":after["revision"],"source":row["source"]}

    def history(self, expense_id, after_sequence=0, limit=50):
        expense_id = uuid_text(expense_id)
        after_sequence = _integer(after_sequence,"after_sequence")
        limit = _integer(limit,"limit",1,200)
        with self.connection() as db:
            self._context(db)
            rows = db.execute("SELECT * FROM sync_history WHERE expenseId=? AND sequence>? ORDER BY sequence LIMIT ?", (expense_id,after_sequence,limit+1)).fetchall()
            page = rows[:limit]
            items = [{"sequence":r["sequence"],"operationId":r["operationId"],"kind":r["kind"],
                      "expenseId":r["expenseId"],"before":json.loads(r["beforeState"]) if r["beforeState"] else None,
                      "after":json.loads(r["afterState"]),"source":r["source"],"createdAt":r["createdAt"]} for r in page]
            return {"items":items,"nextSequence":page[-1]["sequence"] if page else after_sequence,"hasMore":len(rows)>limit}

    def restore_version(self, expense_id, history_sequence, expected_revision, operation_id, source="app"):
        expense_id, operation_id = uuid_text(expense_id),uuid_text(operation_id)
        sequence = _integer(history_sequence,"history_sequence",1)
        base = _integer(expected_revision,"expected_revision",1)
        source = _source(source)
        with self.connection(write=True) as db:
            self._context(db)
            row = db.execute("SELECT afterState FROM sync_history WHERE expenseId=? AND sequence=?", (expense_id,sequence)).fetchone()
            if not row:
                raise LedgerError("History version not found")
            target = json.loads(row[0])
            result = self._operation(db,{"id":operation_id,"kind":"restore_version","expenseId":expense_id,
                "baseRevision":base,"expense":target["expense"],"historySequence":sequence,"archived":target["archived"]},source)
            return result

    def state_snapshot(self):
        with self.connection() as db:
            return {**self._context(db),
                    "nextSequence":db.execute("SELECT COALESCE(MAX(sequence),0) FROM sync_history").fetchone()[0],
                    "records":[json.loads(r[0]) for r in db.execute("SELECT data FROM sync_records ORDER BY id")]}

    def backup(self, path):
        destination = Path(path).expanduser().absolute()
        if destination == self.path:
            raise LedgerError("Backup must be a separate new file")
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        try:
            with self.connection() as source:
                ctx = self._context(source)
                target = sqlite3.connect(destination)
                try:
                    source.backup(target)
                finally:
                    target.close()
            self.validate_backup(destination)
            return {"path":str(destination),"ledgerId":ctx["ledgerId"],"revision":ctx["revision"]}
        except BaseException:
            destination.unlink(missing_ok=True)
            raise

    @staticmethod
    def validate_backup(path):
        path = Path(path).expanduser().absolute()
        if path.is_symlink() or not path.is_file():
            raise LedgerError("Expected a regular backup file")
        try:
            db = sqlite3.connect(path.as_uri()+"?mode=ro",uri=True)
            db.row_factory = sqlite3.Row
            try:
                if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise LedgerError("Backup integrity check failed")
                # A valid SQLite file alone is not necessarily a complete sync backup.
                for table in ("sync_records", "sync_history", "sync_operations", "sync_catalog_history"):
                    db.execute(f"SELECT * FROM {table} LIMIT 0")
                context = SyncStore._context(db)
                uuid_text(context["ledgerId"])
                zone_text(context["timeZone"])
                if context["currency"] not in CURRENCIES:
                    raise LedgerError("Backup has unsupported currency")
                for row in db.execute("SELECT id,data FROM sync_records"):
                    envelope = json.loads(row["data"])
                    expense = expense_data(envelope["expense"])
                    if expense["id"] != row["id"] or envelope["fingerprint"] != fingerprint(expense):
                        raise LedgerError("Backup record integrity check failed")
                    _integer(envelope["revision"], "revision", 1)
                    if type(envelope["archived"]) is not bool:
                        raise LedgerError("Invalid backup tombstone")
                return context
            finally:
                db.close()
        except sqlite3.Error as exc:
            raise LedgerError("Invalid sync backup") from exc
        except (KeyError, TypeError, json.JSONDecodeError) as exc:
            raise LedgerError("Invalid sync backup data") from exc
