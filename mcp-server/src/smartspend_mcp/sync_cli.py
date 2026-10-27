"""Owner-only provisioning, backups, and explicitly selected connector polls.

Never pass bearer/provider tokens on command lines. create-token writes an
exclusive private file; connector credentials are read only from an owner-owned
0600 regular file. The HTTPS reverse proxy and upstream OAuth AS remain operator
configuration; this command does not deploy, register OAuth apps or expose ports.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import warnings
from threading import Event

import httpx
import uvicorn

from .connector_sync import reconcile, resolve_conflict, status
from .connectors import SheetsAdapter, NotionAdapter
from .sync_auth import OAuthVerifier, https_url
from .sync_service import SyncRepository, create_app
from .sync_store import SyncStore
from .validation import LedgerError, uuid_text


def _private_root(value):
    root = Path(value).expanduser().absolute()
    if root.is_symlink():
        raise LedgerError("Root cannot be a symlink")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = root.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise LedgerError("Root must be an owner-owned private directory")
    return root


def _credential_file(path):
    descriptor = os.open(Path(path).expanduser(), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536:
            raise LedgerError("Credentials require an owner-owned 0600 regular file, at most 64 KiB")
        with os.fdopen(descriptor, "r", encoding="utf-8") as file:
            descriptor = None
            raw = file.read(65537)
        if len(raw.encode("utf-8")) > 65536:
            raise LedgerError("Credential file is too large")
        config = json.loads(raw)
        if not isinstance(config, dict):
            raise LedgerError("Connector config must be an object")
        common = {"provider", "ledgerId", "connectorId"}
        providers = {"google_sheets": {"spreadsheetId", "tab"}, "notion": {"dataSourceId"}}
        fields = providers.get(config.get("provider"))
        if config.get("provider") == "google_oauth":
            fields = {"googleClientConfig", "publicUrl"}
        else:
            common = common | {"token"}
        if fields is None or set(config) != common | fields:
            raise LedgerError("Connector config fields do not match its provider")
        if not all(isinstance(value, str) and value and len(value) <= 8192 for value in config.values()):
            raise LedgerError("Connector config requires bounded nonblank strings")
        config["ledgerId"] = uuid_text(config["ledgerId"])
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", config["connectorId"]):
            raise LedgerError("Connector ID must contain 1–80 letters, digits, hyphens or underscores")
        return config
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _write_new_private(path, payload):
    path = Path(path).expanduser().absolute()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            json.dump(payload, file, separators=(",", ":"))
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def _google_oauth(root, public_url, client_config):
    # Import lazily: ordinary sync/Notion deployments need no Google OAuth setup.
    from .google_oauth import GoogleOAuth
    return GoogleOAuth.from_private_file(root, public_url, Path(client_config).expanduser())


def _status_summary(value):
    return {"pendingCount": len(value.get("pending", {})), "conflictCount": len(value.get("conflicts", {})),
            "deletionProposalCount": len(value.get("deletionProposals", [])),
            "deletionDigest": value.get("deletionDigest"), "lastSuccessAt": value.get("lastSuccessAt"),
            "retryAt": value.get("retryAt", 0), "error": value.get("error")}


def _interval(value):
    seconds = int(value)
    if not 5 <= seconds <= 3600:
        raise argparse.ArgumentTypeError("Interval must be 5–3600 seconds")
    return seconds


def _watch(args, stop_event=None):
    """Foreground poll worker; supervise with launchd/systemd for persistence.

    Watch deliberately logs count-only summaries, never --details or reusable
    deletion approvals. Each poll honors the durable provider Retry-After state.
    """
    stop = stop_event or Event()
    single = argparse.Namespace(**{**vars(args), "command": "connector-run", "details": False,
                                   "confirmation_digest": None})
    while not stop.is_set():
        print(json.dumps(run(single), separators=(",", ":")), flush=True)
        stop.wait(args.interval)


def parser():
    result = argparse.ArgumentParser(description="SmartSpend owner-scoped connected sync")
    result.add_argument("--root", required=True, help="Private service data directory (0700)")
    commands = result.add_subparsers(dest="command", required=True)
    google_config = commands.add_parser("configure-google-client", help="Save a Google client secret via a hidden terminal prompt, never command arguments")
    google_config.add_argument("--client-id", required=True)
    google_config.add_argument("--public-url", required=True)
    google_config.add_argument("--output", required=True)
    notion_config = commands.add_parser("configure-notion-client", help="Save a Notion public OAuth client secret via a hidden terminal prompt")
    notion_config.add_argument("--client-id", required=True)
    notion_config.add_argument("--public-url", required=True)
    notion_config.add_argument("--output", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--public-url", required=True)
    serve.add_argument("--port", type=int, default=18770)
    serve.add_argument("--oauth-issuer")
    serve.add_argument("--oauth-jwks-url")
    serve.add_argument("--google-client-config", help="Owner-only downloaded Google web OAuth JSON")
    serve.add_argument("--notion-client-config", help="Owner-only Notion public OAuth client JSON")
    serve.add_argument("--account-client-config", help="Owner-only Google/Apple/Telegram sign-in configuration; separate from expense connector credentials")
    serve.add_argument("--allow-device-enrollment", action="store_true", help="Explicitly enable bounded per-installation signup; configure edge abuse protection before public use")
    token = commands.add_parser("create-token")
    token.add_argument("--ledger", required=True)
    token.add_argument("--public-url", required=True)
    token.add_argument("--output", required=True)
    token.add_argument("--days", type=int, default=30)
    token.add_argument("--read-only", action="store_true")
    for name in ("bind-subject", "unbind-subject"):
        bind = commands.add_parser(name)
        bind.add_argument("--issuer", required=True)
        bind.add_argument("--subject", required=True)
        if name == "bind-subject":
            bind.add_argument("--ledger", required=True)
            bind.add_argument("--read-only", action="store_true")
    revoke = commands.add_parser("revoke")
    revoke.add_argument("--grant-id", required=True)
    backup = commands.add_parser("backup")
    backup.add_argument("--ledger", required=True)
    backup.add_argument("--output", required=True)
    validate = commands.add_parser("validate-backup")
    validate.add_argument("path")
    for name in ("connector-run", "connector-status", "connector-resolve", "connector-watch"):
        connector = commands.add_parser(name)
        connector.add_argument("--config", required=True)
        if name != "connector-watch":
            connector.add_argument("--details", action="store_true", help="Include private financial records in stdout")
        if name == "connector-run":
            connector.add_argument("--confirmation-digest")
        elif name == "connector-resolve":
            connector.add_argument("--expense-id", required=True)
            connector.add_argument("--prefer", required=True, choices=("canonical", "provider"))
            connector.add_argument("--conflict-digest", required=True)
        elif name == "connector-watch":
            connector.add_argument("--interval", type=_interval, default=15)
    return result


def run(args):
    if args.command == "connector-watch":
        _watch(args)
        return None
    repo = SyncRepository(_private_root(args.root))
    if args.command in ("configure-google-client", "configure-notion-client"):
        notion = args.command == "configure-notion-client"
        if notion:
            args.client_id = uuid_text(args.client_id)
        elif not re.fullmatch(r"[A-Za-z0-9_-]{5,200}\.apps\.googleusercontent\.com", args.client_id):
            raise LedgerError("Expected a Google OAuth client ID")
        public = https_url(args.public_url).rstrip("/")
        # Never fall back to a visible stdin prompt in non-interactive sessions.
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            try:
                secret = getpass.getpass("Paste " + ("Notion" if notion else "Google") + " client secret (hidden): ")
            except (getpass.GetPassWarning, EOFError):
                raise LedgerError("Run this command in an interactive terminal; the secret must not be visible") from None
        if not isinstance(secret, str) or not 10 <= len(secret) <= 1024 or any(char.isspace() for char in secret):
            raise LedgerError("Expected a nonblank client secret without whitespace")
        if notion:
            _write_new_private(args.output, {"client_id": args.client_id, "client_secret": secret,
                                            "redirect_uri": public + "/oauth/notion/callback"})
        else:
            _write_new_private(args.output, {"web":{"client_id":args.client_id,"client_secret":secret,
                "redirect_uris":[public+"/oauth/google/callback"],"auth_uri":"https://accounts.google.com/o/oauth2/auth",
                "token_uri":"https://oauth2.googleapis.com/token"}})
        return {"configurationWritten":True}
    scopes = ("ledger:read",) if getattr(args, "read_only", False) else ("ledger:read", "ledger:write")
    if args.command == "serve":
        public = https_url(args.public_url).rstrip("/")
        if not 1024 <= args.port <= 65535:
            raise LedgerError("Port must be 1024–65535")
        if bool(args.oauth_issuer) != bool(args.oauth_jwks_url):
            raise LedgerError("OAuth issuer and JWKS URL must be supplied together")
        oauth = OAuthVerifier(repo.grants, issuer=args.oauth_issuer, resource=public + "/mcp", jwks_url=args.oauth_jwks_url) if args.oauth_issuer else None
        google = _google_oauth(repo.root, public, args.google_client_config) if args.google_client_config else None
        app_options = {"public_url": public, "oauth": oauth}
        if args.account_client_config:
            from .account_auth import AccountAuth
            app_options["account_auth"] = AccountAuth.from_private_file(repo.root, public, Path(args.account_client_config).expanduser())
        if google is not None:
            app_options["google_oauth"] = google
        if args.notion_client_config:
            from .notion_oauth import NotionOAuth
            app_options["notion_oauth"] = NotionOAuth.from_private_file(repo.root, public, Path(args.notion_client_config).expanduser())
        if args.allow_device_enrollment:
            from .device_enrollment import DeviceEnrollment
            app_options["device_enrollment"] = DeviceEnrollment(repo.grants, repo.root)
        uvicorn.run(create_app(repo, **app_options), host="127.0.0.1", port=args.port,
                    access_log=False, log_level="warning", proxy_headers=False)
        return None
    if args.command == "create-token":
        public = https_url(args.public_url).rstrip("/")
        ledger = uuid_text(args.ledger)
        grant, token = repo.grants.issue(ledger, scopes, lifetime=args.days * 86400)
        try:
            _write_new_private(args.output, {"server": public, "ledgerId": ledger, "token": token})
        except BaseException:
            repo.grants.revoke(grant)
            raise
        return {"grantId": grant, "connectionFileWritten": True}
    if args.command == "bind-subject":
        repo.grants.bind(args.issuer, args.subject, args.ledger, scopes)
        return {"bound": True}
    if args.command == "unbind-subject":
        repo.grants.unbind(args.issuer, args.subject)
        return {"unbound": True}
    if args.command == "revoke":
        repo.grants.revoke(args.grant_id)
        return {"revoked": True}
    if args.command == "backup":
        return repo.ledger(args.ledger).backup(args.output)
    if args.command == "validate-backup":
        context = SyncStore.validate_backup(args.path)
        return {"valid": True, "ledgerId": context["ledgerId"], "revision": context["revision"]}
    config = _credential_file(args.config)
    store = repo.ledger(config["ledgerId"])
    path = str(store.path) + ".connectors.sqlite3"
    if args.command == "connector-status":
        current = status(path, config["connectorId"])
    else:
        currency = store.context()["currency"]
        if config["provider"] == "google_oauth":
            manager = _google_oauth(repo.root, config["publicUrl"], config["googleClientConfig"])
            config = manager.config(config["ledgerId"], config["connectorId"])
        with httpx.Client(follow_redirects=False) as client:
            if config["provider"] == "google_sheets":
                adapter = SheetsAdapter(client, config["token"], config["spreadsheetId"], config["tab"], currency)
            else:
                adapter = NotionAdapter(client, config["token"], config["dataSourceId"], currency)
            if args.command == "connector-resolve":
                return resolve_conflict(store, adapter, config["connectorId"], uuid_text(args.expense_id),
                    args.prefer, args.conflict_digest, state_path=path)
            current = reconcile(store, adapter, config["connectorId"], state_path=path,
                                confirmation_digest=args.confirmation_digest)
    return current if args.details else _status_summary(current)


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        result = run(args)
        if result is not None:
            print(json.dumps(result, separators=(",", ":")))
        return 1 if isinstance(result, dict) and result.get("error") else 0
    except (LedgerError, OSError, ValueError, TypeError, KeyError, sqlite3.Error):
        # Never echo raw provider payloads, config values or OS filenames here.
        print("Operation failed. Check private file permissions, configuration and ledger state.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
