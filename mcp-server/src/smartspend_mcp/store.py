"""Single-owner transactional ledger. Never opens the iPhone's personal files."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterator
from uuid import uuid4
from zoneinfo import ZoneInfo

from .validation import (
    CURRENCIES, LedgerError, bounded_text, date_text, expense_data,
    fingerprint, json_text, uuid_text, zone_text,
)

MAX_PENDING_OPERATIONS = 1000  # Matches the iOS reviewed patch limit.


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def decimal_total(value: Decimal) -> str:
    result = format(value, "f")
    return result.rstrip("0").rstrip(".") if "." in result else result


class LedgerStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS ledger (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    ledgerId TEXT NOT NULL, currency TEXT NOT NULL,
                    timeZone TEXT NOT NULL, revision INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS categories (
                    id TEXT PRIMARY KEY, data TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS expenses (
                    id TEXT PRIMARY KEY, data TEXT NOT NULL, fingerprint TEXT NOT NULL,
                    date TEXT NOT NULL, categoryId TEXT NOT NULL, title TEXT NOT NULL,
                    revision INTEGER NOT NULL, archived INTEGER NOT NULL,
                    modifiedAt TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS expense_page ON expenses(archived,date,id);
                CREATE TABLE IF NOT EXISTS history (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    operationId TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                    expenseId TEXT NOT NULL, beforeState TEXT, afterState TEXT NOT NULL,
                    createdAt TEXT NOT NULL, pending INTEGER NOT NULL,
                    idempotencyKey TEXT UNIQUE, requestHash TEXT, response TEXT,
                    action TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS expense_history ON history(expenseId,seq);
            """)
        os.chmod(self.path, 0o600)

    @contextmanager
    def connection(self, *, write: bool = False) -> Iterator[sqlite3.Connection]:
        # One connection per request: safe for FastMCP's threaded sync tool calls.
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA busy_timeout=10000")
        try:
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _meta(db: sqlite3.Connection) -> dict[str, Any]:
        row = db.execute("SELECT * FROM ledger WHERE singleton=1").fetchone()
        if row is None:
            raise LedgerError("Ledger is not initialized. Owner must explicitly import an app snapshot using the CLI first.")
        return {key: row[key] for key in ("ledgerId", "currency", "timeZone", "revision")}

    @staticmethod
    def _state(row: sqlite3.Row | None) -> dict[str, Any] | None:
        if row is None:
            return None
        return {"expense": json.loads(row["data"]), "archived": bool(row["archived"])}

    @staticmethod
    def _public(row: sqlite3.Row) -> dict[str, Any]:
        return {
            **json.loads(row["data"]), "revision": row["revision"],
            "fingerprint": row["fingerprint"], "archived": bool(row["archived"]),
            "modifiedAt": row["modifiedAt"],
        }

    @staticmethod
    def _put(db: sqlite3.Connection, item: dict[str, str], archived: bool, revision: int) -> None:
        db.execute("""
            INSERT INTO expenses VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET data=excluded.data,fingerprint=excluded.fingerprint,
                date=excluded.date,categoryId=excluded.categoryId,title=excluded.title,
                revision=excluded.revision,archived=excluded.archived,modifiedAt=excluded.modifiedAt
        """, (item["id"], json_text(item), fingerprint(item), item["date"], item["categoryId"], item["title"], revision, int(archived), now()))

    def import_snapshot(self, document: dict[str, Any], expected_revision: int | None = None) -> dict[str, Any]:
        """Owner-only CLI operation; never an MCP tool. All validation precedes mutation."""
        if not isinstance(document, dict) or type(document.get("schemaVersion")) is not int or document["schemaVersion"] != 1:
            raise LedgerError("Expected snapshot schemaVersion 1")
        ledger_id = uuid_text(document.get("ledgerId"))
        currency = document.get("currency")
        if not isinstance(currency, str) or currency not in CURRENCIES:
            raise LedgerError("Snapshot currency is unsupported")
        time_zone = zone_text(document.get("timeZone", "UTC"))
        raw_categories = document.get("categories")
        if not isinstance(raw_categories, list) or len(raw_categories) > 1000:
            raise LedgerError("Snapshot requires an array of at most 1000 categories")
        categories: dict[str, dict[str, Any]] = {}
        for category in raw_categories:
            if not isinstance(category, dict):
                raise LedgerError("Category must be an object")
            item = {"id": uuid_text(category.get("id")), "name": bounded_text(category.get("name"), "Category name", 100)}
            for optional in ("iconSystemName", "colorName"):
                if category.get(optional) is not None:
                    item[optional] = bounded_text(category[optional], optional, 100)
            if item["id"] in categories:
                raise LedgerError("Duplicate category UUID")
            categories[item["id"]] = item
        records: dict[str, dict[str, Any]] = {}
        for key, archived in (("expenses", False), ("archivedExpenses", True)):
            values = document.get(key, [] if archived else None)
            if not isinstance(values, list) or len(values) > 100_000:
                raise LedgerError(f"{key} must be an array with at most 100000 records")
            for value in values:
                item = expense_data(value)
                if item["categoryId"] not in categories:
                    raise LedgerError("Every expense must reference a category in this ledger")
                if item["id"] in records:
                    raise LedgerError("Duplicate expense UUID, including active/archived overlap")
                records[item["id"]] = {"expense": item, "archived": archived}
        acknowledged = document.get("appliedOperationIds", [])
        if not isinstance(acknowledged, list) or len(acknowledged) > 100_000:
            raise LedgerError("appliedOperationIds must be a bounded array")
        acknowledged = {uuid_text(item) for item in acknowledged}
        with self.connection(write=True) as db:
            existing = db.execute("SELECT * FROM ledger WHERE singleton=1").fetchone()
            if existing:
                meta = self._meta(db)
                if ledger_id != meta["ledgerId"] or currency != meta["currency"]:
                    raise LedgerError("Ledger/currency mismatch. Use a separate database; amounts are never converted or relabeled.")
                if expected_revision != meta["revision"]:
                    raise LedgerError(f"Reimport requires --expected-revision {meta['revision']} after reviewing the current server state")
                pending = {row[0] for row in db.execute("SELECT operationId FROM history WHERE pending=1")}
                if not pending.issubset(acknowledged):
                    raise LedgerError("Unacknowledged MCP operations remain. Review/import the patch in the app and export a new snapshot first.")
                revision = meta["revision"] + 1
                # Missing rows become tombstones, never hard-delete the audit trail.
                for row in db.execute("SELECT * FROM expenses").fetchall():
                    if row["id"] not in records:
                        records[row["id"]] = {"expense": json.loads(row["data"]), "archived": True}
                db.execute("UPDATE ledger SET timeZone=?,revision=? WHERE singleton=1", (time_zone, revision))
                db.execute("UPDATE history SET pending=0 WHERE pending=1")
            else:
                if expected_revision not in (None, 0):
                    raise LedgerError("A new ledger has revision 0")
                revision = 1
                db.execute("INSERT INTO ledger VALUES(1,?,?,?,?)", (ledger_id, currency, time_zone, revision))
            db.execute("DELETE FROM categories")
            for item in categories.values():
                db.execute("INSERT INTO categories VALUES(?,?)", (item["id"], json_text(item)))
            for state in records.values():
                item = state["expense"]
                previous = db.execute("SELECT * FROM expenses WHERE id=?", (item["id"],)).fetchone()
                before = self._state(previous)
                if before == state:
                    continue
                row_revision = previous["revision"] + 1 if previous else 1
                self._put(db, item, state["archived"], row_revision)
                db.execute("""INSERT INTO history(operationId,kind,expenseId,beforeState,afterState,createdAt,pending,action)
                    VALUES(?,?,?,?,?,?,0,'app_snapshot')""",
                    (str(uuid4()), "archive" if state["archived"] else ("update" if previous else "create"), item["id"], json_text(before) if before else None, json_text(state), now()))
            return {**self._meta(db), "importedActive": sum(not item["archived"] for item in records.values()), "importedArchived": sum(item["archived"] for item in records.values())}

    def context(self) -> dict[str, Any]:
        with self.connection() as db:
            return {
                **self._meta(db), "schemaVersion": 1, "mode": "local_manual_exchange",
                "pendingOperationCount": db.execute("SELECT COUNT(*) FROM history WHERE pending=1").fetchone()[0],
                "maximumPendingOperations": MAX_PENDING_OPERATIONS,
                "activeExpenseCount": db.execute("SELECT COUNT(*) FROM expenses WHERE archived=0").fetchone()[0],
                "archivedExpenseCount": db.execute("SELECT COUNT(*) FROM expenses WHERE archived=1").fetchone()[0],
                "moneyFormat": "positive decimal string; one currency per ledger; no FX conversion",
                "dateFormat": "ISO8601 with explicit timezone, UTC milliseconds in responses",
                "appSync": "No live sync. Owner exports operations then reviews/imports them in the app.",
            }

    def categories(self) -> dict[str, Any]:
        with self.connection() as db:
            return {**self._meta(db), "categories": [json.loads(row[0]) for row in db.execute("SELECT data FROM categories ORDER BY id")]}

    def get_expense(self, expense_id: str) -> dict[str, Any]:
        expense_id = uuid_text(expense_id)
        with self.connection() as db:
            meta = self._meta(db)
            row = db.execute("SELECT * FROM expenses WHERE id=?", (expense_id,)).fetchone()
            if row is None:
                raise LedgerError("Expense not found in this ledger")
            return {"ledgerId": meta["ledgerId"], "currency": meta["currency"], "expense": self._public(row)}

    @staticmethod
    def _filters(start: str | None, end: str | None, category_id: str | None, query: str | None, archived: bool) -> tuple[str, list[Any], dict[str, Any]]:
        if type(archived) is not bool:
            raise LedgerError("archived must be a boolean")
        filters = {"start": date_text(start) if start else None, "end": date_text(end) if end else None, "categoryId": uuid_text(category_id) if category_id else None, "query": query, "archived": archived}
        if filters["start"] and filters["end"] and filters["start"] >= filters["end"]:
            raise LedgerError("start must precede exclusive end")
        clauses, args = ["archived=?"], [int(archived)]
        for key, sql in (("start", "date>=?"), ("end", "date<?"), ("categoryId", "categoryId=?")):
            if filters[key]:
                clauses.append(sql)
                args.append(filters[key])
        if query:
            bounded_text(query, "Query", 100)
            # Python lower() handles Cyrillic; SQLite lower() is ASCII-only.
            clauses.append("instr(unicode_lower(title),?)>0")
            args.append(query.lower())
        return " AND ".join(clauses), args, filters

    def list_expenses(self, *, start: str | None = None, end: str | None = None, category_id: str | None = None, query: str | None = None, archived: bool = False, limit: int = 50, cursor: str | None = None) -> dict[str, Any]:
        if type(limit) is not int or not 1 <= limit <= 100:
            raise LedgerError("limit must be 1–100")
        where, args, filters = self._filters(start, end, category_id, query, archived)
        filter_hash = hashlib.sha256(json_text(filters).encode()).hexdigest()
        with self.connection() as db:
            db.create_function("unicode_lower", 1, lambda value: value.lower(), deterministic=True)
            meta = self._meta(db)
            if cursor:
                try:
                    if not isinstance(cursor, str) or len(cursor) > 2048:
                        raise ValueError()
                    decoded = json.loads(base64.urlsafe_b64decode(cursor).decode())
                    if decoded["filter"] != filter_hash or decoded["revision"] != meta["revision"]:
                        raise LedgerError("Cursor filters changed or ledger changed; restart pagination")
                    last_date, last_id = date_text(decoded["date"]), uuid_text(decoded["id"])
                except (ValueError, KeyError, TypeError, UnicodeError) as exc:
                    if isinstance(exc, LedgerError):
                        raise
                    raise LedgerError("Invalid cursor") from exc
                where += " AND (date<? OR (date=? AND id<?))"
                args.extend([last_date, last_date, last_id])
            rows = db.execute(f"SELECT * FROM expenses WHERE {where} ORDER BY date DESC,id DESC LIMIT ?", [*args, limit + 1]).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            next_cursor = None
            if more:
                next_cursor = base64.urlsafe_b64encode(json_text({"filter": filter_hash, "revision": meta["revision"], "date": rows[-1]["date"], "id": rows[-1]["id"]}).encode()).decode()
            return {**meta, "expenses": [self._public(row) for row in rows], "nextCursor": next_cursor}

    def summary(self, start: str, end: str, *, category_id: str | None = None, time_zone: str | None = None) -> dict[str, Any]:
        where, args, _ = self._filters(start, end, category_id, None, False)
        with self.connection() as db:
            meta = self._meta(db)
            zone = zone_text(time_zone or meta["timeZone"])
            totals: dict[str, Decimal] = {}
            days: dict[str, Decimal] = {}
            total, count = Decimal(0), 0
            for row in db.execute(f"SELECT data FROM expenses WHERE {where}", args):
                item = json.loads(row[0])
                amount = Decimal(item["amount"])
                day = datetime.fromisoformat(item["date"].replace("Z", "+00:00")).astimezone(ZoneInfo(zone)).date().isoformat()
                totals[item["categoryId"]] = totals.get(item["categoryId"], Decimal(0)) + amount
                days[day] = days.get(day, Decimal(0)) + amount
                total += amount
                count += 1
            return {**meta, "start": date_text(start), "endExclusive": date_text(end), "groupingTimeZone": zone, "count": count, "total": decimal_total(total), "byCategory": [{"categoryId": key, "total": decimal_total(value)} for key, value in sorted(totals.items())], "byDay": [{"date": key, "total": decimal_total(value)} for key, value in sorted(days.items())[:366]], "byDayTruncated": len(days) > 366}

    def _mutate(self, kind: str, expense_id: str, *, idempotency_key: str, expected_revision: int | None = None, expense: dict[str, Any] | None = None, undo_operation_id: str | None = None) -> dict[str, Any]:
        expense_id = uuid_text(expense_id)
        idempotency_key = uuid_text(idempotency_key)
        if type(expected_revision) not in (int, type(None)) or (expected_revision is not None and expected_revision < 1):
            raise LedgerError("expected_revision must be a positive integer")
        item = expense_data(expense) if expense is not None else None
        if item is not None and item["id"] != expense_id:
            raise LedgerError("Expense UUID cannot be changed")
        request = {"kind": kind, "expenseId": expense_id, "expectedRevision": expected_revision, "expense": item, "undoOperationId": undo_operation_id}
        request_hash = hashlib.sha256(json_text(request).encode()).hexdigest()
        with self.connection(write=True) as db:
            meta = self._meta(db)
            replay = db.execute("SELECT requestHash,response,pending FROM history WHERE idempotencyKey=?", (idempotency_key,)).fetchone()
            if replay:
                if replay["requestHash"] != request_hash:
                    raise LedgerError("Idempotency key was already used with different arguments")
                return {**json.loads(replay["response"]), "idempotentReplay": True, "pendingAppReview": bool(replay["pending"])}
            if db.execute("SELECT COUNT(*) FROM history WHERE pending=1").fetchone()[0] >= MAX_PENDING_OPERATIONS:
                raise LedgerError("Pending operation limit reached; owner must review/import operations before more writes")
            row = db.execute("SELECT * FROM expenses WHERE id=?", (expense_id,)).fetchone()
            before = self._state(row)
            if kind == "create":
                if row is not None:
                    raise LedgerError("Expense UUID already exists, including archived records")
                if item is None:
                    raise LedgerError("Expense data is required")
                archived = False
                revision = 1
            else:
                if row is None:
                    raise LedgerError("Expense not found in this ledger")
                if expected_revision != row["revision"]:
                    raise LedgerError(f"Revision conflict: read the expense again (current revision {row['revision']})")
                if undo_operation_id:
                    original = db.execute("SELECT * FROM history WHERE operationId=? AND expenseId=? AND action!='app_snapshot'", (uuid_text(undo_operation_id), expense_id)).fetchone()
                    if original is None or json.loads(original["afterState"]) != before or json.loads(original["response"])["expense"]["revision"] != row["revision"]:
                        raise LedgerError("Cannot undo: expense has changed since that operation")
                    target = json.loads(original["beforeState"]) if original["beforeState"] else None
                    item = target["expense"] if target else before["expense"]
                    archived = target["archived"] if target else True
                    kind = "archive" if archived else ("restore" if before["archived"] else "update")
                else:
                    if kind == "restore":
                        if not row["archived"]:
                            raise LedgerError("Only an archived expense can be restored")
                        archived = False
                    elif kind in ("update", "archive"):
                        if row["archived"]:
                            raise LedgerError("Expense is archived; restore it before editing")
                        archived = kind == "archive"
                    else:
                        raise LedgerError("Unknown operation")
                    item = item or before["expense"]
                revision = row["revision"] + 1
            # Archived tombstones can outlive a removed category. Restoring/editing requires ownership.
            if not archived and db.execute("SELECT 1 FROM categories WHERE id=?", (item["categoryId"],)).fetchone() is None:
                raise LedgerError("Unknown category UUID for this ledger")
            state = {"expense": item, "archived": archived}
            if state == before:
                raise LedgerError("No change requested")
            operation_id = str(uuid4())
            self._put(db, item, archived, revision)
            db.execute("UPDATE ledger SET revision=revision+1 WHERE singleton=1")
            response = {"ledgerId": meta["ledgerId"], "currency": meta["currency"], "operationId": operation_id, "kind": kind, "expense": self._public(db.execute("SELECT * FROM expenses WHERE id=?", (expense_id,)).fetchone()), "pendingAppReview": True, "idempotentReplay": False}
            db.execute("""INSERT INTO history(operationId,kind,expenseId,beforeState,afterState,createdAt,pending,idempotencyKey,requestHash,response,action)
                VALUES(?,?,?,?,?,?,1,?,?,?,?)""", (operation_id, kind, expense_id, json_text(before) if before else None, json_text(state), now(), idempotency_key, request_hash, json_text(response), f"undo:{undo_operation_id}" if undo_operation_id else "mcp"))
            return response

    def create(self, expense: dict[str, Any], idempotency_key: str) -> dict[str, Any]:
        item = expense_data(expense)
        return self._mutate("create", item["id"], expense=item, idempotency_key=idempotency_key)

    def update(self, expense_id: str, expected_revision: int, expense: dict[str, Any], idempotency_key: str) -> dict[str, Any]:
        return self._mutate("update", expense_id, expected_revision=expected_revision, expense=expense, idempotency_key=idempotency_key)

    def archive(self, expense_id: str, expected_revision: int, idempotency_key: str) -> dict[str, Any]:
        return self._mutate("archive", expense_id, expected_revision=expected_revision, idempotency_key=idempotency_key)

    def restore(self, expense_id: str, expected_revision: int, idempotency_key: str) -> dict[str, Any]:
        return self._mutate("restore", expense_id, expected_revision=expected_revision, idempotency_key=idempotency_key)

    def undo(self, operation_id: str, expected_revision: int, idempotency_key: str) -> dict[str, Any]:
        with self.connection() as db:
            row = db.execute("SELECT expenseId FROM history WHERE operationId=? AND action!='app_snapshot'", (uuid_text(operation_id),)).fetchone()
            if row is None:
                raise LedgerError("MCP operation not found")
        return self._mutate("undo", row[0], expected_revision=expected_revision, idempotency_key=idempotency_key, undo_operation_id=operation_id)

    def history(self, expense_id: str, *, after_sequence: int = 0, limit: int = 50) -> dict[str, Any]:
        if type(after_sequence) is not int or after_sequence < 0 or type(limit) is not int or not 1 <= limit <= 100:
            raise LedgerError("History requires nonnegative after_sequence and limit 1–100")
        with self.connection() as db:
            meta = self._meta(db)
            rows = db.execute("SELECT * FROM history WHERE expenseId=? AND seq>? ORDER BY seq LIMIT ?", (uuid_text(expense_id), after_sequence, limit + 1)).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            return {"ledgerId": meta["ledgerId"], "history": [{"sequence": row["seq"], "operationId": row["operationId"], "kind": row["kind"], "before": json.loads(row["beforeState"]) if row["beforeState"] else None, "after": json.loads(row["afterState"]), "createdAt": row["createdAt"], "pendingAppReview": bool(row["pending"]), "action": row["action"]} for row in rows], "nextAfterSequence": rows[-1]["seq"] if more else None}

    def export_operations(self) -> dict[str, Any]:
        with self.connection() as db:
            meta = self._meta(db)
            result = []
            for row in db.execute("SELECT * FROM history WHERE pending=1 ORDER BY seq"):
                before = json.loads(row["beforeState"]) if row["beforeState"] else None
                after = json.loads(row["afterState"])
                result.append({"id": row["operationId"], "kind": row["kind"], "expenseId": row["expenseId"], "baseFingerprint": fingerprint(before["expense"]) if before else None, "expense": after["expense"]})
            return {"schemaVersion": 1, "ledgerId": meta["ledgerId"], "currency": meta["currency"], "operations": result}
