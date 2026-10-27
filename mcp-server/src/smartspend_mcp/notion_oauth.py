"""Public Notion OAuth: each ledger authorizes its own workspace and destination.

OAuth grants do not start financial sync. The owner must explicitly select a
shared page; only a new, dedicated SmartSpend database is used. Tokens and state
are encrypted at rest and never returned from public methods.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import sqlite3
import stat
import threading
import time
from urllib.parse import quote, urlencode

from cryptography.fernet import Fernet, InvalidToken
import httpx

from .connectors import ConnectorError
from .google_oauth import _private_file, GoogleOAuth
from .sync_auth import https_url
from .validation import uuid_text

API = "https://api.notion.com/v1/"
VERSION = "2025-09-03"  # Same explicit data-source model as NotionAdapter.


class NotionOAuth:
    def __init__(self, root, client_id, client_secret, public_url, httpx_client=None):
        if not isinstance(client_id, str) or not client_id or not isinstance(client_secret, str) or not client_secret:
            raise ConnectorError("Notion public OAuth configuration is required")
        self.redirect_uri = https_url(public_url).rstrip("/") + "/oauth/notion/callback"
        self._client_id, self._client_secret = client_id, client_secret
        self._owns_client = httpx_client is None
        self._client = httpx_client or httpx.Client(follow_redirects=False)
        self._lock = threading.RLock()
        root = Path(root).absolute()
        if any(p.is_symlink() for p in (root, *root.parents)):
            raise ConnectorError("Notion storage must not contain symlinks")
        root.mkdir(parents=True, mode=0o700, exist_ok=True)
        private = root / "notion-oauth"
        private.mkdir(mode=0o700, exist_ok=True)
        info = private.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConnectorError("Notion storage must be an owner-only directory")
        key = private / "owner.key"
        if not key.exists() and (private / "oauth.sqlite3").exists():
            raise ConnectorError("Missing Notion storage key; restore the matching key and token backup")
        try:
            fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "wb") as stream:
                stream.write(Fernet.generate_key())
                stream.flush()
                os.fsync(stream.fileno())
        with os.fdopen(_private_file(key), "rb") as stream:
            try:
                self._cipher = Fernet(stream.read(1024))
            except (TypeError, ValueError):
                raise ConnectorError("Invalid Notion storage key") from None
        self._db = private / "oauth.sqlite3"
        os.close(_private_file(self._db, create=True))
        with self._connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS states(hash TEXT PRIMARY KEY, expires REAL, payload BLOB, used INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS connections(ledger TEXT, connector TEXT, payload BLOB, PRIMARY KEY(ledger,connector));
            """)

    @contextmanager
    def _connect(self):
        db = sqlite3.connect(self._db)
        try:
            with db:
                yield db
        finally:
            db.close()

    def close(self):
        if self._owns_client:
            self._client.close()

    @classmethod
    def from_private_file(cls, root, public_url, filePath, client=None):
        with os.fdopen(_private_file(filePath), "rb") as stream:
            raw = stream.read(65537)
        try:
            value = json.loads(raw)
            if len(raw) > 65536 or value["redirect_uri"] != https_url(public_url).rstrip("/") + "/oauth/notion/callback":
                raise ValueError()
            return cls(root, value["client_id"], value["client_secret"], public_url, client)
        except (ValueError, TypeError, KeyError):
            raise ConnectorError("Invalid Notion public client or missing exact callback URI") from None

    _identity = staticmethod(GoogleOAuth._identity)

    def _seal(self, value):
        return self._cipher.encrypt(json.dumps(value).encode())

    def _open(self, value):
        try:
            return json.loads(self._cipher.decrypt(value))
        except (InvalidToken, ValueError):
            raise ConnectorError("Cannot decrypt Notion connection") from None

    def _save(self, ledger, connector, value):
        with self._connect() as db:
            db.execute("INSERT OR REPLACE INTO connections VALUES(?,?,?)", (ledger, connector, self._seal(value)))

    def _load(self, ledger, connector):
        with self._connect() as db:
            row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger, connector)).fetchone()
        if not row:
            raise ConnectorError("Notion connection not found")
        return self._open(row[0])

    def _request(self, method, path, *, token=None, **kwargs):
        headers = {"Notion-Version": VERSION}
        if token:
            headers["Authorization"] = "Bearer " + token
        else:
            kwargs["auth"] = httpx.BasicAuth(self._client_id, self._client_secret)
        try:
            response = self._client.request(method, API + path, headers=headers, timeout=30, **kwargs)
            if response.status_code >= 300:
                raise ConnectorError("Notion authorization or request failed; reconnect or review access")
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError()
            return result
        except (httpx.HTTPError, ValueError):
            raise ConnectorError("Notion outcome unknown; no automatic mutating retry") from None

    def start(self, ledger_id, connector_id="notion-default"):
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock, self._connect() as db:
            if db.execute("SELECT 1 FROM connections WHERE ledger=? AND connector=?", (ledger, connector)).fetchone():
                raise ConnectorError("Disconnect the existing Notion connection before reconnecting")
            state = secrets.token_urlsafe(32)
            db.execute("DELETE FROM states WHERE expires<?", (time.time(),))
            db.execute("INSERT INTO states(hash,expires,payload) VALUES(?,?,?)", (
                hashlib.sha256(state.encode()).hexdigest(), time.time() + 600,
                self._seal({"ledgerId": ledger, "connectorId": connector})))
        return {"authorizationUrl": "https://api.notion.com/v1/oauth/authorize?" + urlencode({
            "client_id": self._client_id, "redirect_uri": self.redirect_uri,
            "response_type": "code", "owner": "user", "state": state})}

    @staticmethod
    def _tokens(result):
        if any(not isinstance(result.get(k), str) or not result[k] for k in ("access_token", "refresh_token")):
            raise ConnectorError("Notion OAuth token response is incomplete")
        expires = result.get("expires_in", 3600)
        if type(expires) not in (int, float) or not 0 < expires <= 31536000:
            raise ConnectorError("Invalid Notion token lifetime")
        return {"access": result["access_token"], "refresh": result["refresh_token"],
                "expires": time.time() + expires}

    def callback(self, state, code):
        if not isinstance(state, str) or not 30 <= len(state) <= 100 or not isinstance(code, str) or not 1 <= len(code) <= 4096:
            raise ConnectorError("Invalid or expired Notion authorization")
        with self._lock:
            with self._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                digest = hashlib.sha256(state.encode()).hexdigest()
                row = db.execute("SELECT payload FROM states WHERE hash=? AND used=0 AND expires>?", (digest, time.time())).fetchone()
                if not row:
                    raise ConnectorError("Invalid or expired Notion authorization")
                auth = self._open(row[0])
                db.execute("UPDATE states SET used=1 WHERE hash=?", (digest,))
                if db.execute("SELECT 1 FROM connections WHERE ledger=? AND connector=?", (auth["ledgerId"], auth["connectorId"])).fetchone():
                    raise ConnectorError("Notion connection already exists")
                db.execute("INSERT INTO connections VALUES(?,?,?)", (
                    auth["ledgerId"], auth["connectorId"], self._seal({"status": "pending"})))
            result = self._request("POST", "oauth/token", json={"grant_type": "authorization_code", "code": code, "redirect_uri": self.redirect_uri})
            tokens = self._tokens(result)
            value = {**tokens, "status": "needsSelection"}
            self._save(auth["ledgerId"], auth["connectorId"], value)
            return {"ledgerId": auth["ledgerId"], "connectorId": auth["connectorId"], "needsSelection": True}

    def _authorized(self, ledger, connector):
        value = self._load(ledger, connector)
        if value.get("status") not in {"ready", "needsSelection"}:
            raise ConnectorError("Notion enrollment needs owner reconciliation")
        if value["expires"] <= time.time() + 60:
            # Rotation can consume a refresh token even if its response is lost.
            # Persist blocked status first; never replay an ambiguous rotation.
            original_status = value["status"]
            value["status"] = "pending"
            self._save(ledger, connector, value)
            result = self._request("POST", "oauth/token", json={"grant_type": "refresh_token", "refresh_token": value["refresh"]})
            value.update(self._tokens(result), status=original_status)
            self._save(ledger, connector, value)
        return value

    def parent_pages(self, ledger_id, connector_id="notion-default"):
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock:
            value = self._authorized(ledger, connector)
            pages, cursor, seen = [], None, set()
            for _ in range(20):
                body = {"filter": {"value": "page", "property": "object"}, "page_size": 100}
                if cursor:
                    body["start_cursor"] = cursor
                result = self._request("POST", "search", token=value["access"], json=body)
                if not isinstance(result.get("results"), list):
                    raise ConnectorError("Incomplete Notion page selection")
                for page in result["results"]:
                    if page.get("object") != "page" or page.get("in_trash") or page.get("archived"):
                        continue
                    # Database rows are not destinations, and their properties
                    # are not exposed. Only page-title metadata is returned.
                    if page.get("parent", {}).get("type") not in {"page_id", "workspace", "block_id"}:
                        continue
                    title = next((p.get("title", []) for p in page.get("properties", {}).values() if p.get("type") == "title"), [])
                    text = "".join(t.get("plain_text", t.get("text", {}).get("content", "")) for t in title)
                    pages.append({"id": uuid_text(page["id"]), "title": text[:300] or "Untitled"})
                if not result.get("has_more"):
                    return {"pages": pages, "hasMore": False}
                cursor = result.get("next_cursor")
                if not isinstance(cursor, str) or not cursor or cursor in seen:
                    raise ConnectorError("Incomplete Notion page selection")
                seen.add(cursor)
            raise ConnectorError("Too many shared pages; share a dedicated parent page")

    def authorized_sources(self, ledger_id, connector_id="notion-default"):
        """Metadata/schema for OAuth-shared tables only; never query their rows."""
        from .mapped_notion import schema_summary
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock:
            value = self._authorized(ledger, connector)
            sources, cursor, seen = [], None, set()
            for _ in range(20):
                body = {"filter": {"value": "data_source", "property": "object"}, "page_size": 100}
                if cursor:
                    body["start_cursor"] = cursor
                result = self._request("POST", "search", token=value["access"], json=body)
                if not isinstance(result.get("results"), list):
                    raise ConnectorError("Incomplete Notion data source selection")
                for source in result["results"]:
                    if not isinstance(source, dict) or source.get("object") != "data_source" or source.get("archived") or source.get("in_trash"):
                        continue
                    source_id = uuid_text(source.get("id"))
                    title = "".join(t.get("plain_text", t.get("text", {}).get("content", "")) for t in source.get("title", []))
                    schema = source.get("properties")
                    if schema is None:
                        schema = self._request("GET", "data_sources/" + source_id, token=value["access"]).get("properties")
                    sources.append({"id": source_id, "title": title[:300] or "Untitled", "schema": schema_summary(schema)})
                if not result.get("has_more"):
                    return {"sources": sources, "hasMore": False}
                cursor = result.get("next_cursor")
                if not isinstance(cursor, str) or not cursor or cursor in seen:
                    raise ConnectorError("Incomplete Notion data source selection")
                seen.add(cursor)
            raise ConnectorError("Too many shared Notion tables; share only selected tables")

    def preview_existing_source(self, ledger_id, connector_id, data_source_id, mapping, categories, currency, time_zone):
        """Explicit consent is checked by the caller route; no writes or binding."""
        from .mapped_notion import preview_source
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock:
            value = self._authorized(ledger, connector)
            def request(method, path, **kwargs):
                return self._request(method, path, token=value["access"], **kwargs)
            return preview_source(request, ledger, data_source_id, mapping, categories, currency, time_zone)

    def select_parent(self, ledger_id, connector_id, parent_page_id):
        ledger, connector = self._identity(ledger_id, connector_id)
        parent = uuid_text(parent_page_id)
        with self._lock:
            value = self._authorized(ledger, connector)
            if value["status"] != "needsSelection":
                raise ConnectorError("Notion destination already selected or pending")
            if parent not in {p["id"] for p in self.parent_pages(ledger, connector)["pages"]}:
                raise ConnectorError("Select a page explicitly shared with this Notion connection")
            properties = {"Title": {"title": {}}, "Amount": {"number": {}},
                "Date": {"date": {}}, "Deleted": {"checkbox": {}},
                **{name: {"rich_text": {}} for name in ("SmartSpend ID", "Category ID", "Currency")}}
            value.update(status="pending", parentPageId=parent)
            self._save(ledger, connector, value)
            result = self._request("POST", "databases", token=value["access"], json={
                "parent": {"type": "page_id", "page_id": parent},
                "title": [{"type": "text", "text": {"content": "SmartSpend"}}],
                "initial_data_source": {"properties": properties}})
            try:
                database = uuid_text(result["id"])
                sources = result["data_sources"]
                if len(sources) != 1:
                    raise ValueError()
                source = uuid_text(sources[0]["id"])
            except (KeyError, TypeError, ValueError):
                raise ConnectorError("Notion database creation outcome unknown; do not retry") from None
            value.update(status="ready", databaseId=database, dataSourceId=source)
            self._save(ledger, connector, value)
            return self.connection_status(ledger, connector)

    def connection_status(self, ledger_id, connector_id="notion-default"):
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock, self._connect() as db:
            row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger, connector)).fetchone()
            value = self._open(row[0]) if row else {}
            result = {"connected": value.get("status") == "ready", "pending": value.get("status") == "pending",
                      "needsSelection": value.get("status") == "needsSelection"}
            if value.get("databaseId"):
                result.update(databaseId=value["databaseId"], databaseUrl="https://www.notion.so/" + value["databaseId"].replace("-", ""))
            return result

    def ready_connections(self):
        with self._lock, self._connect() as db:
            return [{"ledgerId": l, "connectorId": c} for l, c, v in db.execute("SELECT ledger,connector,payload FROM connections ORDER BY ledger,connector")
                    if self._open(v).get("status") == "ready"]

    def config(self, ledger_id, connector_id="notion-default"):
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock:
            value = self._authorized(ledger, connector)
            if value["status"] != "ready":
                raise ConnectorError("Select a Notion parent page first")
            return {"provider": "notion", "token": value["access"], "ledgerId": ledger,
                    "connectorId": connector, "dataSourceId": value["dataSourceId"]}

    def disconnect(self, ledger_id, connector_id="notion-default"):
        ledger, connector = self._identity(ledger_id, connector_id)
        with self._lock:
            with self._connect() as db:
                row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger, connector)).fetchone()
                value = self._open(row[0]) if row else {}
                db.execute("DELETE FROM connections WHERE ledger=? AND connector=?", (ledger, connector))
                # Outstanding browser consent must not resurrect a disconnected link.
                for digest, payload in db.execute("SELECT hash,payload FROM states WHERE used=0").fetchall():
                    auth = self._open(payload)
                    if (auth["ledgerId"], auth["connectorId"]) == (ledger, connector):
                        db.execute("UPDATE states SET used=1 WHERE hash=?", (digest,))
            revoked = not value.get("access")
            if value.get("access"):
                try:
                    self._request("POST", "oauth/revoke", json={"token": value["access"]})
                    revoked = True
                except ConnectorError:
                    pass  # Local sync is stopped regardless; owner can revoke in Notion.
            return {"disconnected": True, "revoked": revoked}
