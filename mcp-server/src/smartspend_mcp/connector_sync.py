"""Durable three-way reconciliation; missing/empty sources never imply deletion.

State belongs to one canonical ledger and connector scope. A sidecar SQLite outbox
is committed before either remote side effect. UUID idempotency keys survive crashes.
Provider APIs have no conditional row updates: use a dedicated SmartSpend table;
concurrent edits detected between polls are stopped, never last-writer-wins.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import sqlite3
import stat
import time
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

from .connectors import ExternalRecord, ConnectorError
from .validation import json_text


def _private_file(path):
    path = Path(path)
    if not path.parent.is_dir() or path.parent.stat().st_uid != os.getuid() or path.parent.stat().st_mode & 0o022:
        raise ConnectorError("Connector state requires an existing owner-controlled directory")
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ConnectorError("Connector state requires an owner-owned 0600 regular file")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


@contextmanager
def _db(path):
    descriptor = _private_file(path)
    os.close(descriptor)
    conn = sqlite3.connect(path)
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS connectors (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        conn.commit()
        yield conn
    finally:
        conn.close()


@contextmanager
def _lock(state_path):
    descriptor = _private_file(str(state_path) + ".lock")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def status(state_path, connector_id):
    with _db(state_path) as conn:
        row = conn.execute("SELECT data FROM connectors WHERE id=?", (connector_id,)).fetchone()
        return json.loads(row[0]) if row else {"baseline": {}, "pending": {}, "conflicts": {}, "deletionProposals": []}


def _save(conn, connector_id, state):
    conn.execute("INSERT OR REPLACE INTO connectors VALUES (?,?)", (connector_id, json_text(state)))
    conn.commit()


def _local(store):
    snapshot = store.state_snapshot()
    return snapshot, {r["expense"]["id"]: r for r in snapshot["records"]}


def _value(record):
    return None if record is None else {"expense": record["expense"], "archived": record["archived"]}


def _detail(here, there, base):
    result = {"canonical": here, "provider": there, "baseline": base}
    return {**result, "digest": hashlib.sha256(json_text(result).encode()).hexdigest()}


def _scope(ledger, currency, adapter):
    return {"ledgerId": ledger, "currency": currency, "provider": type(adapter).__name__,
            "resource": getattr(adapter, "source", getattr(adapter, "base", "")), "tab": getattr(adapter, "tab", "")}


def resolve_conflict(store, adapter, connector_id, expense_id, prefer, expected_digest, state_path=None):
    """Approve one reviewed conflict, bound to exact current content on both sides.

    This only rebases the next reconcile; it never directly mutates expense data.
    Deletion proposals require reconcile's separate deletion confirmation digest.
    """
    if prefer not in ("canonical", "provider"):
        raise ConnectorError("Prefer must be canonical or provider")
    state_path = Path(state_path or str(store.path) + ".connectors.sqlite3")
    with _lock(state_path):
        with _db(state_path) as conn:
            state = status(state_path, connector_id)
            context = store.context()
            if state.get("scope") != _scope(context["ledgerId"], context["currency"], adapter):
                raise ConnectorError("Connector identity changed; use the original connector scope")
            if expense_id not in state["conflicts"] or state["conflicts"][expense_id] == "deletion_confirmation_required":
                raise ConnectorError("No editable conflict; deletion requires separate confirmation")
            if hasattr(adapter, "known_pages"):
                adapter.known_pages = state.get("providerPageIds", {})
                adapter.known_records = state["baseline"]
            _, local = _local(store)
            remote = adapter.fetch()
            here = _value(local.get(expense_id))
            there = remote[expense_id].data() if expense_id in remote else None
            detail = _detail(here, there, state["baseline"].get(expense_id))
            if detail["digest"] != expected_digest or there is None or here is None:
                raise ConnectorError("Conflict changed; inspect and confirm its new digest")
            if here["archived"] != there["archived"]:
                raise ConnectorError("Archive/restore differences need explicit deletion/restore review")
            state["baseline"][expense_id] = here if prefer == "provider" else there
            state["pending"].pop(expense_id, None)
            state["conflicts"].pop(expense_id, None)
            state.get("conflictDetails", {}).pop(expense_id, None)
            _save(conn, connector_id, state)
            return {"expenseId": expense_id, "prefer": prefer, "pendingReconcile": True}


def reconcile(store, adapter, connector_id, state_path=None, confirmation_digest=None):
    """Run one complete poll. Returns durable status, no OAuth or automatic bootstrap.

    confirmation_digest approves exactly the current proposed UUID/revision/record
    set, not future deletions. Single explicit Deleted checkbox is accepted; multiple
    explicit deletions and missing known rows require this scoped confirmation.
    """
    state_path = Path(state_path or str(store.path) + ".connectors.sqlite3")
    with _lock(state_path):
        with _db(state_path) as conn:
            state = status(state_path, connector_id)
            state.setdefault("clientId", str(uuid4()))
            state.setdefault("retryAt", 0)
            if state["retryAt"] > time.time():
                return state
            try:
                snapshot, local = _local(store)
                context = store.context()
                ledger = snapshot.get("ledgerId", context.get("ledgerId"))
                currency = snapshot.get("currency", context.get("currency"))
                scope = _scope(ledger, currency, adapter)
                if currency != adapter.currency or not ledger:
                    raise ConnectorError("Connector currency differs from initialized ledger")
                if state.get("scope", scope) != scope:
                    raise ConnectorError("Connector identity changed; use a new connector ID")
                state["scope"] = scope
                if hasattr(adapter, "known_pages"):
                    adapter.known_pages = state.get("providerPageIds", {})
                    adapter.known_records = state["baseline"]
                remote = {key: r.data() for key, r in adapter.fetch().items()}
                if hasattr(adapter, "pages"):
                    state["providerPageIds"] = {**state.get("providerPageIds", {}), **adapter.pages}
                # No state mutation before the full successful provider scan above.
                state["conflicts"] = {}
                proposals = []
                for key, base in state["baseline"].items():
                    current = local.get(key)
                    if current and not current["archived"] and (key not in remote or remote[key]["archived"]):
                        proposals.append({"expenseId": key, "revision": current["revision"],
                                          "missing": key not in remote, "expense": current["expense"]})
                digest = hashlib.sha256(json_text(proposals).encode()).hexdigest() if proposals else None
                state["deletionProposals"], state["deletionDigest"] = proposals, digest
                approved = bool(digest and confirmation_digest == digest)
                guarded = {p["expenseId"] for p in proposals if p["missing"] or len(proposals) > 1}
                if not approved:
                    for key in guarded:
                        state["conflicts"][key] = "deletion_confirmation_required"
                else:
                    for p in proposals:
                        if p["missing"]:
                            remote[p["expenseId"]] = {"expense": p["expense"], "archived": True}
                # Keep old outbox entries until acknowledged/observed, even on restart.
                _save(conn, connector_id, state)
                for key in sorted(set(local) | set(remote) | set(state["pending"])):
                    if key in guarded and not approved:
                        continue
                    snapshot, local = _local(store)
                    here = _value(local.get(key))
                    there = remote.get(key)
                    base = state["baseline"].get(key)
                    pending = state["pending"].get(key)
                    if pending is None:
                        if there is None:
                            # Previously synced missing rows are deletion proposals,
                            # not a reason to resurrect automatically or erase locally.
                            if base is not None:
                                continue
                            direction, target = "export", here
                        elif here == there:
                            state["baseline"][key] = here
                            continue
                        elif base is None and here is not None:
                            state["conflicts"][key] = "initial_values_differ"
                            continue
                        elif here == base or here is None:
                            direction, target = "import", there
                        elif there == base:
                            direction, target = "export", here
                        else:
                            state["conflicts"][key] = "concurrent_edits"
                            continue
                        if target is None:
                            continue
                        pending = {"direction": direction, "target": target, "expected": there,
                                   "operationId": str(uuid4()), "baseRevision": local.get(key, {}).get("revision", 0)}
                        state["pending"][key] = pending
                        _save(conn, connector_id, state)
                    target = pending["target"]
                    if pending["direction"] == "export":
                        if there != target:
                            if there != pending["expected"]:
                                state["conflicts"][key] = "provider_changed_during_retry"
                                continue
                            adapter.put(ExternalRecord(**target), expected=there)
                            if hasattr(adapter, "pages"):
                                state["providerPageIds"] = {**state.get("providerPageIds", {}), **adapter.pages}
                    else:
                        # Retry exact persisted operation; canonical store handles
                        # acknowledgement replay and stale revision without overwrites.
                        prior = local.get(key)
                        if prior and prior["archived"] != target["archived"] and prior["expense"] != target["expense"]:
                            state["conflicts"][key] = "archive_or_restore_with_edits_requires_review"
                            continue
                        kind = ("create" if pending["baseRevision"] == 0 else
                                "archive" if target["archived"] else
                                "restore" if prior and prior["archived"] else "update")
                        if "operation" not in pending:
                            pending["operation"] = {"id": pending["operationId"], "kind": kind,
                                "expenseId": key, "baseRevision": pending["baseRevision"],
                                "expense": target["expense"] if kind in ("create", "update") else None}
                            _save(conn, connector_id, state)
                        if kind == "create" and target["archived"]:
                            state["conflicts"][key] = "new_deleted_record_ignored"
                            continue
                        result = store.exchange({"schemaVersion": 1, "ledgerId": ledger, "currency": currency,
                            "clientId": state["clientId"], "afterSequence": 0, "operations": [pending["operation"]]},
                            source="notion" if type(adapter).__name__ == "NotionAdapter" else "google_sheets")
                        if pending["operationId"] not in result.get("acknowledgedOperationIds", []):
                            state["conflicts"][key] = "canonical_revision_conflict"
                            continue
                    state["baseline"][key] = target
                    del state["pending"][key]
                    _save(conn, connector_id, state)
                state["lastSuccessAt"], state["retryAt"] = time.time(), 0
                state.pop("error", None)
                state["conflictDetails"] = {key: _detail(_value(local.get(key)), remote.get(key), state["baseline"].get(key))
                                            for key in state["conflicts"]}
            except (ConnectorError, ValueError) as exc:
                # Errors from validation are bounded; never persist raw HTTP bodies.
                state["error"] = "Connector unavailable or data invalid; no missing-record deletes applied"
                state["retryAt"] = time.time() + min(3600, max(1, getattr(exc, "retry_after", 30)))
            _save(conn, connector_id, state)
            return state
