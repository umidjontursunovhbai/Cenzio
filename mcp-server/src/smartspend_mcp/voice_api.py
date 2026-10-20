"""Single-owner private phone gateway. Loopback only; TLS via Tailscale Serve.

No ledger access. Audio, provider keys and financial history are not accepted.
Device credentials/pairing/usage counters are persisted; draft text is not.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
from collections import OrderedDict
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .ai_config import AIConfig
from .interpreter import interpret, make_payload
from .validation import LedgerError


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class DeviceStore:
    def __init__(self, path: Path):
        if path.is_symlink():
            raise LedgerError("Voice state must not be a symlink")
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = path
        with self.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS pairing (id INTEGER PRIMARY KEY CHECK(id=1), hash TEXT, expires REAL, attempts INTEGER);
                CREATE TABLE IF NOT EXISTS devices (hash TEXT PRIMARY KEY, created REAL);
                CREATE TABLE IF NOT EXISTS calls (at REAL NOT NULL, device TEXT NOT NULL);
            """)
        os.chmod(path, 0o600)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=5)
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def issue_code(self) -> str:
        # Public Funnel has no tailnet identity gate: use 192 bits of entropy.
        code = secrets.token_urlsafe(24)
        with self.connection() as db:
            db.execute("INSERT OR REPLACE INTO pairing VALUES (1,?,?,0)", (digest(code), time.time() + 600))
        return code

    def pair(self, code: str) -> str | None:
        with self.connection() as db:
            row = db.execute("SELECT hash,expires,attempts FROM pairing WHERE id=1").fetchone()
            if not row or row[1] < time.time() or row[2] >= 5:
                return None
            # Attempts must commit even when the provided code is wrong.
            db.execute("UPDATE pairing SET attempts=attempts+1 WHERE id=1")
            if not secrets.compare_digest(digest(code), row[0]):
                return None
            if db.execute("SELECT count(*) FROM devices").fetchone()[0] >= 5:
                return None
            token = secrets.token_urlsafe(32)
            db.execute("INSERT INTO devices VALUES (?,?)", (digest(token), time.time()))
            db.execute("DELETE FROM pairing")
            return token

    def authorized(self, token: str) -> str | None:
        if not re.fullmatch(r"[A-Za-z0-9_-]{40,100}", token):
            return None
        hashed = digest(token)
        with self.connection() as db:
            return hashed if db.execute("SELECT 1 FROM devices WHERE hash=?", (hashed,)).fetchone() else None

    def revoke(self, hashed: str) -> None:
        with self.connection() as db:
            db.execute("DELETE FROM devices WHERE hash=?", (hashed,))

    def reserve_call(self, hashed: str) -> bool:
        now = time.time()
        day_start = now - now % 86400
        with self.connection() as db:
            db.execute("DELETE FROM calls WHERE at<?", (min(day_start, now - 60),))
            daily = db.execute("SELECT count(*) FROM calls WHERE at>=?", (day_start,)).fetchone()[0]
            minute = db.execute("SELECT count(*) FROM calls WHERE at>?", (now - 60,)).fetchone()[0]
            if daily >= 100 or minute >= 10:
                return False
            db.execute("INSERT INTO calls VALUES (?,?)", (now, hashed))
            return True


class VoiceRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    request_id: str
    transcript: str = Field(min_length=1, max_length=4000)
    categories: list[dict[str, Any]] = Field(max_length=100)
    currency: str
    reference_date: str
    time_zone: str
    consent: Literal[True]


def create_app(config: AIConfig, state: DeviceStore, *, inference=interpret, allowed_hosts: list[str] | None = None) -> Starlette:
    lock = asyncio.Lock()
    cache: OrderedDict[tuple[str, str], tuple[float, str, dict[str, Any]]] = OrderedDict()
    # Pairing attempts are additionally bounded before JSON parsing.
    pair_attempts: list[float] = []

    def reply(data: dict, status=200):
        return JSONResponse(data, status_code=status, headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})

    async def body(request: Request) -> Any:
        if request.headers.get("content-type", "").split(";")[0] != "application/json":
            raise LedgerError("Expected JSON")
        if request.headers.get("content-encoding", "identity") != "identity":
            raise LedgerError("Compressed input is not accepted")
        data = bytearray()
        try:
            async with asyncio.timeout(10):
                async for chunk in request.stream():
                    data.extend(chunk)
                    if len(data) > 65536:
                        raise LedgerError("Input is too large")
        except TimeoutError:
            raise LedgerError("Input timed out") from None
        return json.loads(data)

    def auth(request: Request) -> str | None:
        value = request.headers.get("authorization", "")
        return state.authorized(value[7:]) if value.startswith("Bearer ") else None

    async def health(request):
        return reply({"status": "ok", "service": "smartspend-voice", "version": 1})

    async def pair(request):
        now = time.monotonic()
        pair_attempts[:] = [at for at in pair_attempts if now - at < 60]
        if len(pair_attempts) >= 5:
            return reply({"error": "pairing_rate_limited"}, 429)
        pair_attempts.append(now)
        try:
            data = await body(request)
            if not isinstance(data, dict) or set(data) != {"code"} or not isinstance(data["code"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", data["code"]):
                raise LedgerError("Invalid pairing request")
            token = state.pair(data["code"])
            if not token:
                return reply({"error": "invalid_or_expired_code"}, 401)
            return reply({"token": token})
        except (LedgerError, ValueError, TypeError):
            return reply({"error": "invalid_pairing_request"}, 400)

    async def disconnect(request):
        hashed = auth(request)
        if not hashed:
            return reply({"error": "unauthorized"}, 401)
        state.revoke(hashed)
        for key in list(cache):
            if key[0] == hashed:
                cache.pop(key)
        return reply({"disconnected": True})

    async def draft(request):
        hashed = auth(request)
        if not hashed:
            return reply({"error": "unauthorized"}, 401)
        try:
            incoming = VoiceRequest.model_validate(await body(request))
            if incoming.consent is not True or str(UUID(incoming.request_id)) != incoming.request_id:
                raise LedgerError("Explicit consent and canonical request UUID are required")
            args = {"config": config, "categories": incoming.categories, "currency": incoming.currency, "reference_date": incoming.reference_date, "time_zone": incoming.time_zone}
            payload, _ = make_payload(incoming.transcript, **args)
            request_hash = digest(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
        except (LedgerError, ValidationError, ValueError, TypeError):
            return reply({"error": "invalid_input"}, 400)
        now = time.monotonic()
        for key in list(cache):
            if now - cache[key][0] > 300:
                cache.pop(key)
        key = (hashed, incoming.request_id)
        if key in cache:
            prior = cache[key]
            return reply(prior[2]) if prior[1] == request_hash else reply({"error": "request_id_conflict"}, 409)
        if lock.locked():
            return reply({"error": "busy", "message": "Another draft is processing. Retry shortly."}, 429)
        async with lock:
            if not state.reserve_call(hashed):
                return reply({"error": "usage_limit", "message": "Private preview limit reached: 10 requests/minute, 100/day."}, 429)
            try:
                # Synchronous provider client runs off the ASGI loop. No ledger is opened.
                result = await asyncio.to_thread(inference, incoming.transcript, **args)
                cached_at = time.monotonic()
                cache[key] = (cached_at, request_hash, result)
                def expire():
                    if key in cache and cache[key][0] == cached_at:
                        cache.pop(key, None)
                asyncio.get_running_loop().call_later(300, expire)
                while len(cache) > 32:
                    cache.popitem(last=False)
                return reply(result)
            except LedgerError:
                return reply({"error": "provider_failed", "message": "AI could not prepare a draft. Nothing was saved. Retry explicitly."}, 502)

    return Starlette(routes=[Route("/health", health), Route("/v1/pair", pair, methods=["POST"]), Route("/v1/device", disconnect, methods=["DELETE"]), Route("/v1/drafts", draft, methods=["POST"])], middleware=[Middleware(TrustedHostMiddleware, allowed_hosts=allowed_hosts or ["127.0.0.1", "localhost", "ubuntu.onca-albacore.ts.net"])])


def main():
    parser = argparse.ArgumentParser(description="Private phone voice gateway; no public HTTP binding or ledger access")
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--config", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--port", type=int, default=18769)
    commands.add_parser("pair-code", help="Owner only: issue a one-use 10-minute code; do not log or publish the output")
    commands.add_parser("revoke-all", help="Owner only: disconnect every paired phone")
    args = parser.parse_args()
    state = DeviceStore(args.state)
    if args.command == "pair-code":
        print(json.dumps({"code": state.issue_code(), "expires_in_seconds": 600}))
    elif args.command == "revoke-all":
        with state.connection() as db:
            db.execute("DELETE FROM devices")
            db.execute("DELETE FROM pairing")
        print("All phone connections revoked.")
    else:
        if not args.config or not 1024 <= args.port <= 65535:
            parser.error("serve requires --config and an unprivileged port")
        import uvicorn
        app = create_app(AIConfig.from_private_file(args.config), state)
        uvicorn.run(app, host="127.0.0.1", port=args.port, workers=1, access_log=False, log_level="warning", proxy_headers=False, timeout_keep_alive=5, limit_concurrency=12)


if __name__ == "__main__":
    main()
