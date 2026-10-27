"""Read-only mapping preview for an existing, user-selected Notion data source.

This is deliberately NOT a sync adapter. Existing tables have no durable
SmartSpend identity column, deletion contract, or create idempotency marker.
Preview never changes schema, pages, canonical expenses, or connector state.
"""
from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import math
from uuid import UUID, uuid5
from zoneinfo import ZoneInfo

from .connectors import ConnectorError
from .validation import CURRENCIES, LedgerError, expense_data, uuid_text, zone_text


def validate_mapping(mapping, schema, categories, currency, time_zone):
    """Validate against THIS ledger's current categories and selected schema."""
    if currency not in CURRENCIES:
        raise ConnectorError("Unsupported ledger currency")
    zone_text(time_zone)
    if not isinstance(mapping, dict) or set(mapping) - {"title", "amount", "date", "category", "categoryMap"}:
        raise ConnectorError("Invalid Notion field mapping")
    if not isinstance(schema, dict):
        raise ConnectorError("Notion data source schema is unavailable")
    fields = [mapping.get(key) for key in ("title", "amount", "date", "category")]
    if any(not isinstance(name, str) or not name or len(name) > 300 for name in fields) or len(set(fields)) != 4:
        raise ConnectorError("Select four distinct Notion properties")
    expected = {"title": {"title"}, "amount": {"number"}, "date": {"date"}, "category": {"select", "rich_text"}}
    for key, types in expected.items():
        if not isinstance(schema.get(mapping[key]), dict) or schema[mapping[key]].get("type") not in types:
            raise ConnectorError("Selected Notion property has an unsupported type: " + key)
    allowed = {uuid_text(category["id"]) for category in categories}
    category_map = mapping.get("categoryMap", {})
    if not isinstance(category_map, dict) or len(category_map) > 1000:
        raise ConnectorError("Invalid Notion category mapping")
    for label, category_id in category_map.items():
        if not isinstance(label, str) or not label or len(label) > 300 or uuid_text(category_id) not in allowed:
            raise ConnectorError("Map Notion categories only to this ledger's categories")
    return {**mapping, "categoryMap": dict(category_map)}


def schema_summary(properties):
    """Expose property types/options, not credentials, formulas, or row data."""
    if not isinstance(properties, dict):
        raise ConnectorError("Notion data source schema is unavailable")
    result = {}
    for name, prop in properties.items():
        if not isinstance(name, str) or not isinstance(prop, dict) or not isinstance(prop.get("type"), str):
            raise ConnectorError("Invalid Notion data source schema")
        result[name] = {"type": prop["type"]}
        if prop["type"] == "select":
            options = prop.get("select", {}).get("options", [])
            if not isinstance(options, list):
                raise ConnectorError("Invalid Notion category schema")
            result[name]["options"] = [option["name"] for option in options if isinstance(option, dict) and isinstance(option.get("name"), str)]
    return result


def _text(parts):
    if not isinstance(parts, list):
        raise ConnectorError("Invalid Notion text property")
    result = []
    for part in parts:
        if not isinstance(part, dict):
            raise ConnectorError("Invalid Notion text property")
        value = part.get("plain_text", part.get("text", {}).get("content", ""))
        if not isinstance(value, str):
            raise ConnectorError("Invalid Notion text property")
        result.append(value)
    return "".join(result)


def mapped_record(page, ledger_id, mapping, schema, time_zone):
    """Stable read identity; never confused with create idempotency support."""
    page_id = uuid_text(page.get("id"))
    props = page.get("properties")
    if not isinstance(props, dict):
        raise ConnectorError("Invalid Notion page properties")
    try:
        title = _text(props[mapping["title"]].get("title"))
        amount = props[mapping["amount"]].get("number")
        if type(amount) not in (int, float) or not math.isfinite(amount):
            raise ValueError()
        amount = format(Decimal(str(amount)), "f")
        date = props[mapping["date"]].get("date")
        if not isinstance(date, dict) or not isinstance(date.get("start"), str):
            raise ValueError()
        parsed = datetime.fromisoformat(date["start"].replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=ZoneInfo(time_zone))
        canonical_date = parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        category_prop = props[mapping["category"]]
        if schema[mapping["category"]]["type"] == "select":
            selected = category_prop.get("select")
            label = selected.get("name", "") if isinstance(selected, dict) else ""
        else:
            label = _text(category_prop.get("rich_text"))
        if label not in mapping["categoryMap"]:
            return None, label
        record = expense_data({"id": str(uuid5(UUID(ledger_id), "notion-page:" + page_id)),
            "title": title, "amount": amount, "categoryId": mapping["categoryMap"][label], "date": canonical_date})
        return record, None
    except (KeyError, TypeError, ValueError, InvalidOperation, LedgerError):
        raise ConnectorError("A Notion row has missing or unsupported mapped values") from None


def preview_source(request, ledger_id, source_id, mapping, categories, currency, time_zone, *, sample_limit=5):
    """All-or-nothing bounded read. request is an authenticated fixed-origin API callable."""
    ledger_id, source_id = uuid_text(ledger_id), uuid_text(source_id)
    schema = schema_summary(request("GET", "data_sources/" + source_id).get("properties"))
    mapping = validate_mapping(mapping, schema, categories, currency, time_zone)
    samples, unmapped, seen_pages, seen_cursors = [], set(), set(), set()
    rows, valid, archived, cursor = 0, 0, 0, None
    for _ in range(100):
        body = {"page_size": 100}
        if cursor:
            body["start_cursor"] = cursor
        result = request("POST", "data_sources/" + source_id + "/query", json=body)
        if not isinstance(result.get("results"), list) or result.get("request_status", {}).get("type") == "incomplete":
            raise ConnectorError("Incomplete Notion query; no partial preview")
        for page in result["results"]:
            if not isinstance(page, dict):
                raise ConnectorError("Invalid Notion query row")
            page_id = uuid_text(page.get("id"))
            if page_id in seen_pages:
                raise ConnectorError("Repeated Notion page; no partial preview")
            seen_pages.add(page_id)
            if page.get("in_trash") or page.get("archived"):
                archived += 1
                continue
            rows += 1
            record, missing = mapped_record(page, ledger_id, mapping, schema, time_zone)
            if record is None:
                unmapped.add(missing)
            else:
                valid += 1
                if len(samples) < sample_limit:
                    samples.append(record)
        if not result.get("has_more"):
            return {"readOnly": True, "dataSourceId": source_id, "currency": currency, "timeZone": time_zone,
                "totalRows": rows, "validRows": valid, "excludedArchivedRows": archived,
                "unmappedCategories": sorted(unmapped), "samples": samples, "hasMore": False,
                "canSync": False}
        cursor = result.get("next_cursor")
        if not isinstance(cursor, str) or not cursor or cursor in seen_cursors:
            raise ConnectorError("Incomplete Notion pagination; no partial preview")
        seen_cursors.add(cursor)
    raise ConnectorError("Notion preview is too large; no partial preview")
