"""Bounded account-only HTTP endpoints, separate from ledger authentication."""
import asyncio
import json
from urllib.parse import parse_qsl

from starlette.responses import JSONResponse, RedirectResponse
from starlette.routing import Route

from .account_auth import AccountAuthError, AccountRateLimitError, AccountDeletionError, PROVIDERS


def account_routes(service):
    headers = {"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"}

    def reply(value, status=200):
        return JSONResponse(value, status_code=status, headers=headers)

    async def payload(request):
        data = bytearray()
        async with asyncio.timeout(10):
            async for chunk in request.stream():
                data.extend(chunk)
                if len(data) > 16384:
                    raise AccountAuthError("Account request too large")
        return bytes(data)

    async def handle(request):
        action = request.path_params["action"]
        if action == "providers" and request.method == "GET":
            return reply(service.availability() if service else {"providers": [{"id": p, "available": False} for p in PROVIDERS]})
        if service is None:
            return reply({"error": "account_sign_in_unavailable"}, 503)
        try:
            if action in {"start", "exchange"} and request.method == "POST":
                if request.headers.get("content-type", "").split(";")[0] != "application/json" or request.headers.get("content-encoding", "identity") != "identity":
                    raise AccountAuthError("Expected JSON")
                value = json.loads(await payload(request))
                if action == "start":
                    peer = request.client.host if request.client else "unknown"
                    result = await asyncio.to_thread(service.start, value, peer=peer)
                else:
                    result = await asyncio.to_thread(service.exchange, value)
                return reply(result)
            header = request.headers.get("authorization", "")
            token = header[7:] if header.startswith("Bearer ") else ""
            if action == "me" and request.method in {"GET", "DELETE"}:
                return reply(await asyncio.to_thread(service.delete if request.method == "DELETE" else service.current, token))
            if action == "logout" and request.method == "POST":
                return reply(await asyncio.to_thread(service.logout, token))
            return reply({"error": "not_found"}, 404)
        except AccountRateLimitError:
            return reply({"error": "sign_in_rate_limited"}, 429)
        except AccountDeletionError:
            return reply({"error": "account_deletion_unavailable"}, 503)
        except PermissionError:
            return reply({"error": "unauthorized"}, 401)
        except (ValueError, TypeError, KeyError, TimeoutError):
            return reply({"error": "invalid_sign_in_request"}, 400)

    async def callback(request):
        if service is None:
            return reply({"error": "account_sign_in_unavailable"}, 503)
        try:
            if request.method == "POST":
                if request.headers.get("content-type", "").split(";")[0] != "application/x-www-form-urlencoded":
                    raise AccountAuthError("Expected OAuth callback")
                pairs = parse_qsl((await payload(request)).decode(), max_num_fields=20)
            else:
                if len(request.url.query) > 16384:
                    raise AccountAuthError("Callback too large")
                pairs = list(request.query_params.multi_items())
            if len({key for key, _ in pairs}) != len(pairs):
                raise AccountAuthError("Ambiguous OAuth callback")
            destination = await asyncio.to_thread(service.callback, request.path_params["provider"], dict(pairs))
            return RedirectResponse(destination, status_code=303, headers=headers)
        except (ValueError, TypeError, KeyError, TimeoutError):
            return reply({"error": "invalid_sign_in_callback"}, 400)

    return [Route("/v1/account/{action}", handle, methods=["GET", "POST", "DELETE"]),
            Route("/oauth/account/{provider}/callback", callback, methods=["GET", "POST"])]
