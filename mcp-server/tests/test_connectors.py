import json
from urllib.parse import unquote
from uuid import uuid4

import httpx
import pytest

from smartspend_mcp.connectors import HEADERS, SheetsAdapter, NotionAdapter, ExternalRecord, ConnectorError


def expense():
    return {"id": str(uuid4()), "title": "Bus", "amount": "2500", "categoryId": str(uuid4()), "date": "2026-10-20T00:00:00.000Z"}


def row(item):
    return [item[k] for k in ("id", "title", "amount", "categoryId", "date")] + ["UZS", False]


def page(item):
    def rich(value):
        return {"rich_text": [{"plain_text": value}]}
    return {"id": str(uuid4()), "properties": {"SmartSpend ID": rich(item["id"]),
        "Title": {"title": [{"plain_text": item["title"]}]}, "Amount": {"number": 2500},
        "Category ID": rich(item["categoryId"]), "Date": {"date": {"start": item["date"]}},
        "Currency": rich("UZS"), "Deleted": {"checkbox": False}}}


def test_sheets_stable_id_after_reorder_and_raw_values():
    a, b = expense(), expense()
    requests = []
    def handle(request):
        requests.append(request)
        return httpx.Response(200, json={"values": [HEADERS, row(b), row(a)]} if request.method == "GET" else {})
    adapter = SheetsAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "secret", "selected", "Expenses", "UZS")
    assert set(adapter.fetch()) == {a["id"], b["id"]}
    adapter.put(ExternalRecord(a))
    assert requests[-1].method == "PUT"
    assert "A3:G3" in unquote(str(requests[-1].url))
    assert requests[-1].url.params["valueInputOption"] == "RAW"


@pytest.mark.parametrize("rows", [[], [HEADERS, ["bad"]], [HEADERS, ["bad", "x", -1]], [["wrong"]]])
def test_invalid_sheet_is_not_partial_success(rows):
    adapter = SheetsAdapter(httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"values": rows}))), "s", "id", "tab", "UZS")
    with pytest.raises(ValueError):
        adapter.fetch()


def test_notion_full_pagination_and_duplicate_prevention():
    a, b = expense(), expense()
    requests = []
    def handle(req):
        requests.append(req)
        second = json.loads(req.content).get("start_cursor")
        return httpx.Response(200, json={"results": [page(b if second else a)], "has_more": not second, "next_cursor": None if second else "next"})
    adapter = NotionAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "s", "selected", "UZS")
    assert set(adapter.fetch()) == {a["id"], b["id"]}
    assert len(requests) == 2
    assert all("data_sources/selected/query" in str(r.url) for r in requests)


def test_notion_later_page_failure_is_not_partial_success():
    a = expense()
    def handle(req):
        if json.loads(req.content).get("start_cursor"):
            return httpx.Response(429, headers={"Retry-After": "999999"})
        return httpx.Response(200, json={"results": [page(a)], "has_more": True, "next_cursor": "next"})
    adapter = NotionAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "secret", "selected", "UZS")
    with pytest.raises(ConnectorError) as exc:
        adapter.fetch()
    assert exc.value.retry_after == 3600
    assert "secret" not in str(exc.value)


def test_unknown_append_outcome_retries_by_stable_uuid():
    a, rows, appends = expense(), [HEADERS], []
    def handle(req):
        if req.method == "GET":
            return httpx.Response(200, json={"values": rows})
        if req.method == "POST":
            appends.append(1)
            rows.extend(json.loads(req.content)["values"])
            raise httpx.ReadTimeout("unknown result")
        return httpx.Response(200, json={})
    adapter = SheetsAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "s", "id", "tab", "UZS")
    with pytest.raises(ConnectorError):
        adapter.put(ExternalRecord(a))
    adapter.put(ExternalRecord(a))
    assert len(appends) == 1


def test_notion_known_missing_page_requires_confirmed_trash():
    a = expense()
    def handle(req):
        if req.method == "GET":
            return httpx.Response(200, json={"in_trash": True})
        return httpx.Response(200, json={"results": [], "has_more": False})
    adapter = NotionAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "s", "selected", "UZS")
    adapter.known_pages = {a["id"]: "known-page"}
    adapter.known_records = {a["id"]: {"expense": a, "archived": False}}
    assert adapter.fetch()[a["id"]].archived


def test_notion_capped_query_is_not_full_success():
    adapter = NotionAdapter(httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200,
        json={"results": [], "has_more": False, "request_status": {"type": "incomplete"}}))), "s", "selected", "UZS")
    with pytest.raises(ConnectorError, match="capped"):
        adapter.fetch()


def test_sheets_provider_edit_between_poll_and_put_is_not_overwritten():
    a = expense()
    old = ExternalRecord(a).data()
    edited = {**a, "title": "Human editing"}
    writes = []
    def handle(req):
        if req.method != "GET":
            writes.append(req)
        return httpx.Response(200, json={"values": [HEADERS, row(edited)]})
    adapter = SheetsAdapter(httpx.Client(transport=httpx.MockTransport(handle)), "s", "id", "tab", "UZS")
    with pytest.raises(ConnectorError, match="changed before write"):
        adapter.put(ExternalRecord({**a, "title": "App edit"}), expected=old)
    assert not writes
