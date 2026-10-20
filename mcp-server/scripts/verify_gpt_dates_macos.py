#!/usr/bin/env python3
"""Billable synthetic date regression checks; no ledger/audio access or writes."""
import json
import subprocess
from uuid import uuid4
import httpx
from provision_voice_phone_macos import SSH, ISSUE


def main():
    token = None
    try:
        issued = subprocess.run([*SSH, "/home/ubuntu/smartspend-mcp/.venv/bin/python -"], input=ISSUE.encode(), capture_output=True, check=True, timeout=20)
        token = json.loads(issued.stdout)["token"]
        category = str(uuid4())
        with httpx.Client(base_url="https://ubuntu.onca-albacore.ts.net:10000", timeout=35, trust_env=False) as client:
            cases = [
                ("i spend 15000 for bus like 3 days ago", "2026-10-20", "Asia/Tashkent", "2026-10-17"),
                ("Я потратил 15000 сум на автобус три дня назад", "2026-10-20", "Asia/Tashkent", "2026-10-17"),
                ("I spent 15000 for bus 3 days ago", "2026-01-02", "Asia/Tashkent", "2025-12-30"),
                ("I spent 15000 for bus one day ago", "2024-03-01", "America/Los_Angeles", "2024-02-29"),
            ]
            for text, reference, zone, expected in cases:
                reply = client.post("/v1/drafts", headers={"Authorization": "Bearer " + token}, json={"request_id": str(uuid4()), "transcript": text, "categories": [{"id": category, "name": "Transport"}], "currency": "UZS", "reference_date": reference, "time_zone": zone, "consent": True})
                assert reply.status_code == 200, "Gateway failed"
                result = reply.json()
                assert not result["saved"]
                assert result["transactions"][0]["date_expression"] == expected, "Incorrect date"
                print("PASS: actual GPT-6 Luna date", reference, "→", expected, flush=True)
            assert client.delete("/v1/device", headers={"Authorization": "Bearer " + token}).status_code == 200
            token = None
        return 0
    except Exception:
        print("Date regression check failed; no credentials or response bodies logged.")
        return 1
    finally:
        if token:
            try:
                with httpx.Client(timeout=15, trust_env=False) as client:
                    client.delete("https://ubuntu.onca-albacore.ts.net:10000/v1/device", headers={"Authorization": "Bearer " + token})
            except Exception:
                print("Temporary credential cleanup unconfirmed; owner review required.")


if __name__ == "__main__":
    raise SystemExit(main())
