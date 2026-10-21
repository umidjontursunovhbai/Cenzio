import copy
import json
from uuid import UUID, uuid5

import httpx
import pytest

from smartspend_mcp.connectors import ConnectorError
from smartspend_mcp.mapped_notion import preview_source, schema_summary, validate_mapping
from smartspend_mcp.notion_oauth import NotionOAuth

LEDGER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
SOURCE = "33333333-3333-4333-8333-333333333333"
PAGE = "44444444-4444-4444-8444-444444444444"
CATEGORY = "55555555-5555-4555-8555-555555555555"
SCHEMA = {"Expense": {"type": "title"}, "Amount": {"type": "number"},
    "Category": {"type": "select", "select": {"options": [{"name": "Groceries"}, {"name": "Taxi"}]}},
    "Date": {"type": "date"}, "Notes": {"type": "rich_text"}}
MAPPING = {"title": "Expense", "amount": "Amount", "date": "Date", "category": "Category", "categoryMap": {"Groceries": CATEGORY}}
CATEGORIES = [{"id": CATEGORY, "name": "Ovqat"}]


def page(id=PAGE, label="Groceries", date="2026-10-21"):
    return {"id": id, "properties": {"Expense": {"title": [{"plain_text": "2kg potato"}]},
        "Amount": {"number": 6000}, "Category": {"select": {"name": label}},
        "Date": {"date": {"start": date}}, "Notes": {"rich_text": [{"plain_text": "Keep private extra notes intact"}]}}}


def preview(pages=None, mapping=None, schema=None, ledger=LEDGER):
    calls = []
    rows = [page()] if pages is None else pages
    def request(method, path, **kwargs):
        calls.append((method, path, kwargs))
        if method == "GET":
            return {"properties": schema or SCHEMA}
        assert method == "POST" and path.endswith("/query")
        return {"results": rows, "has_more": False}
    result = preview_source(request, ledger, SOURCE, mapping or MAPPING, CATEGORIES, "UZS", "Asia/Tashkent")
    return result, calls


def test_existing_table_preview_dynamic_labels_and_dates_no_mutations():
    original = page()
    result, calls = preview([original])
    assert result["totalRows"] == result["validRows"] == 1
    assert result["canSync"] is False and result["readOnly"] is True
    assert result["unmappedCategories"] == []
    assert result["samples"] == [{"id": str(uuid5(UUID(LEDGER), "notion-page:"+PAGE)),
        "title": "2kg potato", "amount": "6000", "categoryId": CATEGORY, "date": "2026-10-20T19:00:00.000Z"}]
    assert original == page()  # No record/property mutation, including extra fields.
    assert "Notes" not in str(result)
    assert [c[0] for c in calls] == ["GET", "POST"]
    assert all(c[1] in ("data_sources/"+SOURCE, "data_sources/"+SOURCE+"/query") for c in calls)


def test_identity_stable_and_isolated_by_ledger():
    a, _ = preview()
    b, _ = preview()
    c, _ = preview(ledger=OTHER)
    assert a["samples"][0]["id"] == b["samples"][0]["id"]
    assert a["samples"][0]["id"] != c["samples"][0]["id"]


def test_unsupported_labels_reported_without_guessing():
    result, _ = preview([page(label="Taxi")])
    assert result["validRows"] == 0 and result["samples"] == []
    assert result["unmappedCategories"] == ["Taxi"]


def test_user_language_and_property_names_not_hardcoded():
    p = page()
    schema, mapping = {}, copy.deepcopy(MAPPING)
    names = {"Expense": "Харажат", "Amount": "Сумма", "Date": "Кун", "Category": "Тури"}
    for old, new in names.items():
        p["properties"][new] = p["properties"].pop(old)
        schema[new] = copy.deepcopy(SCHEMA[old])
    for key in ("title", "amount", "date", "category"):
        mapping[key] = names[mapping[key]]
    mapping["categoryMap"] = {"Озиқ-овқат": CATEGORY}
    p["properties"]["Тури"] = {"select": {"name": "Озиқ-овқат"}}
    result, _ = preview([p], mapping, schema)
    assert result["validRows"] == 1


def test_richtext_category_and_explicit_timestamp():
    p, schema = page(date="2026-10-21T08:40:00+05:00"), copy.deepcopy(SCHEMA)
    schema["Category"] = {"type": "rich_text"}
    p["properties"]["Category"] = {"rich_text": [{"plain_text": "Groceries"}]}
    result, _ = preview([p], schema=schema)
    assert result["samples"][0]["date"] == "2026-10-21T03:40:00.000Z"


@pytest.mark.parametrize("field,value", [("amount", "Date"), ("title", "Notes"), ("date", "Amount"), ("category", "Missing")])
def test_mismatched_schema_rejected_before_row_reads(field, value):
    mapping = {**MAPPING, field: value}
    with pytest.raises(ConnectorError):
        preview(mapping=mapping)


def test_categories_bound_to_user():
    mapping = {**MAPPING, "categoryMap": {"Groceries": OTHER}}
    with pytest.raises(ConnectorError, match="this ledger"):
        preview(mapping=mapping)


def test_trashed_rows_excluded_not_deletion_proposals():
    p = {**page(), "in_trash": True}
    result, _ = preview([p])
    assert result["totalRows"] == 0 and result["excludedArchivedRows"] == 1
    assert result["samples"] == []


def test_duplicate_page_and_bad_amount_no_partial_preview():
    with pytest.raises(ConnectorError, match="Repeated"):
        preview([page(), page()])
    p = page()
    p["properties"]["Amount"]["number"] = -1
    with pytest.raises(ConnectorError, match="unsupported"):
        preview([p])


def test_full_pagination_and_capped_samples():
    count = 0
    def request(method, path, **kwargs):
        nonlocal count
        if method == "GET":
            return {"properties": SCHEMA}
        count += 1
        rows = [page(str(uuid5(UUID(LEDGER), str(count)+str(i)))) for i in range(4)]
        if count == 1:
            return {"results": rows, "has_more": True, "next_cursor": "two"}
        assert kwargs["json"]["start_cursor"] == "two"
        return {"results": rows, "has_more": False}
    result = preview_source(request, LEDGER, SOURCE, MAPPING, CATEGORIES, "UZS", "Asia/Tashkent")
    assert result["totalRows"] == result["validRows"] == 8
    assert len(result["samples"]) == 5


@pytest.mark.parametrize("result", [{"results": [], "has_more": True},
    {"results": [], "request_status": {"type": "incomplete"}}, {"results": None}])
def test_incomplete_results_no_partial_preview(result):
    def request(method, path, **kwargs):
        return {"properties": SCHEMA} if method == "GET" else result
    with pytest.raises(ConnectorError, match="Incomplete"):
        preview_source(request, LEDGER, SOURCE, MAPPING, CATEGORIES, "UZS", "Asia/Tashkent")


def test_discovery_metadata_only_and_preview_does_not_bind(tmp_path):
    calls = []
    def handler(request):
        calls.append(request)
        assert request.headers["Authorization"] == "Bearer private"
        if request.url.path == "/v1/search":
            assert json.loads(request.content)["filter"]["value"] == "data_source"
            return httpx.Response(200, json={"results": [{"object": "data_source", "id": SOURCE,
                "title": [{"plain_text": "Expenses"}], "properties": SCHEMA}], "has_more": False})
        if request.method == "GET":
            return httpx.Response(200, json={"properties": SCHEMA})
        assert request.url.path == "/v1/data_sources/"+SOURCE+"/query"
        return httpx.Response(200, json={"results": [page()], "has_more": False})
    oauth = NotionOAuth(tmp_path, "id", "client-private", "https://example.test", httpx.Client(transport=httpx.MockTransport(handler)))
    oauth._save(LEDGER, "notion-default", {"status": "needsSelection", "access": "private", "refresh": "refresh", "expires": 9999999999})
    sources = oauth.authorized_sources(LEDGER)
    assert sources == {"sources": [{"id": SOURCE, "title": "Expenses", "schema": schema_summary(SCHEMA)}], "hasMore": False}
    assert len(calls) == 1  # No expense queries during discovery.
    result = oauth.preview_existing_source(LEDGER, "notion-default", SOURCE, MAPPING, CATEGORIES, "UZS", "Asia/Tashkent")
    assert result["validRows"] == 1
    assert oauth.connection_status(LEDGER)["needsSelection"]
    assert not oauth.connection_status(LEDGER)["connected"]
    assert oauth.ready_connections() == []
    assert all(r.method == "GET" or r.url.path.endswith(("/search", "/query")) for r in calls)
