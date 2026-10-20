from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "scripts" / "configure_openrouter_macos.py"
spec = importlib.util.spec_from_file_location("smartspend_key_entry", SCRIPT)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
FAKE_KEY = "sk-or-v1-" + "synthetic_test_only_" * 3


def setup(monkeypatch):
    monkeypatch.setattr(helper.sys, "platform", "darwin")
    monkeypatch.setattr(helper.sys, "argv", ["key-entry", "--host", "test@100.0.0.1", "--identity", "/synthetic/key", "--server-root", "/synthetic/smartspend"])


def test_hidden_dialog_key_only_in_ssh_stdin_never_args_output_or_local_file(monkeypatch, capsys):
    setup(monkeypatch)
    calls = []

    def run(args, **kwargs):
        calls.append((args, kwargs))
        assert FAKE_KEY not in repr(args)
        if args[0] == "/usr/bin/osascript":
            assert "with hidden answer" in args[-1]
            return subprocess.CompletedProcess(args, 0, stdout=FAKE_KEY + "\n", stderr="")
        if len(calls) == 1:
            assert "input" not in kwargs
            assert "not p.exists()" in args[-1]
        else:
            assert kwargs["input"] == FAKE_KEY.encode()
            assert "save_new" in args[-1]
        assert "StrictHostKeyChecking=yes" in args
        return subprocess.CompletedProcess(args, 0, stdout=b"", stderr=b"")

    monkeypatch.setattr(helper.subprocess, "run", run)
    assert helper.main() == 0
    assert len(calls) == 3
    output = capsys.readouterr()
    assert FAKE_KEY not in output.out + output.err


@pytest.mark.parametrize("stage", ["preflight", "cancel", "invalid", "save", "timeout"])
def test_failures_never_print_secret_or_overwrite_existing_config(stage, monkeypatch, capsys):
    setup(monkeypatch)
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        if len(calls) == 1:
            return subprocess.CompletedProcess(args, int(stage == "preflight"), stdout=b"", stderr=FAKE_KEY.encode())
        if args[0] == "/usr/bin/osascript":
            return subprocess.CompletedProcess(args, int(stage == "cancel"), stdout="bad" if stage == "invalid" else FAKE_KEY, stderr=FAKE_KEY)
        if stage == "timeout":
            raise subprocess.TimeoutExpired(args, 20, output=FAKE_KEY.encode())
        return subprocess.CompletedProcess(args, 1, stdout=FAKE_KEY.encode(), stderr=FAKE_KEY.encode())

    monkeypatch.setattr(helper.subprocess, "run", run)
    assert helper.main() == 1
    assert len(calls) == {"preflight": 1, "cancel": 2, "invalid": 2, "save": 3, "timeout": 3}[stage]
    output = capsys.readouterr()
    assert FAKE_KEY not in output.out + output.err
