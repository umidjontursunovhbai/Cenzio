import copy
import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("voice_https_prompt", Path(__file__).parents[1] / "scripts" / "enable_voice_https_macos.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
PASSWORD = " synthetic password with spaces "
BEFORE = {"TCP": {"443": {"HTTPS": True}}, "Web": {"other.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:1234"}}}}, "AllowFunnel": {"other.ts.net:443": True}}
AFTER = copy.deepcopy(BEFORE)
AFTER["TCP"]["9443"] = {"HTTPS": True}
AFTER["Web"][helper.DOMAIN] = {"Handlers": {"/": {"Proxy": helper.PROXY}}}


@pytest.mark.parametrize("failure", [None, "cancel", "sudo", "timeout", "unexpected_change"])
def test_password_hidden_stdin_only_and_only_scoped_sudo_command(monkeypatch, capsys, failure):
    monkeypatch.setattr(helper.sys, "platform", "darwin")
    monkeypatch.setattr(helper.sys, "argv", ["prompt", "--host", "test@100.0.0.1", "--identity", "/synthetic/key"])
    calls = []

    def run(args, **kwargs):
        calls.append((args, kwargs))
        assert PASSWORD not in repr(args)
        if args[0] == "/usr/bin/osascript":
            assert "with hidden answer" in args[-1]
            return subprocess.CompletedProcess(args, int(failure == "cancel"), stdout=PASSWORD + "\n", stderr=PASSWORD)
        if "sudo" in args[-1]:
            assert kwargs["input"] == PASSWORD.encode() + b"\n"
            assert "--https=9443" in args[-1] and "funnel" not in args[-1] and "reset" not in args[-1]
            assert "--socket" not in args[-1]
            if failure == "timeout":
                raise subprocess.TimeoutExpired(args, 30, output=PASSWORD.encode())
            return subprocess.CompletedProcess(args, int(failure == "sudo"), stdout=PASSWORD.encode(), stderr=PASSWORD.encode())
        assert "input" not in kwargs
        config = copy.deepcopy(BEFORE if len(calls) == 1 else AFTER)
        if failure == "unexpected_change" and len(calls) != 1:
            config["TCP"].pop("443")
        return subprocess.CompletedProcess(args, 0, stdout=json.dumps(config).encode(), stderr=b"")

    monkeypatch.setattr(helper.subprocess, "run", run)
    assert helper.main() == (0 if failure is None else 1)
    output = capsys.readouterr()
    assert PASSWORD not in output.out + output.err
    assert len([args for args, _ in calls if args[0] == "ssh" and "sudo" in args[-1]]) == (0 if failure == "cancel" else 1)


def test_config_verification_rejects_funnel_and_preserves_other_ports():
    assert helper.configured(AFTER)
    assert helper.unrelated(AFTER) == helper.unrelated(BEFORE)
    public = copy.deepcopy(AFTER)
    public["AllowFunnel"][helper.DOMAIN] = True
    assert not helper.configured(public)


def test_public_mode_requires_funnel_and_preserves_private_listener():
    public = copy.deepcopy(AFTER)
    public["TCP"]["10000"] = {"HTTPS": True}
    public["Web"]["ubuntu.onca-albacore.ts.net:10000"] = {"Handlers": {"/": {"Proxy": helper.PROXY}}}
    assert not helper.configured(public, True)
    public["AllowFunnel"]["ubuntu.onca-albacore.ts.net:10000"] = True
    assert helper.configured(public, True)
    assert helper.unrelated(public, "10000") == helper.unrelated(AFTER, "10000")


def test_public_command_is_explicit_and_scoped(monkeypatch, capsys):
    monkeypatch.setattr(helper.sys, "platform", "darwin")
    monkeypatch.setattr(helper.sys, "argv", ["prompt", "--host", "test@100.0.0.1", "--identity", "/synthetic/key", "--public-funnel"])
    calls = []
    after = copy.deepcopy(AFTER)
    after["TCP"]["10000"] = {"HTTPS": True}
    after["Web"]["ubuntu.onca-albacore.ts.net:10000"] = {"Handlers": {"/": {"Proxy": helper.PROXY}}}
    after["AllowFunnel"]["ubuntu.onca-albacore.ts.net:10000"] = True

    def run(args, **kwargs):
        calls.append(args)
        assert PASSWORD not in repr(args)
        if args[0] == "/usr/bin/osascript":
            assert "PUBLIC HTTPS 10000" in args[-1] and "with hidden answer" in args[-1]
            return subprocess.CompletedProcess(args, 0, stdout=PASSWORD + "\n")
        if "sudo" in args[-1]:
            assert "funnel --bg --https=10000 --yes http://127.0.0.1:18769" in args[-1]
            assert "--socket" not in args[-1] and "reset" not in args[-1]
            assert kwargs["input"] == PASSWORD.encode() + b"\n"
            return subprocess.CompletedProcess(args, 0, stdout=b"", stderr=b"")
        return subprocess.CompletedProcess(args, 0, stdout=json.dumps(AFTER if len(calls) == 1 else after).encode())

    monkeypatch.setattr(helper.subprocess, "run", run)
    assert helper.main() == 0
    assert PASSWORD not in capsys.readouterr().out


@pytest.mark.parametrize("message,expected", [
    ("sudo: 1 incorrect password attempt", "password was not accepted"),
    ("not in the sudoers file", "not permitted"),
    ("a terminal is required", "interactive terminal"),
    ("no such file or directory", "binary or socket"),
    ("unknown flag: --test", "command option"),
    ("flag provided multiple times", "command option"),
    ("HTTPS is not enabled", "admin configuration"),
    ("other failure", "not confirmed"),
])
def test_error_classification_never_echoes_subprocess_output(message, expected):
    output = helper.safe_failure_reason((message + PASSWORD).encode())
    assert expected in output
    assert PASSWORD not in output
