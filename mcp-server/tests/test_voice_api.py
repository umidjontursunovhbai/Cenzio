from __future__ import annotations

import json
import time
from pathlib import Path
from uuid import uuid4

import pytest
from starlette.testclient import TestClient

from smartspend_mcp.ai_config import AIConfig
from smartspend_mcp.validation import LedgerError
from smartspend_mcp.voice_api import DeviceStore, create_app

FAKE_CONFIG = AIConfig(api_key="sk-or-v1-" + "synthetic_test_only_" * 3)


@pytest.fixture
def gateway(tmp_path):
    state = DeviceStore(tmp_path / "voice.sqlite3")
    calls = []

    def inference(text, **kwargs):
        calls.append((text, kwargs))
        return {"transactions": [], "unresolved_fields": ["missing amount"], "saved": False, "requires_review": True}

    with TestClient(create_app(FAKE_CONFIG, state, inference=inference, allowed_hosts=["testserver"])) as client:
        yield state, client, calls


def pairing(state, client):
    code = state.issue_code()
    result = client.post("/v1/pair", json={"code": code})
    assert result.status_code == 200
    return {"Authorization": "Bearer " + result.json()["token"]}


def request_body(**changes):
    return {"request_id": str(uuid4()), "transcript": "coffee", "categories": [], "currency": "UZS", "reference_date": "2026-10-20", "time_zone": "Asia/Tashkent", "consent": True, **changes}


def test_no_anonymous_calls_no_credential_in_health(gateway):
    _, client, calls = gateway
    assert client.post("/v1/drafts", json=request_body()).status_code == 401
    assert client.get("/health").json()["status"] == "ok"
    assert FAKE_CONFIG.api_key not in client.get("/health").text
    assert not calls


def test_pairing_single_use_token_hashed_and_revoked(gateway):
    state, client, _ = gateway
    code = state.issue_code()
    assert len(code) == 32
    assert client.post("/v1/pair", json={"code": "12345678"}).status_code == 400
    result = client.post("/v1/pair", json={"code": code})
    token = result.json()["token"]
    assert client.post("/v1/pair", json={"code": code}).status_code == 401
    assert token.encode() not in state.path.read_bytes()
    assert code.encode() not in state.path.read_bytes()
    headers = {"Authorization": "Bearer " + token}
    assert client.delete("/v1/device", headers=headers).status_code == 200
    assert client.post("/v1/drafts", headers=headers, json=request_body()).status_code == 401


def test_pairing_expires_and_failed_attempts_persist(gateway):
    state, _, _ = gateway
    code = state.issue_code()
    for _ in range(5):
        assert state.pair("wrong") is None
    assert state.pair(code) is None
    code = state.issue_code()
    with state.connection() as db:
        db.execute("UPDATE pairing SET expires=?", (time.time() - 1,))
    assert state.pair(code) is None


def test_drafts_require_consent_and_do_not_receive_history(gateway):
    state, client, calls = gateway
    headers = pairing(state, client)
    body = request_body()
    result = client.post("/v1/drafts", headers=headers, json=body)
    assert result.status_code == 200 and result.json()["saved"] is False
    assert len(calls) == 1 and "expenses" not in calls[0][1]
    assert result.headers["cache-control"] == "no-store"
    assert client.post("/v1/drafts", headers=headers, json={**body, "consent": False}).status_code == 400


def test_idempotent_retry_no_extra_provider_charge_and_conflicting_id_fails(gateway):
    state, client, calls = gateway
    headers = pairing(state, client)
    body = request_body()
    first = client.post("/v1/drafts", headers=headers, json=body)
    assert client.post("/v1/drafts", headers=headers, json=body).json() == first.json()
    assert len(calls) == 1
    assert client.post("/v1/drafts", headers=headers, json={**body, "transcript": "lunch"}).status_code == 409


@pytest.mark.parametrize("changes", [{"request_id": "bad"}, {"transcript": "x" * 4001}, {"currency": "BTC"}, {"consent": False}, {"expenses": []}, {"audio": "base64"}, {"reference_date": "yesterday"}])
def test_invalid_or_excess_data_not_sent(gateway, changes):
    state, client, calls = gateway
    headers = pairing(state, client)
    assert client.post("/v1/drafts", headers=headers, json=request_body(**changes)).status_code == 400
    assert not calls


def test_limit_per_minute_and_host_validation(gateway):
    state, client, calls = gateway
    headers = pairing(state, client)
    for _ in range(10):
        assert client.post("/v1/drafts", headers=headers, json=request_body()).status_code == 200
    assert client.post("/v1/drafts", headers=headers, json=request_body()).status_code == 429
    assert len(calls) == 10
    assert client.get("/health", headers={"Host": "attacker.invalid"}).status_code == 400


def test_provider_errors_never_reveal_key_or_transcript(tmp_path):
    state = DeviceStore(tmp_path / "voice.sqlite3")

    def fail(*args, **kwargs):
        raise LedgerError(FAKE_CONFIG.api_key)

    with TestClient(create_app(FAKE_CONFIG, state, inference=fail, allowed_hosts=["testserver"])) as client:
        headers = pairing(state, client)
        response = client.post("/v1/drafts", headers=headers, json=request_body())
        assert response.status_code == 502
        assert FAKE_CONFIG.api_key not in response.text


def test_oversized_and_compressed_input_rejected(gateway):
    state, client, calls = gateway
    headers = pairing(state, client)
    response = client.post("/v1/drafts", headers={**headers, "Content-Type": "application/json"}, content=b"x" * 65537)
    assert response.status_code == 400
    response = client.post("/v1/drafts", headers={**headers, "Content-Encoding": "gzip"}, json=request_body())
    assert response.status_code == 400 and not calls


def test_rate_limit_survives_midnight(gateway, monkeypatch):
    import smartspend_mcp.voice_api as api

    state, _, _ = gateway
    clock = [86400 * 20000 - 10]
    monkeypatch.setattr(api.time, "time", lambda: clock[0])
    for _ in range(10):
        assert state.reserve_call("synthetic-device")
    clock[0] += 20
    assert not state.reserve_call("synthetic-device")
