#!/usr/bin/env python3
"""Provision one owner development iPhone over the paired Mac, without a user code.

Only a revocable device bearer is transferred. The provider API key never leaves
Ubuntu. No credentials are passed in process arguments, printed, or bundled.
"""
import argparse
import json
import os
import subprocess
import tempfile

SSH = ["ssh", "-i", "/Users/gg/.ssh/hermes_openclaw", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "ubuntu@100.67.52.60"]
ISSUE = '''import json
from pathlib import Path
from smartspend_mcp.voice_api import DeviceStore
state = DeviceStore(Path('/home/ubuntu/smartspend-mcp/.data/voice.sqlite3'))
token = state.pair(state.issue_code())
if not token: raise SystemExit(1)
print(json.dumps({'server':'https://ubuntu.onca-albacore.ts.net:10000','token':token}))
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    token = None
    try:
        result = subprocess.run([*SSH, "/home/ubuntu/smartspend-mcp/.venv/bin/python -"], input=ISSUE.encode(), capture_output=True, timeout=20, check=True)
        credential = json.loads(result.stdout)
        token = credential["token"]
        if not isinstance(token, str) or not 40 <= len(token) <= 100:
            raise ValueError("Invalid credential")
        with tempfile.TemporaryDirectory(prefix="smartspend-phone-") as directory:
            path = os.path.join(directory, "connection.json")
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as handle:
                json.dump(credential, handle)
            subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
                            "--source", path, "--destination", "Documents/.smartspend-voice-connection.json",
                            "--domain-type", "appDataContainer", "--domain-identifier", "com.tursunov.SmartSpend",
                            "--timeout", "30", "--quiet"], capture_output=True, timeout=40, check=True)
        print("Owner development iPhone provisioned. No pairing code or provider key entered on the phone; no credential logged.")
        return 0
    except Exception:
        # A failed copy must not leave an orphaned server-side phone credential.
        if token:
            cleanup = "from pathlib import Path\nfrom smartspend_mcp.voice_api import DeviceStore,digest\nimport sys\nDeviceStore(Path('/home/ubuntu/smartspend-mcp/.data/voice.sqlite3')).revoke(digest(sys.stdin.read()))"
            try:
                import shlex
                subprocess.run([*SSH, "/home/ubuntu/smartspend-mcp/.venv/bin/python -c " + shlex.quote(cleanup)], input=token.encode(), capture_output=True, timeout=15, check=True)
            except Exception:
                print("Failed provision credential cleanup requires owner review.")
        print("Device provisioning failed. No credential or subprocess output logged.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
