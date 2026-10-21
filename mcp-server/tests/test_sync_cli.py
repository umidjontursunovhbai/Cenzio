import json
import os
from pathlib import Path
from unittest.mock import Mock

import pytest

from smartspend_mcp import sync_cli
from smartspend_mcp.sync_service import SyncRepository
from conftest import LEDGER, EXPENSE, snapshot


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "private"
    path.mkdir(mode=0o700)
    return path


def call(root, *args):
    return sync_cli.main(["--root", str(root), *map(str, args)])


def config(tmp_path, **changes):
    path = tmp_path / "credentials"
    path.write_text(json.dumps({"provider": "google_sheets", "ledgerId": LEDGER, "connectorId": "selected",
        "spreadsheetId": "selected-sheet", "tab": "Expenses", "token": "private-provider-token", **changes}))
    path.chmod(0o600)
    return path


def test_token_written_exclusively_private_no_stdout_secret(root, tmp_path, capsys):
    output = tmp_path / "connection"
    assert call(root, "create-token", "--ledger", LEDGER, "--public-url", "https://sync.example", "--output", output) == 0
    data = json.loads(output.read_text())
    assert set(data) == {"server", "ledgerId", "token"}
    assert os.stat(output).st_mode & 0o777 == 0o600
    stdout = capsys.readouterr().out
    assert data["token"] not in stdout
    grant = SyncRepository(root).grants.verify(data["token"])
    assert grant.ledger_id == LEDGER
    assert "ledger:write" in grant.scopes
    assert call(root, "revoke", "--grant-id", grant.grant_id) == 0
    assert SyncRepository(root).grants.verify(data["token"]) is None


def test_google_client_hidden_configuration_exclusive_private(root, tmp_path, monkeypatch, capsys):
    output = tmp_path / "google-client"
    secret = "synthetic-google-client-secret"
    monkeypatch.setattr(sync_cli.getpass, "getpass", lambda _: secret)
    args = ("configure-google-client", "--client-id", "synthetic-client.apps.googleusercontent.com",
            "--public-url", "https://sync.example", "--output", output)
    assert call(root, *args) == 0
    saved = json.loads(output.read_text())["web"]
    assert saved["client_secret"] == secret
    assert saved["redirect_uris"] == ["https://sync.example/oauth/google/callback"]
    assert os.stat(output).st_mode & 0o777 == 0o600
    assert secret not in capsys.readouterr().out
    assert call(root, *args) == 1
    assert json.loads(output.read_text())["web"] == saved


def test_google_configuration_refuses_unhidden_input(root, tmp_path, monkeypatch):
    def not_interactive(_):
        import warnings
        warnings.warn("cannot hide input", sync_cli.getpass.GetPassWarning)
        return "never-reached"
    monkeypatch.setattr(sync_cli.getpass, "getpass", not_interactive)
    output = tmp_path / "google-client"
    assert call(root, "configure-google-client", "--client-id", "synthetic-client.apps.googleusercontent.com",
                "--public-url", "https://sync.example", "--output", output) == 1
    assert not output.exists()


def test_existing_output_is_not_overwritten_and_failed_grant_revoked(root, tmp_path, capsys):
    output = tmp_path / "connection"
    output.write_text("preserve")
    assert call(root, "create-token", "--ledger", LEDGER, "--public-url", "https://sync.example", "--output", output) == 1
    assert output.read_text() == "preserve"
    import sqlite3
    with sqlite3.connect(root / "grants.sqlite3") as db:
        assert db.execute("SELECT count(*) FROM grants").fetchone()[0] == 0
    assert "token" not in capsys.readouterr().out


def test_readonly_token_scopes_and_bind_unbind(root, tmp_path):
    output = tmp_path / "connection"
    assert call(root, "create-token", "--ledger", LEDGER, "--public-url", "https://sync.example", "--output", output, "--read-only") == 0
    grants = SyncRepository(root).grants
    assert grants.verify(json.loads(output.read_text())["token"]).scopes == frozenset({"ledger:read"})
    assert call(root, "bind-subject", "--issuer", "https://auth.example", "--subject", "owner", "--ledger", LEDGER, "--read-only") == 0
    assert grants.subject("https://auth.example", "owner", ["ledger:read", "ledger:write"]).scopes == frozenset({"ledger:read"})
    assert call(root, "unbind-subject", "--issuer", "https://auth.example", "--subject", "owner") == 0
    assert grants.subject("https://auth.example", "owner", ["ledger:read"]) is None


def test_serve_loopback_no_access_log_and_oauth_pair(root, monkeypatch):
    serve = Mock()
    monkeypatch.setattr(sync_cli.uvicorn, "run", serve)
    assert call(root, "serve", "--public-url", "https://sync.example") == 0
    assert serve.call_args.kwargs["host"] == "127.0.0.1"
    assert serve.call_args.kwargs["port"] == 18770
    assert serve.call_args.kwargs["access_log"] is False
    assert serve.call_args.kwargs["proxy_headers"] is False
    serve.reset_mock()
    assert call(root, "serve", "--public-url", "https://sync.example", "--oauth-issuer", "https://auth.example") == 1
    serve.assert_not_called()


def test_notion_client_hidden_configuration_is_private_and_not_overwritten(root, tmp_path, monkeypatch, capsys):
    output = tmp_path / "notion-client.json"
    monkeypatch.setattr(sync_cli.getpass, "getpass", lambda prompt: "synthetic-notion-client-value")
    arguments = ("configure-notion-client", "--client-id", LEDGER, "--public-url", "https://sync.example", "--output", output)
    assert call(root, *arguments) == 0
    assert output.stat().st_mode & 0o777 == 0o600
    assert json.loads(output.read_text()) == {"client_id": LEDGER, "client_secret": "synthetic-notion-client-value",
                                             "redirect_uri": "https://sync.example/oauth/notion/callback"}
    before = output.read_bytes()
    assert call(root, *arguments) == 1
    assert output.read_bytes() == before
    assert "synthetic-notion-client-value" not in capsys.readouterr().out


def test_serve_explicitly_enables_device_enrollment_and_notion_only_when_configured(root, monkeypatch):
    app, enrollment, notion = Mock(), Mock(), Mock()
    monkeypatch.setattr(sync_cli, "create_app", app)
    monkeypatch.setattr(sync_cli.uvicorn, "run", Mock())
    monkeypatch.setattr("smartspend_mcp.device_enrollment.DeviceEnrollment", enrollment)
    monkeypatch.setattr("smartspend_mcp.notion_oauth.NotionOAuth.from_private_file", notion)
    assert call(root, "serve", "--public-url", "https://sync.example") == 0
    assert "device_enrollment" not in app.call_args.kwargs
    assert "notion_oauth" not in app.call_args.kwargs
    assert call(root, "serve", "--public-url", "https://sync.example", "--allow-device-enrollment",
                "--notion-client-config", "/private/example-notion.json") == 0
    assert app.call_args.kwargs["device_enrollment"] == enrollment.return_value
    assert app.call_args.kwargs["notion_oauth"] == notion.return_value


def test_serve_oauth_resource_is_exact(root, monkeypatch):
    verifier, app = Mock(), Mock()
    monkeypatch.setattr(sync_cli, "OAuthVerifier", verifier)
    monkeypatch.setattr(sync_cli, "create_app", app)
    monkeypatch.setattr(sync_cli.uvicorn, "run", Mock())
    assert call(root, "serve", "--public-url", "https://sync.example/", "--oauth-issuer", "https://auth.example",
                "--oauth-jwks-url", "https://auth.example/keys") == 0
    assert verifier.call_args.kwargs == {"issuer": "https://auth.example", "resource": "https://sync.example/mcp", "jwks_url": "https://auth.example/keys"}


@pytest.mark.parametrize("kind", ["permissions", "symlink", "oversize", "bad_json", "wrong_fields"])
def test_private_config_validation(root, tmp_path, capsys, kind):
    path = config(tmp_path)
    if kind == "permissions":
        path.chmod(0o644)
    elif kind == "symlink":
        link = tmp_path / "link"
        link.symlink_to(path)
        path = link
    elif kind == "oversize":
        path.write_text("x" * 65537)
    elif kind == "bad_json":
        path.write_text("private-provider-token invalid")
    else:
        path.write_text(json.dumps({"token": "private-provider-token"}))
    assert call(root, "connector-status", "--config", path) == 1
    assert "private-provider-token" not in str(capsys.readouterr())


def test_connector_run_currency_from_ledger_status_sanitized(root, tmp_path, monkeypatch, capsys):
    SyncRepository(root).ledger(LEDGER).bootstrap(snapshot())
    path = config(tmp_path)
    adapter = Mock()
    monkeypatch.setattr(sync_cli, "SheetsAdapter", adapter)
    poll = Mock(return_value={"pending": {EXPENSE: {}}, "conflicts": {}, "baseline": {"private": "financial-title"}})
    monkeypatch.setattr(sync_cli, "reconcile", poll)
    assert call(root, "connector-run", "--config", path, "--confirmation-digest", "reviewed") == 0
    assert adapter.call_args.args[-1] == "UZS"
    assert poll.call_args.kwargs["confirmation_digest"] == "reviewed"
    stdout = capsys.readouterr().out
    assert json.loads(stdout)["pendingCount"] == 1
    assert "financial-title" not in stdout and "private-provider-token" not in stdout


def test_connector_status_does_not_contact_provider(root, tmp_path, monkeypatch, capsys):
    path = config(tmp_path)
    client = Mock(side_effect=AssertionError("must not contact provider"))
    monkeypatch.setattr(sync_cli.httpx, "Client", client)
    assert call(root, "connector-status", "--config", path) == 0
    assert json.loads(capsys.readouterr().out)["pendingCount"] == 0


def test_connector_resolve_passes_exact_approval(root, tmp_path, monkeypatch):
    SyncRepository(root).ledger(LEDGER).bootstrap(snapshot())
    path = config(tmp_path)
    resolve = Mock(return_value={"pendingReconcile": True})
    monkeypatch.setattr(sync_cli, "resolve_conflict", resolve)
    assert call(root, "connector-resolve", "--config", path, "--expense-id", EXPENSE, "--prefer", "provider", "--conflict-digest", "exact") == 0
    assert resolve.call_args.args[-3:] == (EXPENSE, "provider", "exact")


def test_backup_and_validate(root, tmp_path, capsys):
    SyncRepository(root).ledger(LEDGER).bootstrap(snapshot())
    output = tmp_path / "backup.sqlite3"
    assert call(root, "backup", "--ledger", LEDGER, "--output", output) == 0
    assert call(root, "validate-backup", output) == 0
    assert '"valid":true' in capsys.readouterr().out
    assert call(root, "backup", "--ledger", LEDGER, "--output", output) == 1


def test_public_or_symlink_root_refused(tmp_path):
    root = tmp_path / "public"
    root.mkdir(mode=0o755)
    assert call(root, "revoke", "--grant-id", "irrelevant") == 1
    link = tmp_path / "linked"
    link.symlink_to(root)
    assert call(link, "revoke", "--grant-id", "irrelevant") == 1


def test_watch_polls_count_only_and_stops_without_live_network(root, tmp_path, monkeypatch, capsys):
    path = config(tmp_path)
    args = sync_cli.parser().parse_args(["--root", str(root), "connector-watch", "--config", str(path), "--interval", "5"])
    class Stop:
        waits = []
        def is_set(self):
            return len(self.waits) >= 2
        def wait(self, seconds):
            self.waits.append(seconds)
    poll = Mock(return_value={"pendingCount": 0, "error": None})
    monkeypatch.setattr(sync_cli, "run", poll)
    stop = Stop()
    sync_cli._watch(args, stop_event=stop)
    assert poll.call_count == 2
    assert stop.waits == [5, 5]
    assert poll.call_args.args[0].details is False
    assert poll.call_args.args[0].confirmation_digest is None
    assert len(capsys.readouterr().out.splitlines()) == 2


@pytest.mark.parametrize("interval", ["0", "4", "3601", "-1"])
def test_watch_interval_bounds(root, tmp_path, interval):
    with pytest.raises(SystemExit):
        sync_cli.parser().parse_args(["--root", str(root), "connector-watch", "--config", "unused", "--interval", interval])


def google_config(tmp_path):
    path = tmp_path / "oauth-connector"
    path.write_text(json.dumps({"provider": "google_oauth", "ledgerId": LEDGER, "connectorId": "selected",
        "googleClientConfig": str(tmp_path / "google-web-client"), "publicUrl": "https://sync.example"}))
    path.chmod(0o600)
    return path


def test_google_oauth_connector_refreshes_private_config_each_poll(root, tmp_path, monkeypatch, capsys):
    SyncRepository(root).ledger(LEDGER).bootstrap(snapshot())
    path = google_config(tmp_path)
    manager = Mock()
    manager.config.return_value = {"provider": "google_sheets", "ledgerId": LEDGER, "connectorId": "selected",
        "token": "refreshed-secret-token", "spreadsheetId": "selected-sheet", "tab": "Expenses"}
    factory = Mock(return_value=manager)
    monkeypatch.setattr(sync_cli, "_google_oauth", factory)
    adapter = Mock()
    monkeypatch.setattr(sync_cli, "SheetsAdapter", adapter)
    monkeypatch.setattr(sync_cli, "reconcile", Mock(return_value={"conflicts": {}, "pending": {}}))
    assert call(root, "connector-run", "--config", path) == 0
    assert call(root, "connector-run", "--config", path) == 0
    assert manager.config.call_count == 2
    assert manager.config.call_args.args == (LEDGER, "selected")
    assert adapter.call_args.args[1] == "refreshed-secret-token"
    assert "refreshed-secret-token" not in capsys.readouterr().out


def test_google_oauth_status_does_not_refresh_or_contact_provider(root, tmp_path, monkeypatch):
    path = google_config(tmp_path)
    factory = Mock(side_effect=AssertionError("No provider calls for status"))
    monkeypatch.setattr(sync_cli, "_google_oauth", factory)
    assert call(root, "connector-status", "--config", path) == 0


def test_serve_passes_google_oauth_manager(root, tmp_path, monkeypatch):
    factory, app = Mock(), Mock()
    monkeypatch.setattr(sync_cli, "_google_oauth", factory)
    monkeypatch.setattr(sync_cli, "create_app", app)
    monkeypatch.setattr(sync_cli.uvicorn, "run", Mock())
    source = tmp_path / "private-web-client"
    assert call(root, "serve", "--public-url", "https://sync.example", "--google-client-config", source) == 0
    assert factory.call_args.args == (root.resolve(), "https://sync.example", str(source))
    assert app.call_args.kwargs["google_oauth"] is factory.return_value
