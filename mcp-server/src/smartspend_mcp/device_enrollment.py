"""Explicitly enabled installation ownership, not a cross-device user account.

The app keeps a random owner proof in its Keychain. A ledger UUID alone is never
authorization. Existing operator-created ledgers cannot be claimed by signup.
Public deployment still requires an operator's edge abuse/attestation policy.
"""
from __future__ import annotations

import base64
from contextlib import closing
import hashlib
import hmac
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import time

from .sync_auth import GrantStore, SCOPES
from .validation import LedgerError, uuid_text


class EnrollmentLimitError(LedgerError):
    pass


class DeviceEnrollment:
    LIFETIME = 86400 * 30

    def __init__(self, grants: GrantStore, root: Path, *, max_installations=1000,
                 daily_limit=100, hourly_peer_limit=30, global_hourly_limit=3000):
        self.grants, self.root = grants, root
        self.max_installations = max_installations
        self.daily_limit, self.hourly_peer_limit = daily_limit, hourly_peer_limit
        self.global_hourly_limit = global_hourly_limit
        key_path = root / "device-enrollment.key"
        if not os.path.lexists(key_path):
            with closing(sqlite3.connect(grants.path)) as db:
                table = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='device_installations'").fetchone()
                if table and db.execute("SELECT 1 FROM device_installations LIMIT 1").fetchone():
                    raise LedgerError("Enrollment key is missing; restore the private server backup")
        try:
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, "wb") as handle:
                handle.write(secrets.token_bytes(32))
                handle.flush()
                os.fsync(handle.fileno())
        fd = os.open(key_path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise LedgerError("Enrollment key must be a private owner file")
            self.key = handle.read(33)
        if len(self.key) != 32:
            raise LedgerError("Invalid enrollment key")
        with closing(sqlite3.connect(grants.path)) as db, db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS device_installations(
                id TEXT PRIMARY KEY, proof_hash TEXT NOT NULL,
                ledger TEXT UNIQUE NOT NULL, generation INTEGER NOT NULL,
                grant_id TEXT NOT NULL, created INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS device_attempts(peer TEXT, bucket INTEGER, count INTEGER,
                PRIMARY KEY(peer,bucket));
            """)

    def _proof(self, value):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", value):
            raise LedgerError("A random 256-bit installation proof is required")
        try:
            decoded = base64.urlsafe_b64decode(value + "=")
        except ValueError:
            raise LedgerError("Invalid installation proof") from None
        if len(decoded) != 32 or base64.urlsafe_b64encode(decoded).decode().rstrip("=") != value:
            raise LedgerError("Invalid installation proof")
        return hmac.new(self.key, value.encode(), hashlib.sha256).hexdigest()

    def _token(self, identifier, proof, generation):
        message = f"session:{identifier}:{generation}:{proof}".encode()
        return base64.urlsafe_b64encode(hmac.new(self.key, message, hashlib.sha256).digest()).decode().rstrip("=")

    def enroll(self, data, *, peer: str):
        """First claim or durable retry/renewal; caller must cap HTTP body size.

        Use the direct network peer, never an untrusted X-Forwarded-For header.
        An operator revoking the current grant also disables further renewal.
        """
        if not isinstance(data, dict) or set(data) != {"installationId", "ownerProof", "ledgerId", "consent"} or data["consent"] is not True:
            raise LedgerError("Explicit installation enrollment consent is required")
        identifier, ledger = uuid_text(data["installationId"]), uuid_text(data["ledgerId"])
        proof_hash = self._proof(data["ownerProof"])
        if not isinstance(peer, str) or not 1 <= len(peer) <= 200:
            raise LedgerError("A bounded network peer is required")
        now = int(time.time())
        bucket = now // 3600
        peer_hash = hmac.new(self.key, peer.encode(), hashlib.sha256).hexdigest()
        # Commit the quota separately so failed ownership guesses still count.
        with closing(sqlite3.connect(self.grants.path)) as db, db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM device_attempts WHERE bucket<?", (bucket - 1,))
            attempts = db.execute("SELECT coalesce(sum(count),0) FROM device_attempts WHERE bucket=?", (bucket,)).fetchone()[0]
            if attempts >= self.global_hourly_limit:
                raise EnrollmentLimitError("Installation enrollment is rate limited")
            db.execute("INSERT INTO device_attempts VALUES(?,?,1) ON CONFLICT(peer,bucket) DO UPDATE SET count=count+1", (peer_hash, bucket))
            count = db.execute("SELECT count FROM device_attempts WHERE peer=? AND bucket=?", (peer_hash, bucket)).fetchone()[0]
        if count > self.hourly_peer_limit:
            raise EnrollmentLimitError("Installation enrollment is rate limited")
        with closing(sqlite3.connect(self.grants.path)) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT proof_hash,ledger,generation,grant_id,revoked FROM device_installations WHERE id=?", (identifier,)).fetchone()
            if row:
                if not hmac.compare_digest(row[0], proof_hash) or row[1] != ledger or row[4]:
                    raise PermissionError("installation_ownership_required")
                generation, grant_id = row[2], row[3]
                grant = db.execute("SELECT expires FROM grants WHERE id=?", (grant_id,)).fetchone()
                if grant is None:
                    raise PermissionError("installation_revoked")
                expires = grant[0]
                # The app refreshes during the last minute. Rotate once here,
                # rather than returning a nearly-expired token every poll and
                # consuming the shared proxy's enrollment attempt quota.
                if expires <= now + 60:
                    db.execute("DELETE FROM grants WHERE id=?", (grant_id,))
                    generation += 1
                    grant_id, expires = self._issue(db, identifier, data["ownerProof"], ledger, generation, now)
                    db.execute("UPDATE device_installations SET generation=?,grant_id=? WHERE id=?", (generation, grant_id, identifier))
            else:
                # Never reinterpret an existing ledger as owned by a new device.
                if os.path.lexists(self.root / (ledger + ".sqlite3")) or db.execute("SELECT 1 FROM grants WHERE ledger=?", (ledger,)).fetchone() or db.execute("SELECT 1 FROM subjects WHERE ledger=?", (ledger,)).fetchone() or db.execute("SELECT 1 FROM device_installations WHERE ledger=?", (ledger,)).fetchone():
                    raise PermissionError("installation_ownership_required")
                total = db.execute("SELECT count(*) FROM device_installations").fetchone()[0]
                daily = db.execute("SELECT count(*) FROM device_installations WHERE created>=?", (now - 86400,)).fetchone()[0]
                if total >= self.max_installations or daily >= self.daily_limit:
                    raise EnrollmentLimitError("Installation enrollment capacity reached")
                generation = 1
                grant_id, expires = self._issue(db, identifier, data["ownerProof"], ledger, generation, now)
                db.execute("INSERT INTO device_installations VALUES(?,?,?,?,?,?,0)", (identifier, proof_hash, ledger, generation, grant_id, now))
            return {"ledgerId": ledger, "token": self._token(identifier, data["ownerProof"], generation),
                    "expiresAt": expires, "ownership": "installation"}

    def _issue(self, db, identifier, proof, ledger, generation, now):
        token = self._token(identifier, proof, generation)
        grant_id, expires = secrets.token_hex(16), now + self.LIFETIME
        db.execute("INSERT INTO grants VALUES(?,?,?,?,?)", (grant_id, hashlib.sha256(token.encode()).hexdigest(), ledger,
                    GrantStore.scope_text(SCOPES), expires))
        return grant_id, expires

    def revoke(self, identifier: str, proof: str):
        identifier, proof_hash = uuid_text(identifier), self._proof(proof)
        with closing(sqlite3.connect(self.grants.path)) as db, db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT proof_hash,grant_id FROM device_installations WHERE id=?", (identifier,)).fetchone()
            if not row or not hmac.compare_digest(row[0], proof_hash):
                raise PermissionError("installation_ownership_required")
            db.execute("DELETE FROM grants WHERE id=?", (row[1],))
            db.execute("UPDATE device_installations SET revoked=1 WHERE id=?", (identifier,))
