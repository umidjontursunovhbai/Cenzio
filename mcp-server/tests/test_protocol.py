from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from conftest import CATEGORY, EXPENSE, item, key


def test_actual_stdio_initialize_list_read_write_and_errors(store):
    async def exercise():
        params = StdioServerParameters(command=sys.executable, args=["-m", "smartspend_mcp.cli", "--db", str(store.path), "serve", "--allow-writes"])
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as client:
                initialized = await client.initialize()
                assert initialized.serverInfo.name == "SmartSpend"
                tools = (await client.list_tools()).tools
                names = {tool.name for tool in tools}
                assert names == {"get_context", "list_categories", "list_expenses", "get_expense", "get_spending_summary", "get_expense_history", "create_expense", "update_expense", "archive_expense", "restore_expense", "undo_operation"}
                context = (await client.call_tool("get_context")).structuredContent
                assert context["currency"] == "UZS" and context["writesEnabled"] is True
                assert (await client.call_tool("list_categories")).structuredContent["categories"][0]["id"] == CATEGORY
                args = {"title": "Метро", "amount": "2000.00", "currency": "UZS", "category_id": CATEGORY, "date": "2026-10-20T12:00:00+05:00", "idempotency_key": key()}
                created = await client.call_tool("create_expense", args)
                assert not created.isError
                assert created.structuredContent["expense"]["amount"] == "2000"
                repeated = await client.call_tool("create_expense", args)
                assert repeated.structuredContent["operationId"] == created.structuredContent["operationId"]
                assert repeated.structuredContent["idempotentReplay"] is True
                identifier = created.structuredContent["expense"]["id"]
                fetched = (await client.call_tool("get_expense", {"expense_id": identifier})).structuredContent
                assert fetched["expense"]["title"] == "Метро"
                listed = (await client.call_tool("list_expenses", {"query": "метро", "limit": 1})).structuredContent
                assert listed["expenses"][0]["id"] == identifier
                summary = (await client.call_tool("get_spending_summary", {"start": "2026-10-20T00:00:00+05:00", "end": "2026-10-21T00:00:00+05:00"})).structuredContent
                assert summary["total"] == "17800"
                changed = await client.call_tool("update_expense", {"expense_id": identifier, "expected_revision": 1, "title": "Метро домой", "amount": "3000", "currency": "UZS", "category_id": CATEGORY, "date": args["date"], "idempotency_key": key()})
                assert not changed.isError
                assert changed.structuredContent["expense"]["revision"] == 2
                undone = await client.call_tool("undo_operation", {"operation_id": changed.structuredContent["operationId"], "expected_revision": 2, "idempotency_key": key()})
                assert not undone.isError
                assert undone.structuredContent["expense"]["amount"] == "2000"
                archived = await client.call_tool("archive_expense", {"expense_id": identifier, "expected_revision": 3, "idempotency_key": key()})
                assert not archived.isError
                assert archived.structuredContent["expense"]["archived"] is True
                restored = await client.call_tool("restore_expense", {"expense_id": identifier, "expected_revision": 4, "idempotency_key": key()})
                assert not restored.isError
                assert restored.structuredContent["expense"]["archived"] is False
                history = (await client.call_tool("get_expense_history", {"expense_id": identifier, "limit": 2})).structuredContent
                assert len(history["history"]) == 2 and history["nextAfterSequence"] is not None
                bad_currency = await client.call_tool("create_expense", {**args, "currency": "USD", "idempotency_key": key()})
                assert bad_currency.isError
                assert "Currency mismatch" in bad_currency.content[0].text
                conflict = await client.call_tool("archive_expense", {"expense_id": EXPENSE, "expected_revision": 999, "idempotency_key": key()})
                assert conflict.isError
                assert "Revision conflict" in conflict.content[0].text
                # Names and schema are actual SDK-generated tools, not hand-made JSON fixtures.
                assert next(tool for tool in tools if tool.name == "list_expenses").annotations.readOnlyHint is True
                assert next(tool for tool in tools if tool.name == "create_expense").annotations.readOnlyHint is False

    anyio.run(exercise)


def test_default_stdio_disables_writes(store):
    async def exercise():
        params = StdioServerParameters(command=sys.executable, args=["-m", "smartspend_mcp.cli", "--db", str(store.path), "serve"])
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as client:
                await client.initialize()
                result = await client.call_tool("archive_expense", {"expense_id": EXPENSE, "expected_revision": 1, "idempotency_key": key()})
                assert result.isError
                assert "Writes are disabled" in result.content[0].text
    anyio.run(exercise)
    assert store.get_expense(EXPENSE)["expense"]["archived"] is False


def test_cli_export_exclusive_and_import_explicit(store, tmp_path):
    store.create(item(id=key()), key())
    destination = tmp_path / "review-patch.json"
    args = [sys.executable, "-m", "smartspend_mcp.cli", "--db", str(store.path), "export-operations", str(destination)]
    first = subprocess.run(args, capture_output=True, text=True)
    assert first.returncode == 0
    assert len(json.loads(destination.read_text())["operations"]) == 1
    previous_bytes = destination.read_bytes()
    repeated = subprocess.run(args, capture_output=True, text=True)
    assert repeated.returncode == 1
    assert destination.read_bytes() == previous_bytes
    missing_db = subprocess.run([sys.executable, "-m", "smartspend_mcp.cli", "status"], capture_output=True, text=True, env={"PATH": str(Path(sys.executable).parent)})
    assert missing_db.returncode != 0
