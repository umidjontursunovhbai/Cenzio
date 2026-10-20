#!/usr/bin/env python3
"""Explicit billable synthetic checks against the authenticated GPT gateway.

No audio or real ledger history is used. Test device credential is revoked.
"""
import json
import subprocess
from uuid import uuid4
from datetime import datetime
from zoneinfo import ZoneInfo

import httpx
from provision_voice_phone_macos import SSH, ISSUE


def main():
    token = None
    try:
        result = subprocess.run([*SSH, "/home/ubuntu/smartspend-mcp/.venv/bin/python -"], input=ISSUE.encode(), capture_output=True, timeout=20, check=True)
        token = json.loads(result.stdout)["token"]
        with httpx.Client(base_url="https://ubuntu.onca-albacore.ts.net:10000", timeout=35, trust_env=False, follow_redirects=False) as client:
            food, vehicle = str(uuid4()), str(uuid4())
            cases = [
                ("bus", "for bus i spend 2500 today", [{"id": vehicle, "name": "Transport"}, {"id": food, "name": "Groceries"}], vehicle, "2500", "bus"),
                ("quantity", "i bought 2 kilo potato yesterday for 6000", [{"id": vehicle, "name": "Transport"}, {"id": food, "name": "Groceries"}], food, "6000", "potato"),
                ("Uzbek category options", "Men bugun 2 ta apple oldim, jami 6000 so'm to'ladim", [{"id": vehicle, "name": "Moshna"}, {"id": food, "name": "Ovqat"}], food, "6000", None),
                ("Russian category options", "Вчера купил 2 кг картошки за 6000 сум", [{"id": food, "name": "Продукты"}, {"id": vehicle, "name": "Транспорт"}], food, "6000", "карто"),
            ]
            for name, transcript, categories, expected_category, expected_amount, noun in cases:
                response = client.post("/v1/drafts", headers={"Authorization": "Bearer " + token}, json={
                    "request_id": str(uuid4()), "transcript": transcript, "categories": categories,
                    "currency": "UZS", "reference_date": datetime.now(ZoneInfo("Asia/Tashkent")).date().isoformat(),
                    "time_zone": "Asia/Tashkent", "consent": True,
                })
                assert response.status_code == 200, "Gateway request failed"
                draft = response.json()
                assert draft["saved"] is False and draft["requires_review"] is True
                assert len(draft["transactions"]) == 1
                item = draft["transactions"][0]
                assert item["category_id"] == expected_category, "Wrong category"
                assert item["amount_decimal"] == expected_amount, "Wrong amount"
                assert item["title"] and len(item["title"].split()) <= 6, "Title is not concise"
                if noun:
                    assert noun in item["title"].lower(), "Item missing from title"
                print("PASS:", name, "— actual GPT-6 Luna amount, dynamic category, compact title; not saved.", flush=True)
            assert client.delete("/v1/device", headers={"Authorization": "Bearer " + token}).status_code == 200
            token = None
        return 0
    except Exception:
        print("Live GPT check failed; no credentials or response bodies logged.")
        return 1
    finally:
        if token:
            try:
                with httpx.Client(timeout=15, trust_env=False) as client:
                    client.delete("https://ubuntu.onca-albacore.ts.net:10000/v1/device", headers={"Authorization": "Bearer " + token})
            except Exception:
                print("Temporary test credential cleanup unconfirmed; owner review required.")


if __name__ == "__main__":
    raise SystemExit(main())
