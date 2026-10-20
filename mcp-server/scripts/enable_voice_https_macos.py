#!/usr/bin/env python3
"""Hidden Ubuntu sudo prompt, scoped to one SmartSpend HTTPS listener.

The password is never printed, passed in argv, saved, or copied to a clipboard.
Default: private Serve 9443. Explicit --public-funnel: public Funnel 10000.
No global reset; all unrelated listeners are checked before and after.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import shlex
import subprocess
import sys

DOMAIN = "ubuntu.onca-albacore.ts.net:9443"
PROXY = "http://127.0.0.1:18769"
DIALOG = '''
tell current application
    activate
    set response to display dialog "Ubuntu'dagi ubuntu foydalanuvchisining SUDO parolini kiriting.\nBu Mac paroli EMAS.\n\nFaqat SmartSpend uchun PRIVATE HTTPS 9443 yoqiladi.\nMavjud 443/8443 xizmatlari o'zgarmaydi. Parol saqlanmaydi." default answer "" with hidden answer buttons {"Cancel", "Enable HTTPS"} default button "Enable HTTPS" cancel button "Cancel" with title "SmartSpend — Ubuntu sudo"
    return text returned of response
end tell
'''


def unrelated(config, port="9443"):
    result = copy.deepcopy(config)
    domain = "ubuntu.onca-albacore.ts.net:" + port
    for section, key in [("TCP", port), ("Web", domain), ("AllowFunnel", domain)]:
        result.setdefault(section, {}).pop(key, None)
        if not result[section]:
            result.pop(section)
    return result


def configured(config, public=False):
    port = "10000" if public else "9443"
    domain = "ubuntu.onca-albacore.ts.net:" + port
    return (config.get("TCP", {}).get(port, {}).get("HTTPS") is True
            and config.get("Web", {}).get(domain, {}).get("Handlers", {}).get("/", {}).get("Proxy") == PROXY
            and bool(config.get("AllowFunnel", {}).get(domain, False)) == public)


def safe_failure_reason(output):
    """Classify stderr using fixed messages only; never reveal its contents."""
    text = output.decode("utf-8", errors="replace").lower()
    if any(marker in text for marker in ["incorrect password", "authentication failure", "sorry, try again"]):
        return "Ubuntu password was not accepted by sudo. No automatic retry was made."
    if any(marker in text for marker in ["not in the sudoers", "not allowed to execute", "may not run sudo"]):
        return "The Ubuntu account is not permitted to run this sudo command."
    if "terminal is required" in text or "no tty" in text:
        return "This server's sudo policy requires an interactive terminal."
    if any(marker in text for marker in ["no such file", "failed to connect to local tailscaled", "cannot connect", "failed to find tailscaled"]):
        return "The privileged command could not reach the Tailscale binary or socket."
    if any(marker in text for marker in ["flag provided but not defined", "flag provided multiple times", "unknown flag", "unrecognized option"]):
        return "The installed Tailscale version rejected a command option."
    if "https is not enabled" in text or "enable https" in text:
        return "HTTPS must be enabled in the Tailscale admin configuration."
    return "The HTTPS command failed; setup was not confirmed. No automatic retry was made."


def main():
    parser = argparse.ArgumentParser(description="Native hidden sudo entry for SmartSpend private HTTPS only")
    parser.add_argument("--host", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--public-funnel", action="store_true", help="Explicitly expose ONLY SmartSpend port 10000 to the internet")
    args = parser.parse_args()
    port = "10000" if args.public_funnel else "9443"
    domain = "ubuntu.onca-albacore.ts.net:" + port
    description = "PUBLIC HTTPS 10000 (internetdan ochiq, telefon pairing bilan himoyalangan)" if args.public_funnel else "PRIVATE HTTPS 9443"
    dialog_script = DIALOG.replace("PRIVATE HTTPS 9443", description)
    if sys.platform != "darwin" or not re.fullmatch(r"[a-z_][a-z0-9_-]*@[a-zA-Z0-9.-]+", args.host):
        print("A macOS session and valid verified SSH destination are required.")
        return 1
    ssh = ["ssh", "-i", args.identity, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", args.host]

    def status():
        result = subprocess.run([*ssh, "/snap/bin/tailscale serve status --json"], capture_output=True, timeout=15)
        if result.returncode or len(result.stdout) > 65536:
            raise ValueError("Cannot inspect Serve configuration")
        config = json.loads(result.stdout)
        if not isinstance(config, dict):
            raise ValueError("Invalid configuration")
        return config

    try:
        before = status()
        if configured(before, args.public_funnel):
            print(f"SmartSpend HTTPS {port} is already configured; no password requested.")
            return 0
        if port in before.get("TCP", {}) or domain in before.get("Web", {}):
            print(f"Port {port} is already used. Nothing was changed.")
            return 1
        dialog = subprocess.run(["/usr/bin/osascript", "-e", dialog_script], capture_output=True, text=True)
        if dialog.returncode:
            print("Sudo entry cancelled or dialog unavailable. No privileged command ran.")
            return 1
        # Preserve intentional spaces in a password; remove osascript's one newline only.
        password = dialog.stdout.removesuffix("\n")
        if not password or len(password) > 1024 or any(character in password for character in "\r\n\x00"):
            print("No valid single-line password supplied. No privileged command ran.")
            return 1
        # Snap's launcher already injects --socket. Supplying it again makes the
        # Go CLI fail before it reaches Serve, even with valid sudo credentials.
        command = shlex.join(["sudo", "-S", "-p", "", "--", "/snap/bin/tailscale", "funnel" if args.public_funnel else "serve", "--bg", f"--https={port}", "--yes", PROXY])
        enabled = subprocess.run([*ssh, command], input=password.encode("utf-8") + b"\n", capture_output=True, timeout=30)
        if enabled.returncode:
            print(safe_failure_reason(enabled.stderr))
            return 1
        after = status()
        if not configured(after, args.public_funnel) or unrelated(before, port) != unrelated(after, port):
            print("Serve configuration needs manual review; unrelated services were not reset or rolled back.")
            return 1
        print(f"SmartSpend HTTPS {port} enabled. Existing services unchanged. Public Funnel: {args.public_funnel}.")
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired):
        # Do not print exceptions, subprocess output, input or passwords.
        print("Setup confirmation unavailable. Check Serve status before retrying.")
        return 1
    except KeyboardInterrupt:
        print("Secure setup cancelled.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
