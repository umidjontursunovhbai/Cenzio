"""Ledger-scoped grants. Voice tokens are intentionally not accepted here.

OAuth is a resource-server integration with an operator-configured issuer, not a
home-made login/password service. Subject-to-ledger bindings are owner-managed.
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

import jwt
from mcp.server.auth.provider import AccessToken

from .validation import LedgerError, uuid_text

SCOPES = frozenset({"ledger:read", "ledger:write"})


def https_url(value: str) -> str:
    parts = urlsplit(value)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise LedgerError("A fixed HTTPS URL without credentials, query or fragment is required")
    return value


@dataclass(frozen=True)
class Principal:
    ledger_id: str
    scopes: frozenset[str]
    grant_id: str

    def require(self, scope: str) -> None:
        if scope not in self.scopes:
            raise PermissionError("insufficient_scope")


class GrantStore:
    def __init__(self, path: Path):
        if path.is_symlink():
            raise LedgerError("Grant database must not be a symlink")
        path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.path = path
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        os.chmod(path, 0o600)
        with sqlite3.connect(path) as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS grants(id TEXT PRIMARY KEY, hash TEXT UNIQUE, ledger TEXT, scopes TEXT, expires INTEGER);
            CREATE TABLE IF NOT EXISTS subjects(issuer TEXT, subject TEXT, ledger TEXT, scopes TEXT, PRIMARY KEY(issuer,subject));
            """)
        os.chmod(path, 0o600)

    @staticmethod
    def scope_text(scopes):
        values = frozenset(scopes)
        if not values or not values <= SCOPES or "ledger:read" not in values:
            raise LedgerError("Grants require ledger:read and optionally ledger:write")
        return " ".join(sorted(values))

    def issue(self, ledger_id: str, scopes=SCOPES, *, lifetime: int = 86400 * 30):
        ledger_id = uuid_text(ledger_id)
        if type(lifetime) is not int or not 60 <= lifetime <= 86400 * 90:
            raise LedgerError("Grant lifetime must be 60 seconds–90 days")
        scope = self.scope_text(scopes)
        identifier, token = secrets.token_hex(16), secrets.token_urlsafe(32)
        with sqlite3.connect(self.path) as db:
            db.execute("INSERT INTO grants VALUES(?,?,?,?,?)", (identifier, hashlib.sha256(token.encode()).hexdigest(), ledger_id, scope, int(time.time()) + lifetime))
        return identifier, token

    def verify(self, token: str) -> Principal | None:
        if not isinstance(token, str) or not 40 <= len(token) <= 100:
            return None
        with sqlite3.connect(self.path) as db:
            row = db.execute("SELECT id,ledger,scopes FROM grants WHERE hash=? AND expires>?", (hashlib.sha256(token.encode()).hexdigest(), int(time.time()))).fetchone()
        return Principal(row[1], frozenset(row[2].split()), row[0]) if row else None

    def revoke(self, grant_id: str):
        with sqlite3.connect(self.path) as db:
            db.execute("DELETE FROM grants WHERE id=?", (grant_id,))

    def bind(self, issuer: str, subject: str, ledger_id: str, scopes=SCOPES):
        issuer = https_url(issuer)
        if not isinstance(subject, str) or not 1 <= len(subject) <= 300:
            raise LedgerError("A bounded OAuth subject is required")
        with sqlite3.connect(self.path) as db:
            db.execute("INSERT OR REPLACE INTO subjects VALUES(?,?,?,?)", (issuer, subject, uuid_text(ledger_id), self.scope_text(scopes)))

    def unbind(self, issuer: str, subject: str):
        with sqlite3.connect(self.path) as db:
            db.execute("DELETE FROM subjects WHERE issuer=? AND subject=?", (https_url(issuer), subject))

    def subject(self, issuer: str, subject: str, granted_scopes) -> Principal | None:
        with sqlite3.connect(self.path) as db:
            row = db.execute("SELECT ledger,scopes FROM subjects WHERE issuer=? AND subject=?", (issuer, subject)).fetchone()
        if not row:
            return None
        scopes = frozenset(row[1].split()) & frozenset(granted_scopes)
        return Principal(row[0], scopes, "oauth") if "ledger:read" in scopes else None


class OAuthVerifier:
    """RS256 access tokens; pinned issuer/audience and server-side subject binding.

    Configure the upstream OAuth AS for authorization-code + S256 PKCE and an
    MCP-compatible registered client. No insecure fallback to decoded claims.
    """
    def __init__(self, grants: GrantStore, *, issuer: str, resource: str, jwks_url: str):
        self.grants = grants
        self.issuer, self.resource = https_url(issuer), https_url(resource)
        self.keys = jwt.PyJWKClient(https_url(jwks_url), cache_keys=True, lifespan=300, timeout=5)

    def _verify(self, token: str) -> AccessToken | None:
        try:
            if len(token) > 8192:
                return None
            key = self.keys.get_signing_key_from_jwt(token)
            claims = jwt.decode(token, key.key, algorithms=["RS256"], audience=self.resource, issuer=self.issuer,
                                options={"require": ["exp", "iat", "sub", "iss", "aud"]})
            scope = claims.get("scope", "")
            if not isinstance(scope, str) or not isinstance(claims["sub"], str):
                return None
            principal = self.grants.subject(self.issuer, claims["sub"], scope.split())
            if principal is None:
                return None
            return AccessToken(token=token, client_id=str(claims.get("client_id", claims.get("azp", "oauth"))),
                               scopes=sorted(principal.scopes), expires_at=claims["exp"], resource=self.resource,
                               subject=claims["sub"], claims={"ledgerId": principal.ledger_id})
        except (jwt.PyJWTError, ValueError, TypeError, KeyError):
            return None

    async def verify_token(self, token: str) -> AccessToken | None:
        return await asyncio.to_thread(self._verify, token)
