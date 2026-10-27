"""Pinned OIDC identity adapters. No access tokens are retained.

The account service owns one-time state, nonce and PKCE transactions and must
encrypt the Apple refresh credential needed for account-deletion revocation.
Identity is (provider, subject), NEVER email. Connector OAuth is separate.
Sources: developers.google.com/identity/openid-connect/openid-connect,
appleid.apple.com/.well-known/openid-configuration,
core.telegram.org/bots/telegram-login. Telegram uses its default RS256 setting.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hmac
import json
import os
from pathlib import Path
import stat
import threading
import time
from urllib.parse import urlencode

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import httpx
import jwt


class IdentityProviderError(ValueError):
    """Safe to surface: never contains provider response bodies or credentials."""


@dataclass(frozen=True)
class VerifiedIdentity:
    provider: str
    subject: str
    email: str | None = None
    email_verified: bool = False
    display_name: str | None = None
    # Internal credential custody only. Account core must encrypt at rest and
    # serialize public profile fields explicitly, never dataclasses.asdict().
    revocation_token: str | None = field(default=None, repr=False, compare=False)


_ENDPOINTS = {
    "google": ("https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token",
               "https://www.googleapis.com/oauth2/v3/certs", ("https://accounts.google.com", "accounts.google.com")),
    "apple": ("https://appleid.apple.com/auth/authorize", "https://appleid.apple.com/auth/token",
              "https://appleid.apple.com/auth/keys", ("https://appleid.apple.com",)),
    "telegram": ("https://oauth.telegram.org/auth", "https://oauth.telegram.org/token",
                 "https://oauth.telegram.org/.well-known/jwks.json", ("https://oauth.telegram.org",)),
}


def _text(value, limit=8192):
    return isinstance(value, str) and 0 < len(value) <= limit and not any(ord(c) < 32 for c in value)


class OIDCProvider:
    def __init__(self, provider, client_id, client_secret=None, *, team_id=None, key_id=None,
                 private_key=None, httpx_client=None):
        if provider not in _ENDPOINTS or not _text(client_id, 300):
            raise IdentityProviderError("Invalid identity provider configuration")
        if provider == "apple":
            if not _text(team_id, 100) or not _text(key_id, 100) or not isinstance(private_key, str):
                raise IdentityProviderError("Apple signing configuration is required")
            try:
                parsed = serialization.load_pem_private_key(private_key.encode(), password=None)
                if not isinstance(parsed, ec.EllipticCurvePrivateKey) or not isinstance(parsed.curve, ec.SECP256R1):
                    raise ValueError()
            except (ValueError, TypeError):
                raise IdentityProviderError("Invalid Apple signing key") from None
        elif not _text(client_secret):
            raise IdentityProviderError("Identity client secret is required")
        self.provider, self.client_id = provider, client_id
        self._secret, self._team, self._key_id, self._private_key = client_secret, team_id, key_id, private_key
        self.authorization_endpoint, self._token_endpoint, self._jwks_endpoint, self._issuers = _ENDPOINTS[provider]
        self._owns_client = httpx_client is None
        self._http = httpx_client or httpx.Client(timeout=10, follow_redirects=False)
        self._lock = threading.Lock()
        self._keys, self._keys_at = [], 0.0

    def close(self):
        if self._owns_client:
            self._http.close()

    def authorization_url(self, *, state, nonce, redirect_uri, code_challenge):
        params = {"client_id": self.client_id, "redirect_uri": redirect_uri, "response_type": "code",
                  "state": state, "nonce": nonce}
        if self.provider == "apple":
            # Apple requires form_post when requesting email/name. Native name
            # payload is not trusted as identity; only signed claims are used.
            params.update(scope="openid email name", response_mode="form_post")
        else:
            params.update(scope="openid email profile" if self.provider == "google" else "openid profile",
                          code_challenge=code_challenge, code_challenge_method="S256")
        return self.authorization_endpoint + "?" + urlencode(params)

    def _client_secret(self):
        if self.provider != "apple":
            return self._secret
        now = int(time.time())
        return jwt.encode({"iss": self._team, "iat": now, "exp": now + 300,
                           "aud": "https://appleid.apple.com", "sub": self.client_id},
                          self._private_key, algorithm="ES256", headers={"kid": self._key_id})

    @staticmethod
    def _json(response):
        if response.status_code != 200 or len(response.content) > 65536:
            raise IdentityProviderError("Identity provider request failed")
        try:
            body = response.json()
            if not isinstance(body, dict):
                raise ValueError()
            return body
        except ValueError:
            raise IdentityProviderError("Invalid identity provider response") from None

    def _signing_key(self, kid):
        with self._lock:
            age = time.monotonic() - self._keys_at
            matches = [key for key in self._keys if key.get("kid") == kid]
            # Rotate on a previously unseen kid, but bound hostile kid refreshes.
            if not self._keys or age >= 300 or (not matches and age >= 30):
                body = self._json(self._http.get(self._jwks_endpoint, timeout=10, follow_redirects=False))
                keys = body.get("keys")
                if not isinstance(keys, list) or not 1 <= len(keys) <= 50 or not all(isinstance(k, dict) for k in keys):
                    raise IdentityProviderError("Invalid identity signing keys")
                self._keys, self._keys_at = keys, time.monotonic()
                matches = [key for key in keys if key.get("kid") == kid]
            if len(matches) != 1:
                raise IdentityProviderError("Unknown identity signing key")
            key = matches[0]
            if key.get("kty") != "RSA" or key.get("use", "sig") != "sig" or key.get("alg", "RS256") != "RS256":
                raise IdentityProviderError("Unsupported identity signing key")
            if "key_ops" in key and "verify" not in key["key_ops"]:
                raise IdentityProviderError("Invalid identity signing key usage")
            return jwt.PyJWK.from_dict(key, algorithm="RS256").key

    def verify_id_token(self, token, *, nonce):
        """Verify only against this adapter's pinned keys, issuer and audience."""
        try:
            if not _text(token, 16384) or not _text(nonce, 256):
                raise ValueError()
            header = jwt.get_unverified_header(token)
            if header.get("alg") != "RS256" or not _text(header.get("kid"), 256) or header.get("crit"):
                raise ValueError()
            claims = jwt.decode(token, self._signing_key(header["kid"]), algorithms=["RS256"],
                                audience=self.client_id, issuer=self._issuers,
                                options={"require": ["iss", "aud", "sub", "exp", "iat", "nonce"]})
            if not _text(claims["sub"], 255) or not isinstance(claims["nonce"], str) or not hmac.compare_digest(claims["nonce"], nonce):
                raise ValueError()
            if claims.get("azp", self.client_id) != self.client_id:
                raise ValueError()
            if isinstance(claims["aud"], list) and len(claims["aud"]) > 1 and claims.get("azp") != self.client_id:
                raise ValueError()
            # Provider email and name are optional metadata, never account keys.
            email = claims.get("email") if _text(claims.get("email"), 320) else None
            verified = claims.get("email_verified") is True or claims.get("email_verified") == "true"
            name = claims.get("name") if _text(claims.get("name"), 300) else None
            return VerifiedIdentity(self.provider, claims["sub"], email, bool(email and verified), name)
        except (jwt.PyJWTError, httpx.HTTPError, ValueError, TypeError, KeyError):
            raise IdentityProviderError("Identity verification failed") from None

    def exchange(self, *, code, redirect_uri, nonce, code_verifier):
        if not _text(code, 4096):
            raise IdentityProviderError("Invalid identity authorization code")
        try:
            data = {"grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
                    "client_id": self.client_id}
            auth = None
            if self.provider == "telegram":
                auth = httpx.BasicAuth(self.client_id, self._secret)
            else:
                data["client_secret"] = self._client_secret()
            if self.provider != "apple":
                data["code_verifier"] = code_verifier
            result = self._json(self._http.post(self._token_endpoint, data=data, auth=auth, timeout=10,
                                                follow_redirects=False))
            identity = self.verify_id_token(result.get("id_token"), nonce=nonce)
            if self.provider == "apple":
                refresh = result.get("refresh_token")
                if not _text(refresh, 8192):
                    raise IdentityProviderError("Apple revocation credential is missing")
                return VerifiedIdentity(identity.provider, identity.subject, identity.email,
                                        identity.email_verified, identity.display_name, refresh)
            return identity
        except (httpx.HTTPError, jwt.PyJWTError, ValueError, TypeError):
            raise IdentityProviderError("Identity sign-in failed") from None

    def revoke(self, refresh_token):
        """Apple account deletion must revoke before erasing its credential.

        Non-200/unknown outcomes raise; account core retains encrypted token for
        retry and must not report that the provider grant was revoked.
        """
        if self.provider != "apple" or not _text(refresh_token, 8192):
            raise IdentityProviderError("Unsupported identity revocation")
        try:
            response = self._http.post("https://appleid.apple.com/auth/revoke", data={
                "client_id": self.client_id, "client_secret": self._client_secret(),
                "token": refresh_token, "token_type_hint": "refresh_token"}, timeout=10,
                follow_redirects=False)
            if response.status_code != 200:
                raise IdentityProviderError("Identity revocation failed")
        except (httpx.HTTPError, jwt.PyJWTError, ValueError, TypeError):
            raise IdentityProviderError("Identity revocation failed") from None


def load_identity_providers(private_file):
    """Read optional provider entries from one bounded owner-only 0600 JSON file.

    {"google":{"client_id":...,"client_secret":...},
     "apple":{"client_id":...,"team_id":...,"key_id":...,"private_key":PEM},
     "telegram":{"client_id":...,"client_secret":...}}
    An omitted provider is unavailable; incomplete/malformed entries fail startup.
    """
    fd = None
    providers = {}
    try:
        fd = os.open(Path(private_file).expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536:
            raise ValueError()
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            fd = None
            raw = stream.read(65537)
        if len(raw.encode()) > 65536:
            raise ValueError()
        config = json.loads(raw)
        if not isinstance(config, dict) or not set(config) <= set(_ENDPOINTS):
            raise ValueError()
        for name, values in config.items():
            fields = {"client_id", "team_id", "key_id", "private_key"} if name == "apple" else {"client_id", "client_secret"}
            if not isinstance(values, dict) or set(values) != fields:
                raise ValueError()
            providers[name] = OIDCProvider(name, **values)
        return providers
    except (OSError, ValueError, TypeError):
        for provider in providers.values():
            provider.close()
        raise IdentityProviderError("Invalid private identity provider configuration (requires owner-only 0600 JSON)") from None
    finally:
        if fd is not None:
            os.close(fd)
