from pathlib import Path
from types import SimpleNamespace
import os
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from smartspend_mcp.sync_auth import GrantStore, OAuthVerifier
from smartspend_mcp.validation import LedgerError

LEDGER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"


def test_grants_scopes_revocation_and_permissions(tmp_path):
    store = GrantStore(tmp_path / "auth.sqlite3")
    identifier, token = store.issue(LEDGER, {"ledger:read"})
    assert store.verify(token).ledger_id == LEDGER
    with pytest.raises(PermissionError):
        store.verify(token).require("ledger:write")
    assert store.verify("bad") is None
    assert os.stat(store.path).st_mode & 0o777 == 0o600
    assert token.encode() not in store.path.read_bytes()
    store.revoke(identifier)
    assert store.verify(token) is None
    with pytest.raises(LedgerError):
        store.issue(LEDGER, {"admin"})
    with pytest.raises(LedgerError):
        store.issue("../escape")
    with pytest.raises(LedgerError):
        store.issue(LEDGER, lifetime=0)


def test_grants_refuse_symlink(tmp_path):
    target = tmp_path / "target"
    target.write_text("keep")
    link = tmp_path / "auth"
    link.symlink_to(target)
    with pytest.raises(LedgerError):
        GrantStore(link)
    assert target.read_text() == "keep"


@pytest.fixture
def oauth(tmp_path, monkeypatch):
    grants = GrantStore(tmp_path / "auth.sqlite3")
    # Keep exact issuer, including its trailing slash.
    issuer, resource = "https://identity.example/", "https://sync.example/mcp"
    grants.bind(issuer, "alice", LEDGER, {"ledger:read"})
    verifier = OAuthVerifier(grants, issuer=issuer, resource=resource, jwks_url="https://identity.example/jwks")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(verifier.keys, "get_signing_key_from_jwt", lambda _: SimpleNamespace(key=key.public_key()))
    claims = {"sub":"alice", "iss":issuer, "aud":resource, "iat":int(time.time())-2,
              "exp":int(time.time())+300, "scope":"ledger:read ledger:write", "ledgerId":OTHER}
    return grants, verifier, key, claims


def test_oauth_ledger_is_serverbound_scopes_intersect_and_unbind_revokes(oauth):
    grants, verifier, key, claims = oauth
    token = jwt.encode(claims,key,algorithm="RS256")
    verified = verifier._verify(token)
    assert verified is not None
    assert verified.claims["ledgerId"] == LEDGER
    assert verified.scopes == ["ledger:read"]
    grants.unbind(verifier.issuer, "alice")
    assert verifier._verify(token) is None


@pytest.mark.parametrize("changes", [{"aud":"https://evil.example/mcp"}, {"iss":"https://identity.example"},
    {"exp":1}, {"iat":int(time.time())+600}, {"sub":"mallory"}, {"scope":"ledger:write"}, {"scope":["ledger:read"]}])
def test_oauth_rejects_invalid_claims(oauth,changes):
    _, verifier, key, claims = oauth
    assert verifier._verify(jwt.encode({**claims,**changes},key,algorithm="RS256")) is None


def test_oauth_requires_verified_signature(oauth):
    _, verifier, _, claims = oauth
    other = rsa.generate_private_key(public_exponent=65537,key_size=2048)
    assert verifier._verify(jwt.encode(claims,other,algorithm="RS256")) is None
    assert verifier._verify(jwt.encode(claims,"not-a-real-secret",algorithm="HS256")) is None
    assert verifier._verify("not-a-token") is None
