#!/usr/bin/env python3
"""Native hidden credential entry -> verified SSH stdin -> private server config.

Never print the credential, pass it in process arguments, write a local copy,
copy it to the clipboard, or make a model API request. Uses macOS stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys

DIALOG = '''
tell current application
    activate
    set response to display dialog "YANGI OpenRouter API key'ni shu yerga kiriting.\nQiymat yashirin bo'ladi va faqat SmartSpend Ubuntu serveriga saqlanadi.\nChatga yuborilgan eski key'ni avval revoke qiling." default answer "" with hidden answer buttons {"Cancel", "Save"} default button "Save" cancel button "Cancel" with title "SmartSpend — Private API Key"
    return text returned of response
end tell
'''


def main() -> int:
    parser = argparse.ArgumentParser(description="Open a native macOS hidden API-key field for SmartSpend")
    parser.add_argument("--host", required=True, help="Verified SSH user@host")
    parser.add_argument("--identity", required=True, help="Existing SSH identity file, never an API key")
    parser.add_argument("--server-root", required=True, help="Absolute private SmartSpend server directory")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("This hidden-entry dialog requires macOS.")
        return 1
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*@[a-zA-Z0-9.-]+", args.host) or not args.server_root.startswith("/"):
        print("Invalid SSH destination or server directory.")
        return 1
    ssh = ["ssh", "-i", args.identity, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", args.host]
    python = args.server_root.rstrip("/") + "/.venv/bin/python"
    config_path = args.server_root.rstrip("/") + "/.data/openrouter.json"
    # Existing configuration must never be replaced. Preflight before asking for a key.
    preflight = "from pathlib import Path; from smartspend_mcp.ai_config import AIConfig; p=Path(" + json.dumps(config_path) + "); assert p.parent.is_dir() and not p.exists() and not p.is_symlink()"
    command = shlex.join([python, "-c", preflight])
    try:
        check = subprocess.run([*ssh, command], capture_output=True, timeout=15)
        if check.returncode:
            print("Cannot prepare key entry: check SSH access or an existing configuration. Nothing was replaced.")
            return 1
        dialog = subprocess.run(["/usr/bin/osascript", "-e", DIALOG], capture_output=True, text=True)
        if dialog.returncode:
            print("Key entry cancelled or native dialog unavailable. No credential was saved.")
            return 1
        key = dialog.stdout.strip()
        if not re.fullmatch(r"sk-or-v1-[a-zA-Z0-9_-]{20,200}", key):
            print("Invalid OpenRouter key format. No credential was sent or saved.")
            return 1
        save = (
            "import sys; from pathlib import Path; from smartspend_mcp.ai_config import AIConfig; "
            "p=Path(" + json.dumps(config_path) + "); "
            "AIConfig(api_key=sys.stdin.read(512).strip()).save_new(p); "
            "c=AIConfig.from_private_file(p); "
            "print('GPT-6 Luna credential saved privately; no model API request was made.')"
        )
        # Credential travels only through an SSH subprocess stdin, not argv or logs.
        saved = subprocess.run([*ssh, shlex.join([python, "-c", save])], input=key.encode("utf-8"), capture_output=True, timeout=20)
        if saved.returncode:
            print("Server confirmation was not received. Check configuration status before retrying; no existing key was overwritten.")
            return 1
        print("GPT-6 Luna credential saved privately on Ubuntu. No model API request was made.")
        return 0
    except (OSError, subprocess.TimeoutExpired):
        # Exception text can include subprocess output: deliberately do not print it.
        print("Secure setup could not finish. Check server configuration status before retrying.")
        return 1
    except KeyboardInterrupt:
        print("Key setup cancelled.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
