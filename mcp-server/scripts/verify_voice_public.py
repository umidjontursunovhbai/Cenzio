#!/usr/bin/env python3
"""Non-billable public-route smoke test. No secrets are logged or saved."""
import http.client
import json
import socket
import ssl
import subprocess

HOST = "ubuntu.onca-albacore.ts.net"


class PublicHTTPS(http.client.HTTPSConnection):
    def connect(self):
        # Resolve through public DNS, not this Mac's tailnet MagicDNS.
        result = subprocess.run(["dig", "@1.1.1.1", HOST, "A", "+short"], capture_output=True, text=True, check=True, timeout=10)
        addresses = [line for line in result.stdout.splitlines() if line and not line.startswith("100.")]
        if not addresses:
            raise ValueError("No public DNS answer")
        self.sock = ssl.create_default_context().wrap_socket(socket.create_connection((addresses[0], 10000), timeout=20), server_hostname=HOST)


def request(method, path, data=None, token=None):
    connection = PublicHTTPS(HOST, 10000, timeout=20)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        connection.request(method, path, json.dumps(data) if data is not None else None, headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read(65536))
    finally:
        connection.close()


def main():
    token = None
    try:
        assert request("GET", "/health")[0] == 200
        assert request("POST", "/v1/drafts", {})[0] == 401
        ssh = ["ssh", "-i", "/Users/gg/.ssh/hermes_openclaw", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "ubuntu@100.67.52.60"]
        result = subprocess.run([*ssh, "/home/ubuntu/smartspend-mcp/.venv/bin/smartspend-voice --state /home/ubuntu/smartspend-mcp/.data/voice.sqlite3 pair-code"], capture_output=True, timeout=20, check=True)
        code = json.loads(result.stdout)["code"]
        status, paired = request("POST", "/v1/pair", {"code": code})
        assert status == 200
        token = paired["token"]
        assert request("POST", "/v1/pair", {"code": code})[0] == 401
        # Invalid/consent-free input must fail before any provider request.
        assert request("POST", "/v1/drafts", {"consent": False}, token)[0] == 400
        assert request("DELETE", "/v1/device", token=token)[0] == 200
        assert request("POST", "/v1/drafts", {}, token)[0] == 401
        token = None
        print("PASS: public TLS, health, anonymous denial, one-use pairing, validation, revocation. No AI calls or expense writes.")
        return 0
    except Exception:
        print("Public-route smoke test failed; no credentials or response bodies logged.")
        return 1
    finally:
        if token:
            try:
                request("DELETE", "/v1/device", token=token)
            except Exception:
                print("Temporary test credential cleanup unconfirmed; owner review required.")


if __name__ == "__main__":
    raise SystemExit(main())
