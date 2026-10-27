"""Provider-verified account identity. Never grants access to a financial ledger.

Native PKCE protects completion codes independently from provider OAuth PKCE.
Emails never merge identities; only a verified provider subject identifies users.
"""
from __future__ import annotations

import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time
from urllib.parse import urlencode
from uuid import uuid4

from cryptography.fernet import Fernet

from .sync_auth import https_url


PROVIDERS = ("google", "apple", "telegram")
CALLBACK_URI = "smartspend://account/callback"


class AccountAuthError(ValueError):
    pass


class AccountRateLimitError(AccountAuthError):
    pass


class AccountDeletionError(AccountAuthError):
    pass


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def challenge(value):
    return base64.urlsafe_b64encode(hashlib.sha256(value.encode()).digest()).decode().rstrip("=")


def bounded(value, pattern, maximum):
    if not isinstance(value, str) or len(value) > maximum or not re.fullmatch(pattern, value):
        raise AccountAuthError("Invalid account request")
    return value


class AccountAuth:
    def __init__(self, root, public_url, providers):
        self.public_url = https_url(public_url).rstrip("/")
        if set(providers) - set(PROVIDERS):
            raise AccountAuthError("Unsupported account provider")
        self.providers = dict(providers)
        root = Path(root).absolute()
        if any(p.is_symlink() for p in (root, *root.parents)):
            raise AccountAuthError("Account storage must not contain symlinks")
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = root / "accounts"
        directory.mkdir(mode=0o700, exist_ok=True)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise AccountAuthError("Account directory must be private")
        self.path = directory / "accounts.sqlite3"
        key_path = directory / "tokens.key"
        if not key_path.exists() and self.path.exists():
            raise AccountAuthError("Missing account token key; restore matching private backup")
        try:
            key_fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(key_fd, "wb") as stream:
                stream.write(Fernet.generate_key())
                stream.flush()
                os.fsync(stream.fileno())
        key_fd = os.open(key_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(key_fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise AccountAuthError("Account key must be private")
            self._cipher = Fernet(stream.read(1024))
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise AccountAuthError("Account database must be private")
        finally:
            os.close(fd)
        self._lock = threading.RLock()
        with self._db() as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS pending(hash TEXT PRIMARY KEY, expires REAL, payload TEXT);
            CREATE TABLE IF NOT EXISTS completions(hash TEXT PRIMARY KEY, expires REAL, payload TEXT);
            CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, provider TEXT, subject TEXT,
              email TEXT, name TEXT, revocation BLOB, UNIQUE(provider,subject));
            CREATE TABLE IF NOT EXISTS sessions(hash TEXT PRIMARY KEY, account TEXT, expires REAL);
            CREATE TABLE IF NOT EXISTS limits(peer TEXT, window INTEGER, count INTEGER,
              PRIMARY KEY(peer,window));
            """)

    @classmethod
    def from_private_file(cls, root, public_url, path):
        from .identity_providers import load_identity_providers
        return cls(root, public_url, load_identity_providers(path))

    @contextmanager
    def _db(self):
        connection = sqlite3.connect(self.path)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def availability(self):
        return {"providers": [{"id": p, "available": p in self.providers} for p in PROVIDERS]}

    def start(self, data, *, peer):
        if not isinstance(data, dict) or set(data) != {"provider", "codeChallenge", "state"}:
            raise AccountAuthError("Invalid account request")
        provider = data["provider"]
        if not isinstance(provider, str) or provider not in self.providers:
            raise AccountAuthError("Account provider unavailable")
        native_challenge = bounded(data["codeChallenge"], r"[A-Za-z0-9_-]{43}", 43)
        native_state = bounded(data["state"], r"[A-Za-z0-9_-]{32,128}", 128)
        now = time.time()
        state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
        redirect = self.public_url + "/oauth/account/" + provider + "/callback"
        # Rate limits persist across restarts; forwarding headers are not trusted.
        with self._lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            window = int(now // 3600)
            key = digest(str(peer))
            row = db.execute("SELECT count FROM limits WHERE peer=? AND window=?", (key, window)).fetchone()
            if row and row[0] >= 30:
                raise AccountRateLimitError("Account request limit reached")
            db.execute("INSERT INTO limits VALUES(?,?,1) ON CONFLICT(peer,window) DO UPDATE SET count=count+1", (key, window))
            db.execute("DELETE FROM limits WHERE window<?", (window - 1,))
            for table in ("pending", "completions", "sessions"):
                db.execute(f"DELETE FROM {table} WHERE expires<?", (now,))
            if db.execute("SELECT count(*) FROM pending").fetchone()[0] >= 10000:
                raise AccountRateLimitError("Account request limit reached")
            payload = {"provider": provider, "nativeState": native_state, "challenge": native_challenge,
                       "nonce": nonce, "verifier": verifier, "redirect": redirect}
            db.execute("INSERT INTO pending VALUES(?,?,?)", (digest(state), now + 600, json.dumps(payload)))
        url = self.providers[provider].authorization_url(state=state, nonce=nonce,
                  redirect_uri=redirect, code_challenge=challenge(verifier))
        return {"authorizationURL": url, "expiresAt": int(now + 600)}

    def callback(self, provider, fields):
        state = bounded(fields.get("state"), r"[A-Za-z0-9_-]{43}", 43)
        with self._lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT expires,payload FROM pending WHERE hash=?", (digest(state),)).fetchone()
            if not row or row[0] <= time.time():
                raise AccountAuthError("Sign-in expired")
            payload = json.loads(row[1])
            if payload["provider"] != provider:
                raise AccountAuthError("Invalid callback provider")
            db.execute("DELETE FROM pending WHERE hash=?", (digest(state),))
        # Claim state before exchanging: callbacks can never be replayed concurrently.
        try:
            if fields.get("error") or not isinstance(fields.get("code"), str) or not 1 <= len(fields["code"]) <= 8192:
                raise AccountAuthError("Sign-in failed")
            identity = self.providers[provider].exchange(code=fields["code"], redirect_uri=payload["redirect"],
                         nonce=payload["nonce"], code_verifier=payload["verifier"])
            if identity.provider != provider or not identity.subject or len(identity.subject) > 512:
                raise AccountAuthError("Invalid provider identity")
            completion = secrets.token_urlsafe(32)
            value = {"provider": provider, "subject": identity.subject,
                     "email": identity.email if identity.email_verified else None,
                     "name": identity.display_name, "state": payload["nativeState"],
                     "challenge": payload["challenge"]}
            revocation = getattr(identity, "revocation_token", None)
            if provider == "apple" and not revocation:
                raise AccountAuthError("Apple revocation token required")
            value["revocation"] = self._cipher.encrypt(revocation.encode()).decode() if revocation else None
            with self._lock, self._db() as db:
                db.execute("INSERT INTO completions VALUES(?,?,?)", (digest(completion), time.time() + 120, json.dumps(value)))
            return CALLBACK_URI + "?" + urlencode({"code": completion, "state": payload["nativeState"]})
        except Exception:
            # Never send provider exception text, credentials, or auth codes to a client/log.
            return CALLBACK_URI + "?" + urlencode({"error": "sign_in_failed", "state": payload["nativeState"]})

    def exchange(self, data):
        if not isinstance(data, dict) or set(data) != {"code", "codeVerifier", "state"}:
            raise AccountAuthError("Invalid account request")
        code = bounded(data["code"], r"[A-Za-z0-9_-]{43}", 43)
        verifier = bounded(data["codeVerifier"], r"[A-Za-z0-9._~-]{43,128}", 128)
        state = bounded(data["state"], r"[A-Za-z0-9_-]{32,128}", 128)
        now = time.time()
        with self._lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT expires,payload FROM completions WHERE hash=?", (digest(code),)).fetchone()
            if not row or row[0] <= now:
                raise AccountAuthError("Sign-in expired")
            value = json.loads(row[1])
            if not secrets.compare_digest(state, value["state"]) or not secrets.compare_digest(challenge(verifier), value["challenge"]):
                raise AccountAuthError("Invalid sign-in proof")
            db.execute("DELETE FROM completions WHERE hash=?", (digest(code),))
            row = db.execute("SELECT id FROM accounts WHERE provider=? AND subject=?", (value["provider"], value["subject"])).fetchone()
            account_id = row[0] if row else str(uuid4())
            db.execute("INSERT INTO accounts VALUES(?,?,?,?,?,?) ON CONFLICT(provider,subject) DO UPDATE SET email=excluded.email,name=excluded.name,revocation=COALESCE(excluded.revocation,accounts.revocation)",
                       (account_id, value["provider"], value["subject"], value["email"], value["name"], value["revocation"]))
            token = secrets.token_urlsafe(32)
            expires = int(now + 7 * 86400)
            db.execute("INSERT INTO sessions VALUES(?,?,?)", (digest(token), account_id, expires))
            account = self._account(db, account_id)
        return {"accessToken": token, "expiresAt": expires, "account": account}

    @staticmethod
    def _account(db, identifier):
        row = db.execute("SELECT id,provider,email,name FROM accounts WHERE id=?", (identifier,)).fetchone()
        return {"id": row[0], "provider": row[1], "email": row[2], "displayName": row[3]} if row else None

    def current(self, token):
        if not isinstance(token, str) or len(token) != 43:
            raise PermissionError("Unauthorized")
        with self._lock, self._db() as db:
            row = db.execute("SELECT account FROM sessions WHERE hash=? AND expires>?", (digest(token), time.time())).fetchone()
            account = self._account(db, row[0]) if row else None
        if not account:
            raise PermissionError("Unauthorized")
        return {"account": account}

    def logout(self, token):
        self.current(token)
        with self._lock, self._db() as db:
            db.execute("DELETE FROM sessions WHERE hash=?", (digest(token),))
        return {"signedOut": True}

    def delete(self, token):
        identifier = self.current(token)["account"]["id"]
        with self._lock, self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            stored = db.execute("SELECT provider,subject,revocation FROM accounts WHERE id=?", (identifier,)).fetchone()
            if not stored:
                raise PermissionError("Unauthorized")
            row = stored[:2]
            if row[0] == "apple":
                try:
                    self.providers["apple"].revoke(self._cipher.decrypt(stored[2]).decode())
                except Exception:
                    raise AccountDeletionError("Account deletion unavailable; retry") from None
            # Discard in-flight verified completions for this identity as well.
            for key, raw in db.execute("SELECT hash,payload FROM completions").fetchall():
                value = json.loads(raw)
                if row and (value["provider"], value["subject"]) == row:
                    db.execute("DELETE FROM completions WHERE hash=?", (key,))
            db.execute("DELETE FROM sessions WHERE account=?", (identifier,))
            db.execute("DELETE FROM accounts WHERE id=?", (identifier,))
        return {"deleted": True}
