#!/usr/bin/env python3
"""Show a short-lived owner invitation locally, without logging its value."""
import json
import re
import subprocess


def main():
    ssh = ["ssh", "-i", "/Users/gg/.ssh/hermes_openclaw", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "ubuntu@100.67.52.60"]
    command = "/home/ubuntu/smartspend-mcp/.venv/bin/smartspend-voice --state /home/ubuntu/smartspend-mcp/.data/voice.sqlite3 pair-code"
    try:
        result = subprocess.run([*ssh, command], capture_output=True, timeout=20)
        if result.returncode:
            raise ValueError("Pairing unavailable")
        code = json.loads(result.stdout)["code"]
        if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", code):
            raise ValueError("Unexpected invite format")
        # Pass invitation over stdin only, never process arguments or clipboard.
        script = '''tell current application
activate
display dialog "iPhone: + tugmasini bosib turib pastga torting > Voice connection.\nServer: https://ubuntu.onca-albacore.ts.net:10000\n\nQuyidagi kodni nusxalab telefondagi pairing maydoniga qo'ying. Kod 10 daqiqa amal qiladi, faqat bir marta ishlaydi. Bu API key emas." default answer ''' + json.dumps(code) + ''' buttons {"Done"} default button "Done" with title "SmartSpend — iPhone pairing"
end tell
'''
        subprocess.run(["/usr/bin/osascript", "-"], input=script.encode(), capture_output=True, check=True)
        print("Pairing invitation shown locally; its value was not logged.")
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print("Pairing window unavailable. No invitation was logged.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
