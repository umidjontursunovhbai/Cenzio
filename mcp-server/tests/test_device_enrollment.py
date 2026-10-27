import base64
import os
import secrets
import sqlite3
from uuid import uuid4

import pytest

from smartspend_mcp.device_enrollment import DeviceEnrollment, EnrollmentLimitError
from smartspend_mcp.sync_auth import GrantStore
from smartspend_mcp.validation import LedgerError


def request(**changes):
    return {"installationId": str(uuid4()), "ledgerId": str(uuid4()),
            "ownerProof": secrets.token_urlsafe(32), "consent": True, **changes}


@pytest.fixture
def setup(tmp_path):
    grants = GrantStore(tmp_path / "grants.sqlite3")
    return grants, DeviceEnrollment(grants, tmp_path)


def test_enrollment_retry_restart_private_hash_only_and_ledger_binding(setup, tmp_path):
    grants, service = setup
    data = request()
    response = service.enroll(data, peer="127.0.0.1")
    assert response["ownership"] == "installation"
    assert grants.verify(response["token"]).ledger_id == data["ledgerId"]
    assert grants.verify(response["token"]).scopes == {"ledger:read", "ledger:write"}
    assert service.enroll(data, peer="127.0.0.1") == response
    assert DeviceEnrollment(grants, tmp_path).enroll(data, peer="127.0.0.1") == response
    assert os.stat(tmp_path / "device-enrollment.key").st_mode & 0o777 == 0o600
    contents = grants.path.read_bytes()
    assert data["ownerProof"].encode() not in contents
    assert response["token"].encode() not in contents
    assert b"127.0.0.1" not in contents
    for changes in ({"ownerProof": secrets.token_urlsafe(32)}, {"ledgerId": str(uuid4())}):
        with pytest.raises(PermissionError):
            service.enroll({**data, **changes}, peer="127.0.0.1")
    with pytest.raises(PermissionError):
        service.enroll(request(ledgerId=data["ledgerId"]), peer="127.0.0.1")


@pytest.mark.parametrize("existing", ["file", "grant", "subject", "symlink"])
def test_cannot_claim_operator_existing_ledger(setup, tmp_path, existing):
    grants, service = setup
    data = request()
    if existing == "file":
        (tmp_path / (data["ledgerId"] + ".sqlite3")).touch()
    elif existing == "symlink":
        (tmp_path / (data["ledgerId"] + ".sqlite3")).symlink_to(tmp_path / "missing")
    elif existing == "grant":
        grants.issue(data["ledgerId"])
    else:
        grants.bind("https://issuer.example", "subject", data["ledgerId"])
    with pytest.raises(PermissionError):
        service.enroll(data, peer="peer")


def test_expiry_rotates_but_retries_remain_stable_and_revocation_sticks(setup, monkeypatch):
    grants, service = setup
    data = request()
    first = service.enroll(data, peer="peer")
    monkeypatch.setattr("smartspend_mcp.device_enrollment.time.time", lambda: first["expiresAt"] + 1)
    second = service.enroll(data, peer="peer")
    assert second["token"] != first["token"]
    assert grants.verify(first["token"]) is None
    assert grants.verify(second["token"]) is not None
    assert service.enroll(data, peer="peer") == second
    grants.revoke(grants.verify(second["token"]).grant_id)
    with pytest.raises(PermissionError):
        service.enroll(data, peer="peer")


def test_last_minute_renewal_rotates_once_instead_of_each_poll(setup, monkeypatch):
    grants, service = setup
    data = request()
    first = service.enroll(data, peer="peer")
    monkeypatch.setattr("smartspend_mcp.device_enrollment.time.time", lambda: first["expiresAt"] - 30)
    renewed = service.enroll(data, peer="peer")
    assert renewed["token"] != first["token"]
    assert renewed["expiresAt"] > first["expiresAt"]
    assert service.enroll(data, peer="peer") == renewed
    assert grants.verify(first["token"]) is None


def test_explicit_revoke_requires_proof_and_does_not_delete_data(setup, tmp_path):
    grants, service = setup
    data = request()
    response = service.enroll(data, peer="peer")
    ledger = tmp_path / (data["ledgerId"] + ".sqlite3")
    ledger.write_text("retained")
    with pytest.raises(PermissionError):
        service.revoke(data["installationId"], secrets.token_urlsafe(32))
    assert grants.verify(response["token"]) is not None
    service.revoke(data["installationId"], data["ownerProof"])
    assert grants.verify(response["token"]) is None
    with pytest.raises(PermissionError):
        service.enroll(data, peer="peer")
    assert ledger.read_text() == "retained"


def test_capacity_does_not_block_existing_owner_and_attempt_quota_persists(setup, tmp_path):
    grants, _ = setup
    service = DeviceEnrollment(grants, tmp_path, max_installations=1, hourly_peer_limit=3)
    data = request()
    response = service.enroll(data, peer="peer")
    with pytest.raises(EnrollmentLimitError):
        service.enroll(request(), peer="peer")
    assert service.enroll(data, peer="peer") == response
    with pytest.raises(EnrollmentLimitError):
        service.enroll(data, peer="peer")
    assert DeviceEnrollment(grants, tmp_path, max_installations=1).enroll(data, peer="other-peer") == response


def test_global_attempt_budget_bounds_peer_database_growth(setup, tmp_path):
    grants, _ = setup
    service = DeviceEnrollment(grants, tmp_path, global_hourly_limit=2)
    data = request()
    service.enroll(data, peer="one")
    service.enroll(data, peer="two")
    with pytest.raises(EnrollmentLimitError):
        service.enroll(data, peer="three")
    with sqlite3.connect(grants.path) as db:
        assert db.execute("SELECT count(*) FROM device_attempts").fetchone()[0] == 2


@pytest.mark.parametrize("changes", [{"consent": False}, {"consent": 1}, {"ownerProof": "short"},
    {"ownerProof": "a" * 42 + "b"}, {"ownerProof": 3}, {"extra": True}, {"ledgerId": "../x"}])
def test_rejects_invalid_enrollment(setup, changes):
    _, service = setup
    with pytest.raises(LedgerError):
        service.enroll(request(**changes), peer="peer")


def test_private_key_symlink_refused(tmp_path):
    grants = GrantStore(tmp_path / "grants.sqlite3")
    target = tmp_path / "target"
    target.write_bytes(secrets.token_bytes(32))
    original_mode = target.stat().st_mode
    (tmp_path / "device-enrollment.key").symlink_to(target)
    with pytest.raises(OSError):
        DeviceEnrollment(grants, tmp_path)
    assert target.stat().st_mode == original_mode


def test_missing_owner_key_never_silently_replaces_existing_identity(setup, tmp_path):
    grants, service = setup
    service.enroll(request(), peer="peer")
    (tmp_path / "device-enrollment.key").unlink()
    with pytest.raises(LedgerError, match="restore"):
        DeviceEnrollment(grants, tmp_path)
    assert not (tmp_path / "device-enrollment.key").exists()


def test_concurrent_new_claim_same_ledger_only_one_owner(setup):
    from concurrent.futures import ThreadPoolExecutor
    _, service = setup
    data = request()
    other = request(ledgerId=data["ledgerId"])
    def attempt(value):
        try:
            return service.enroll(value, peer="peer")
        except PermissionError:
            return None
    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(attempt, [data, other]))
    assert sum(value is not None for value in results) == 1
