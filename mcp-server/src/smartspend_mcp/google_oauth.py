"""Owner/ledger-bound Google enrollment. Tokens never belong in HTTP responses.

Only drive.file is requested. Enrollment creates one dedicated SmartSpend sheet;
connecting an existing sheet needs a Google Picker flow and is not implemented.
Unknown create outcomes remain pending for operator reconciliation, never retried.
"""
from __future__ import annotations

import base64
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

from .connectors import ConnectorError, HEADERS
from .sync_auth import https_url
from .validation import uuid_text

SCOPE = "https://www.googleapis.com/auth/drive.file"
TOKEN_URL = "https://oauth2.googleapis.com/token"


def _private_file(path, *, create=False):
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if create:
        flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            os.close(fd)
            raise ConnectorError("Google configuration must be an owner-only regular file")
        return fd
    except OSError:
        raise ConnectorError("Cannot open private Google configuration") from None


class GoogleOAuth:
    def __init__(self, root, client_id, client_secret, public_url, httpx_client=None):
        if not client_id or not client_secret:
            raise ConnectorError("Google OAuth client configuration is required")
        self.redirect_uri = https_url(public_url).rstrip("/") + "/oauth/google/callback"
        self._client_id, self._client_secret = client_id, client_secret
        self._owns_client = httpx_client is None
        self._client = httpx_client or httpx.Client(follow_redirects=False)
        self._lock = threading.RLock()
        root = Path(root).absolute()
        # Refuse symlink components, including a substituted parent directory.
        if any(p.is_symlink() for p in (root, *root.parents)):
            raise ConnectorError("Google storage must not contain symlinks")
        root.mkdir(parents=True, mode=0o700, exist_ok=True)
        private = root / "google-oauth"
        private.mkdir(mode=0o700, exist_ok=True)
        info = private.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConnectorError("Google storage must be an owner-only directory")
        key_path = private / "owner.key"
        if not key_path.exists() and (private / "oauth.sqlite3").exists():
            raise ConnectorError("Missing Google storage key; restore the matching key and token backup")
        try:
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "wb") as stream:
                stream.write(Fernet.generate_key())
                stream.flush()
                os.fsync(stream.fileno())
        with os.fdopen(_private_file(key_path), "rb") as stream:
            try:
                self._cipher = Fernet(stream.read(1024))
            except (ValueError, TypeError):
                raise ConnectorError("Invalid Google storage key") from None
        self._db = private / "oauth.sqlite3"
        os.close(_private_file(self._db, create=True))
        with self._connect() as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS states(hash TEXT PRIMARY KEY, expires REAL, payload BLOB, used INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS connections(ledger TEXT, connector TEXT, payload BLOB,
                PRIMARY KEY(ledger,connector));
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

    def ready_connections(self):
        """Internal scheduler identities only; never expose token/config blobs."""
        with self._lock, self._connect() as db:
            rows = db.execute("SELECT ledger,connector,payload FROM connections ORDER BY ledger,connector").fetchall()
            return [{"ledgerId": ledger, "connectorId": connector}
                    for ledger, connector, payload in rows if self._open(payload).get("status") == "ready"]

    def connection_status(self, ledger_id, connector_id="google-default"):
        ledger_id, connector_id = self._identity(ledger_id, connector_id)
        with self._lock, self._connect() as db:
            row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger_id, connector_id)).fetchone()
            if not row:
                return {"connected": False, "pending": False}
            value = self._open(row[0])
            result = {"connected": value.get("status") == "ready", "pending": value.get("status") == "pending"}
            if value.get("spreadsheetId"):
                result["spreadsheetId"] = value["spreadsheetId"]
            return result

    def disconnect(self, ledger_id, connector_id="google-default"):
        """Stop this connection and erase its tokens; never delete the sheet.

        Do not revoke Google's project-wide grant here: it could also disconnect
        this person's other installations. They can revoke it in Google settings.
        """
        ledger_id, connector_id = self._identity(ledger_id, connector_id)
        with self._lock, self._connect() as db:
            row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger_id, connector_id)).fetchone()
            saved = self._open(row[0]) if row else {}
            tombstone = {"status": "disconnected"}
            if saved.get("spreadsheetId"):
                tombstone["spreadsheetId"] = saved["spreadsheetId"]
            db.execute("INSERT OR REPLACE INTO connections VALUES(?,?,?)", (ledger_id, connector_id, self._seal(tombstone)))
            # Invalidate in-flight authorization states so a late callback cannot
            # silently reconnect after the user disconnects this installation.
            for digest, payload in db.execute("SELECT hash,payload FROM states WHERE used=0").fetchall():
                value = self._open(payload)
                if value.get("ledgerId") == ledger_id and value.get("connectorId") == connector_id:
                    db.execute("UPDATE states SET used=1 WHERE hash=?", (digest,))
        return {"disconnected": True, "providerRevoked": False}

    @classmethod
    def from_private_file(cls, root, public_url, filePath, client=None):
        with os.fdopen(_private_file(filePath), "rb") as stream:
            raw = stream.read(65537)
        try:
            if len(raw) > 65536:
                raise ValueError()
            web = json.loads(raw)["web"]
            callback = https_url(public_url).rstrip("/") + "/oauth/google/callback"
            if callback not in web["redirect_uris"]:
                raise ValueError()
            return cls(root, web["client_id"], web["client_secret"], public_url, client)
        except (KeyError, ValueError, TypeError):
            raise ConnectorError("Invalid Google web client or missing exact callback URI") from None

    def _seal(self, value):
        return self._cipher.encrypt(json.dumps(value).encode())

    def _open(self, value):
        try:
            return json.loads(self._cipher.decrypt(value))
        except (InvalidToken, ValueError):
            raise ConnectorError("Cannot decrypt Google connection") from None

    @staticmethod
    def _identity(ledger_id, connector_id):
        ledger_id = uuid_text(ledger_id)
        if not isinstance(connector_id, str) or not 1 <= len(connector_id) <= 100 or any(ord(c) < 32 for c in connector_id):
            raise ConnectorError("Invalid connector identifier")
        return ledger_id, connector_id

    def start(self, ledger_id, connector_id):
        ledger_id, connector_id = self._identity(ledger_id, connector_id)
        with self._lock, self._connect() as db:
            existing = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger_id, connector_id)).fetchone()
            if existing and self._open(existing[0]).get("status") != "disconnected":
                raise ConnectorError("Connection already exists or needs owner reconciliation")
            if existing:
                db.execute("DELETE FROM connections WHERE ledger=? AND connector=?", (ledger_id, connector_id))
            state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
            payload = {"ledgerId": ledger_id, "connectorId": connector_id, "verifier": verifier}
            db.execute("DELETE FROM states WHERE expires<?", (time.time(),))
            db.execute("INSERT INTO states(hash,expires,payload) VALUES(?,?,?)", (hashlib.sha256(state.encode()).hexdigest(), time.time() + 600, self._seal(payload)))
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
        return {"authorizationUrl": "https://accounts.google.com/o/oauth2/v2/auth?" + urlencode({
            "client_id": self._client_id, "redirect_uri": self.redirect_uri,
            "response_type": "code", "scope": SCOPE, "access_type": "offline",
            "prompt": "consent", "state": state, "code_challenge": challenge,
            "code_challenge_method": "S256", "include_granted_scopes": "false",
        })}

    def _request(self, method, url, **kwargs):
        try:
            response = self._client.request(method, url, timeout=30, **kwargs)
            if response.status_code >= 300:
                raise ConnectorError("Google request failed; reconnect or reconcile with owner")
            value = response.json()
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except (httpx.HTTPError, ValueError):
            raise ConnectorError("Google response unavailable; no automatic mutating retry") from None

    def _tokens(self, value, old=None):
        scope = value.get("scope")
        if scope is not None and (not isinstance(scope, str) or set(scope.split()) != {SCOPE}):
            raise ConnectorError("Google did not grant the requested file-only scope")
        access = value.get("access_token")
        refresh = value.get("refresh_token") or (old or {}).get("refresh")
        expires = value.get("expires_in")
        if not isinstance(access, str) or not access or not isinstance(refresh, str) or not refresh or type(expires) not in (int, float) or not 0 < expires <= 86400:
            raise ConnectorError("Google offline authorization is incomplete")
        token_type = value.get("token_type", "Bearer")
        if not isinstance(token_type, str) or token_type.lower() != "bearer":
            raise ConnectorError("Unsupported Google token type")
        return {"access": access, "refresh": refresh, "expires": time.time() + expires}

    def _save(self, ledger, connector, value):
        with self._connect() as db:
            db.execute("INSERT OR REPLACE INTO connections VALUES(?,?,?)", (ledger, connector, self._seal(value)))

    def callback(self, state, code):
        if not isinstance(state, str) or not 30 <= len(state) <= 100 or not isinstance(code, str) or not 1 <= len(code) <= 4096:
            raise ConnectorError("Invalid or expired Google authorization")
        with self._lock:
            # Commit single-use consumption BEFORE the code exchange, even on timeout.
            with self._connect() as db:
                db.execute("BEGIN IMMEDIATE")
                digest = hashlib.sha256(state.encode()).hexdigest()
                row = db.execute("SELECT payload FROM states WHERE hash=? AND used=0 AND expires>?", (digest, time.time())).fetchone()
                if not row:
                    raise ConnectorError("Invalid or expired Google authorization")
                db.execute("UPDATE states SET used=1 WHERE hash=?", (digest,))
                auth = self._open(row[0])
                # Prevent separate valid states from creating multiple sheets for one connector.
                existing = db.execute("SELECT 1 FROM connections WHERE ledger=? AND connector=?", (auth["ledgerId"], auth["connectorId"])).fetchone()
                if existing:
                    raise ConnectorError("Connection already exists or needs owner reconciliation")
                db.execute("INSERT INTO connections VALUES(?,?,?)", (auth["ledgerId"], auth["connectorId"], self._seal({"status": "pending"})))
            tokens = self._tokens(self._request("POST", TOKEN_URL, data={
                "client_id": self._client_id, "client_secret": self._client_secret,
                "code": code, "code_verifier": auth["verifier"], "grant_type": "authorization_code",
                "redirect_uri": self.redirect_uri,
            }))
            value = {**tokens, "status": "pending", "tab": "Sheet1"}
            self._save(auth["ledgerId"], auth["connectorId"], value)
            headers = {"Authorization": "Bearer " + tokens["access"]}
            sheet = self._request("POST", "https://sheets.googleapis.com/v4/spreadsheets", headers=headers,
                                  json={"properties": {"title": "SmartSpend"}, "sheets": [{"properties": {"title": "Sheet1"}}]})
            spreadsheet_id = sheet.get("spreadsheetId")
            if not isinstance(spreadsheet_id, str) or not spreadsheet_id:
                raise ConnectorError("Google spreadsheet creation outcome unknown; owner reconciliation required")
            value["spreadsheetId"] = spreadsheet_id
            self._save(auth["ledgerId"], auth["connectorId"], value)
            self._request("PUT", "https://sheets.googleapis.com/v4/spreadsheets/" + quote(spreadsheet_id, safe="") + "/values/Sheet1!A1:G1",
                          headers=headers, params={"valueInputOption": "RAW"}, json={"values": [list(HEADERS)]})
            value["status"] = "ready"
            self._save(auth["ledgerId"], auth["connectorId"], value)
            return {"ledgerId": auth["ledgerId"], "connectorId": auth["connectorId"], "spreadsheetId": spreadsheet_id, "tab": "Sheet1"}

    def config(self, ledger_id, connector_id):
        ledger_id, connector_id = self._identity(ledger_id, connector_id)
        with self._lock:
            with self._connect() as db:
                row = db.execute("SELECT payload FROM connections WHERE ledger=? AND connector=?", (ledger_id, connector_id)).fetchone()
            if not row:
                raise ConnectorError("Google connection not found")
            value = self._open(row[0])
            if value.get("status") != "ready":
                raise ConnectorError("Google enrollment pending; owner reconciliation required")
            if value["expires"] <= time.time() + 60:
                tokens = self._tokens(self._request("POST", TOKEN_URL, data={"client_id": self._client_id,
                    "client_secret": self._client_secret, "grant_type": "refresh_token", "refresh_token": value["refresh"]}), value)
                value.update(tokens)
                self._save(ledger_id, connector_id, value)
            return {"provider": "google_sheets", "token": value["access"], "ledgerId": ledger_id,
                    "connectorId": connector_id, "spreadsheetId": value["spreadsheetId"], "tab": value["tab"]}
