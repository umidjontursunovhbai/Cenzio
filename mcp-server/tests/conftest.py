from __future__ import annotations

from copy import deepcopy
from uuid import uuid4

import pytest

from smartspend_mcp.store import LedgerStore

LEDGER = "11111111-1111-4111-8111-111111111111"
CATEGORY = "22222222-2222-4222-8222-222222222222"
EXPENSE = "33333333-3333-4333-8333-333333333333"


def key() -> str:
    return str(uuid4())


def item(**changes):
    return {"id": EXPENSE, "title": "Lunch", "amount": "15800", "categoryId": CATEGORY, "date": "2026-10-20T07:30:00.000Z", **changes}


def snapshot(**changes):
    return deepcopy({"schemaVersion": 1, "ledgerId": LEDGER, "currency": "UZS", "timeZone": "Asia/Tashkent", "categories": [{"id": CATEGORY, "name": "Food", "iconSystemName": "fork.knife", "colorName": "orange"}], "expenses": [item()], **changes})


@pytest.fixture
def store(tmp_path):
    ledger = LedgerStore(tmp_path / "private" / "ledger.sqlite3")
    ledger.import_snapshot(snapshot())
    return ledger
