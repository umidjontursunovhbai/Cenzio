"""Wire-format validation shared by the CLI, store and MCP tools."""

from __future__ import annotations

import hashlib
import json
import re
import struct
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# Matches the currencies supported by the iOS Currency enum. No FX conversions.
CURRENCIES = frozenset("USD EUR GBP JPY CNY AUD CAD CHF INR BRL UZS KRW SGD HKD TWD THB MYR IDR PHP VND AED SAR ILS TRY EGP IRR RUB PLN SEK NOK DKK CZK HUF RON BGN ZAR NGN KES ETB GHS MXN ARS CLP COP PEN NZD".split())
MONEY = re.compile(r"(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,6})?\Z")
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})\Z")


class LedgerError(ValueError):
    """A bounded, user-actionable validation or conflict error."""


def uuid_text(value: str) -> str:
    if not isinstance(value, str):
        raise LedgerError("Expected a UUID string")
    try:
        return str(UUID(value))
    except (ValueError, AttributeError) as exc:
        raise LedgerError("Expected a valid UUID") from exc


def amount_text(value: str) -> str:
    if not isinstance(value, str) or not MONEY.fullmatch(value):
        raise LedgerError("Amount must be a positive decimal string; at most 12 whole and 6 fractional digits; no separators/exponents")
    number = Decimal(value)
    if number <= 0 or number >= Decimal("1000000000000"):
        raise LedgerError("Amount must be greater than zero and less than 1 trillion")
    result = format(number, "f").rstrip("0").rstrip(".") if "." in value else value
    if len(result.replace(".", "").lstrip("0")) > 15:
        raise LedgerError("Amount must contain at most 15 significant decimal digits for the iPhone bridge")
    return result


def date_text(value: str) -> str:
    if not isinstance(value, str) or not ISO_DATE.fullmatch(value):
        raise LedgerError("Date must be an ISO8601 timestamp with an explicit timezone and at most millisecond precision")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError as exc:
        raise LedgerError("Invalid calendar date") from exc
    if not 1900 <= result.year <= 2200:
        raise LedgerError("Date must be between years 1900 and 2200")
    return result.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def zone_text(value: str) -> str:
    if not isinstance(value, str) or len(value) > 100:
        raise LedgerError("Expected an IANA timezone")
    try:
        ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise LedgerError("Unknown IANA timezone") from exc
    return value


def bounded_text(value: str, field: str, limit: int) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise LedgerError(f"{field} must be nonblank and at most {limit} characters")
    if "\x00" in value:
        raise LedgerError(f"{field} cannot contain NUL")
    return value


def expense_data(value: dict[str, Any]) -> dict[str, str]:
    if not isinstance(value, dict):
        raise LedgerError("Expense must be an object")
    try:
        return {
            "id": uuid_text(value["id"]),
            "title": bounded_text(value["title"], "Title", 300),
            "amount": amount_text(value["amount"]),
            "categoryId": uuid_text(value["categoryId"]),
            "date": date_text(value["date"]),
        }
    except KeyError as exc:
        raise LedgerError(f"Missing expense field: {exc.args[0]}") from exc


def fingerprint(expense: dict[str, Any]) -> str:
    """SHA256 of five UInt32-BE-length-prefixed UTF-8 canonical fields."""
    item = expense_data(expense)
    payload = b"".join(
        struct.pack(">I", len(encoded)) + encoded
        for key in ("id", "title", "amount", "categoryId", "date")
        for encoded in [item[key].encode("utf-8")]
    )
    return hashlib.sha256(payload).hexdigest()


def json_text(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)
