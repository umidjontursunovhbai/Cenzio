#!/usr/bin/env python3
"""One-use loopback credential form. No secret in logs, argv or local files."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import secrets
import subprocess
import time
from urllib.parse import parse_qs


SSH = ["ssh", "-i", "/Users/gg/.ssh/hermes_openclaw", "-o", "IdentitiesOnly=yes",
       "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
       "ubuntu@100.67.52.60"]
CONFIG = "/home/ubuntu/smartspend-sync/private/account-clients.json"
PREFLIGHT = "from pathlib import Path; p=Path(" + repr(CONFIG) + "); assert p.parent.is_dir() and not p.exists() and not p.is_symlink()"
SAVE = """import sys,json,os
data=json.loads(sys.stdin.buffer.read(8193))
assert set(data)=={'telegram'}
value=data['telegram']
assert set(value)=={'client_id','client_secret'}
assert value['client_id'].isdigit() and 1<=len(value['client_id'])<=100
assert 10<=len(value['client_secret'])<=4096 and not any(c.isspace() for c in value['client_secret'])
fd=os.open('/home/ubuntu/smartspend-sync/private/account-clients.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as f:
 json.dump(data,f); f.flush(); os.fsync(f.fileno())
"""


def main():
    import shlex
    try:
        result = subprocess.run(SSH + [shlex.join(["python3", "-c", PREFLIGHT])],
                                capture_output=True, timeout=15)
        if result.returncode:
            print("Setup unavailable or account configuration already exists; nothing replaced.", flush=True)
            return
    except (OSError, subprocess.TimeoutExpired):
        print("SSH unavailable; no credential requested.", flush=True)
        return
    path = "/" + secrets.token_urlsafe(32)
    done = False

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body.encode())

        def valid(self):
            return self.path == path and self.headers.get("Host") == authority

        def do_GET(self):
            if not self.valid() or done:
                self.respond(404, "This setup link is unavailable.")
                return
            self.respond(200, '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SmartSpend — Telegram setup</title><style>body{font:17px system-ui;max-width:560px;margin:48px auto;padding:24px;background:#f5f5f7}input,button{box-sizing:border-box;width:100%;padding:14px;margin:8px 0 22px;border:1px solid #bbb;border-radius:12px;font:inherit}button{background:#0088cc;color:white;border:0}code{overflow-wrap:anywhere}</style>
<h1>Telegram sign-in</h1><p>For <b>@smartspend_aibot</b>. In BotFather → Web Login, add this exact Allowed URL:</p>
<p><code>https://ubuntu.onca-albacore.ts.net:10000/oauth/account/telegram/callback</code></p>
<p>Use the Web Login client ID and secret, <b>not the Bot API token</b>. Credentials go privately to your Ubuntu server; they are not shown in chat.</p>
<form method="post" autocomplete="off"><label>Client ID<input name="client_id" inputmode="numeric" required maxlength="100"></label>
<label>Client secret<input name="client_secret" type="password" required maxlength="4096" autocomplete="new-password"></label>
<button>Save privately on Ubuntu</button></form>''')

        def do_POST(self):
            nonlocal done
            if not self.valid() or done or self.headers.get("Origin") != origin:
                self.respond(403, "Request refused. Reopen the setup link and submit there.")
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 16384 or self.headers.get("Content-Type", "").split(";")[0] != "application/x-www-form-urlencoded":
                    raise ValueError()
                fields = parse_qs(self.rfile.read(size).decode(), strict_parsing=True, max_num_fields=2)
                if set(fields) != {"client_id", "client_secret"} or any(len(v) != 1 for v in fields.values()):
                    raise ValueError()
                client, secret = fields["client_id"][0].strip(), fields["client_secret"][0].strip()
                if not client.isascii() or not client.isdigit() or not 1 <= len(client) <= 100 or not 10 <= len(secret) <= 4096 or any(c.isspace() for c in secret) or secret.startswith("bot") or ":" in secret:
                    raise ValueError()
                value = json.dumps({"telegram": {"client_id": client, "client_secret": secret}}).encode()
                result = subprocess.run(SSH + [shlex.join(["python3", "-c", SAVE])],
                                        input=value, capture_output=True, timeout=25)
                if result.returncode:
                    self.respond(502, "Save could not be confirmed. Ask Codex to check before retrying; no existing configuration was replaced.")
                    return
                done = True
                self.respond(200, "<h1>Saved privately</h1><p>You can close this page and tell Codex to continue. Real login has not yet been tested.</p>")
                print("Telegram account configuration saved privately on Ubuntu. No credentials printed.", flush=True)
            except (ValueError, UnicodeError, OSError, subprocess.TimeoutExpired):
                self.respond(400, "Setup could not finish. Check Web Login values; do not paste them into chat.")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    server.timeout = 1
    authority = "127.0.0.1:" + str(server.server_port)
    origin = "http://" + authority
    print("Open: " + origin + path, flush=True)
    deadline = time.monotonic() + 900
    try:
        while not done and time.monotonic() < deadline:
            server.handle_request()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
