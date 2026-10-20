"""Explicitly selected Google Sheet / Notion data-source adapters.

Official contracts (no workspace-wide search or implicit resource creation):
https://developers.google.com/workspace/sheets/api/guides/values
https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/append
https://developers.notion.com/reference/query-a-data-source
https://developers.notion.com/reference/patch-page
https://developers.notion.com/reference/post-page

Use a dedicated table with exactly HEADERS below. Deleted is an explicit soft-delete
flag; missing rows/pages are NOT deletion instructions. Access tokens are injected
by the owner-side runner and are never persisted by these adapters.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Protocol
from urllib.parse import quote

import httpx

from .validation import CURRENCIES, LedgerError, expense_data, uuid_text

HEADERS = ("SmartSpend ID", "Title", "Amount", "Category ID", "Date", "Currency", "Deleted")
_UNSET = object()


class ConnectorError(LedgerError):
    """Safe error that never contains authorization headers/provider response bodies."""


@dataclass(frozen=True)
class ExternalRecord:
    expense: dict
    archived: bool = False

    def data(self):
        return {"expense": self.expense, "archived": self.archived}


class Adapter(Protocol):
    currency: str
    def fetch(self) -> dict[str, ExternalRecord]: ...
    def put(self, record: ExternalRecord, expected=_UNSET) -> None: ...


def _record(values, currency):
    if len(values) != 7 or values[5] != currency or currency not in CURRENCIES:
        raise ConnectorError("Invalid connector row or currency mismatch")
    flag = str(values[6]).strip().lower()
    if flag not in ("", "false", "true", "0", "1"):
        raise ConnectorError("Deleted must be TRUE or FALSE")
    return ExternalRecord(expense_data(dict(zip(
        ("id", "title", "amount", "categoryId", "date"), map(str, values[:5])
    ))), flag in ("true", "1"))


class _HTTP:
    def __init__(self, client, token, currency):
        if currency not in CURRENCIES or not token:
            raise ConnectorError("A supported currency and access token are required")
        self.client, self.token, self.currency = client, token, currency

    def request(self, method, url, **kwargs):
        # No automatic mutating retries: an unknown outcome must be reconciled by
        # stable UUID before a create is attempted again. Runner persists retries.
        headers = {"Authorization": f"Bearer {self.token}", **kwargs.pop("headers", {})}
        try:
            response = self.client.request(method, url, headers=headers, timeout=30, **kwargs)
        except httpx.HTTPError as exc:
            raise ConnectorError("Provider connection failed; retry after reconciliation") from None
        if response.status_code >= 400:
            retry = response.headers.get("Retry-After", "")
            try:
                wait = max(1, min(3600, int(retry)))
            except ValueError:
                wait = 30
            error = ConnectorError(f"Provider HTTP {response.status_code}; retry in {wait}s")
            error.retry_after = wait
            raise error
        try:
            data = response.json()
        except ValueError:
            raise ConnectorError("Provider returned invalid JSON") from None
        if not isinstance(data, dict):
            raise ConnectorError("Provider returned an invalid response object")
        return data


class SheetsAdapter(_HTTP):
    def __init__(self, client: httpx.Client, token: str, spreadsheet_id: str, tab: str, currency: str):
        super().__init__(client, token, currency)
        if not spreadsheet_id or not tab or len(tab) > 100:
            raise ConnectorError("An explicitly selected spreadsheet and tab are required")
        self.base = f"https://sheets.googleapis.com/v4/spreadsheets/{quote(spreadsheet_id, safe='')}/values/"
        self.tab = "'" + tab.replace("'", "''") + "'"

    def fetch(self):
        result = self.request("GET", self.base + quote(self.tab + "!A:G", safe=""),
                              params={"valueRenderOption": "UNFORMATTED_VALUE"})
        rows = result.get("values", [])
        if not rows or tuple(rows[0]) != HEADERS:
            raise ConnectorError("Sheet is empty or SmartSpend headers do not match; no changes applied")
        records = {}
        for row in rows[1:]:
            if not any(str(v).strip() for v in row):
                continue
            row = list(row) + [""] * (7 - len(row))
            record = _record(row, self.currency)
            key = record.expense["id"]
            if key in records:
                raise ConnectorError("Duplicate SmartSpend UUID in provider")
            records[key] = record
        return records

    def put(self, record, expected=_UNSET):
        # Re-read immediately: rows can be reordered between sync runs; row numbers
        # are coordinates only, NEVER identity. Unknown append outcomes deduplicate.
        rows = self.request("GET", self.base + quote(self.tab + "!A:G", safe=""),
                            params={"valueRenderOption": "UNFORMATTED_VALUE"}).get("values", [])
        if not rows or tuple(rows[0]) != HEADERS:
            raise ConnectorError("Sheet headers changed; refusing write")
        matches = [i for i, row in enumerate(rows[1:], 2)
                   if row and str(row[0]).strip() and uuid_text(str(row[0])) == record.expense["id"]]
        if len(matches) > 1:
            raise ConnectorError("Duplicate SmartSpend UUID in provider")
        if expected is not _UNSET:
            current = None
            if matches:
                values = list(rows[matches[0] - 1])
                current = _record(values + [""] * (7 - len(values)), self.currency).data()
            if current != expected and current != record.data():
                raise ConnectorError("Provider changed before write; reconcile again")
        item = expense_data(record.expense)
        values = [[item[k] for k in ("id", "title", "amount", "categoryId", "date")]
                  + [self.currency, record.archived]]
        if matches:
            target = self.tab + f"!A{matches[0]}:G{matches[0]}"
            self.request("PUT", self.base + quote(target, safe=""), params={"valueInputOption": "RAW"}, json={"values": values})
        else:
            self.request("POST", self.base + quote(self.tab + "!A:G", safe="") + ":append",
                         params={"valueInputOption": "RAW", "insertDataOption": "INSERT_ROWS"}, json={"values": values})


class NotionAdapter(_HTTP):
    def __init__(self, client: httpx.Client, token: str, data_source_id: str, currency: str):
        super().__init__(client, token, currency)
        if not data_source_id:
            raise ConnectorError("An explicitly selected Notion data source is required")
        self.source = data_source_id
        self.pages = {}
        self.known_pages = {}
        self.known_records = {}

    def request(self, method, url, **kwargs):
        return super().request(method, "https://api.notion.com/v1/" + url,
                               headers={"Notion-Version": "2025-09-03"}, **kwargs)

    def fetch(self):
        records, pages, cursor, seen = {}, {}, None, set()
        while True:
            body = {"page_size": 100}
            if cursor:
                body["start_cursor"] = cursor
            result = self.request("POST", f"data_sources/{quote(self.source, safe='')}/query", json=body)
            if not isinstance(result.get("results"), list):
                raise ConnectorError("Incomplete Notion query")
            if result.get("request_status", {}).get("type") == "incomplete":
                raise ConnectorError("Notion query result capped; no partial sync allowed")
            for page in result["results"]:
                properties = page.get("properties", {})
                def text(name, kind="rich_text"):
                    return "".join(part.get("plain_text", part.get("text", {}).get("content", ""))
                                   for part in properties.get(name, {}).get(kind, []))
                amount = properties.get("Amount", {}).get("number")
                date = properties.get("Date", {}).get("date") or {}
                record = _record([text("SmartSpend ID"), text("Title", "title"),
                                  format(Decimal(str(amount)), "f") if amount is not None else "",
                                  text("Category ID"), date.get("start", ""), text("Currency"),
                                  properties.get("Deleted", {}).get("checkbox", False)], self.currency)
                if page.get("in_trash") or page.get("archived") or page.get("is_archived"):
                    record = ExternalRecord(record.expense, True)
                key = record.expense["id"]
                if key in records:
                    raise ConnectorError("Duplicate SmartSpend UUID in provider")
                records[key], pages[key] = record, page["id"]
            if not result.get("has_more", False):
                break
            cursor = result.get("next_cursor")
            if not cursor or cursor in seen:
                raise ConnectorError("Incomplete or repeated Notion cursor")
            seen.add(cursor)
            if len(seen) > 1000:
                raise ConnectorError("Notion pagination limit exceeded")
        # Query omits trashed pages. Confirm each previously mapped missing page
        # with the retrieve endpoint; revoked access / 404 is not a delete signal.
        for key, page_id in self.known_pages.items():
            if key in records or key not in self.known_records:
                continue
            page = self.request("GET", "pages/" + quote(page_id, safe=""))
            if page.get("in_trash") or page.get("archived") or page.get("is_archived"):
                records[key] = ExternalRecord(self.known_records[key]["expense"], True)
                pages[key] = page_id
        self.pages = pages
        return records

    def put(self, record, expected=_UNSET):
        # Query before every write, including retry after unknown create outcome.
        current = self.fetch().get(record.expense["id"])
        if expected is not _UNSET and (current.data() if current else None) not in (expected, record.data()):
            raise ConnectorError("Provider changed before write; reconcile again")
        item = expense_data(record.expense)
        def rich(value):
            return {"rich_text": [{"text": {"content": value}}]}
        props = {"SmartSpend ID": rich(item["id"]), "Title": {"title": [{"text": {"content": item["title"]}}]},
                 "Amount": {"number": float(Decimal(item["amount"]))}, "Category ID": rich(item["categoryId"]),
                 "Date": {"date": {"start": item["date"]}}, "Currency": rich(self.currency),
                 "Deleted": {"checkbox": record.archived}}
        if item["id"] in self.pages:
            payload = {"properties": props}
            if not record.archived:
                payload["in_trash"] = False
            self.request("PATCH", "pages/" + quote(self.pages[item["id"]], safe=""), json=payload)
        else:
            result = self.request("POST", "pages", json={"parent": {"type": "data_source_id", "data_source_id": self.source}, "properties": props})
            if not result.get("id"):
                raise ConnectorError("Notion create outcome unknown; reconcile before retry")
            self.pages[item["id"]] = result["id"]
