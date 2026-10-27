# SmartSpend server tools — optional integrations and MCP

The normal mobile surface is **Settings → Integrations**, with Google Sheets and
Notion account consent. MCP is an AI-client/server protocol, not a setting every
iPhone user needs to configure. Its legacy manual snapshot/patch tooling remains
available to operators; it is no longer a visible mobile settings entry.

The `smartspend-sync` service has a separate [operator guide](../docs/CONNECTED_SYNC.md)
for per-installation ownership, optional public-provider OAuth, incremental ledger
sync, history and remote MCP. Public installation signup is **off by default**;
`--allow-device-enrollment` enables a bounded preview, not production App Attest
or cross-device accounts. Provider app credentials are configured once by the
operator; every user separately authorizes their own Google/Notion account.

New dedicated provider tables have a sync implementation. Existing Notion tables
support **schema discovery and mapped read-only preview only**: no import, schema
modification or bidirectional sync. Running the manual commands below does not
enable either provider flow or deploy this branch.

A real MCP server for reading expenses and staging reversible changes from an AI
client. Built on the [official MCP Python SDK](https://py.sdk.modelcontextprotocol.io/v1/),
pinned to its supported `1.x` API in `uv.lock`.

**The manual workflow is not live iPhone sync or a public ChatGPT connector.** In
this mode the iOS app keeps its records locally. The owner explicitly exports a snapshot, runs
this server against a separate SQLite mirror, and reviews/imports a patch in the
app. Until that last step, a tool saying "created" means **created in the server
mirror, pending app review**, not saved on the iPhone.

## Run locally

Requires Python 3.11+ and [uv](https://docs.astral.sh/uv/). From this directory:

```sh
uv sync --frozen
uv run smartspend-mcp --db .data/ledger.sqlite3 import-snapshot /absolute/path/to/app-snapshot.json
uv run smartspend-mcp --db .data/ledger.sqlite3 status
uv run smartspend-mcp --db .data/ledger.sqlite3 serve
```

The last command speaks **stdio MCP**, not human-readable CLI output. It opens no
HTTP port. Writes are disabled by default; owner opt-in is explicit:

```sh
uv run smartspend-mcp --db .data/ledger.sqlite3 serve --allow-writes
```

An MCP-capable desktop/CLI host can launch it with this configuration (replace
absolute paths; client-specific configuration format may differ):

```json
{
  "mcpServers": {
    "smartspend": {
      "command": "/absolute/path/to/uv",
      "args": [
        "run", "--frozen", "--directory", "/absolute/path/to/SmartSpend/mcp-server",
        "smartspend-mcp", "--db", "/absolute/private/path/ledger.sqlite3",
        "serve", "--allow-writes"
      ]
    }
  }
}
```

Remove `--allow-writes` for read-only access. No API keys or passwords are needed
for stdio. The host's permission/approval controls still matter: **tool annotations
are hints, not proof that a human approved a transaction**.

At most 1,000 operations may be pending, matching the app's reviewed batch limit.
Review/import/reconcile that batch before further writes; retries remain safe at
the limit. This also bounds an AI client's unreviewed write queue.

## Optional GPT-6 Luna text interpreter (server only)

The separate **owner CLI** `smartspend-ai` uses
[`openai/gpt-6-luna` on OpenRouter](https://openrouter.ai/openai/gpt-6-luna) to turn
an English/Russian transcript into **review-only drafts**. It is not an MCP tool:
connecting an MCP client does not enable cloud calls or cause extra charges.
This CLI does not record a microphone, connect a phone, expose an HTTP listener
or write transactions. The separate optional iPhone gateway is described below. Existing MCP tools
continue to work without an OpenRouter account.

Use a dedicated, spending-limited OpenRouter key. If a key was pasted into chat,
revoke/rotate it in OpenRouter; do not paste its replacement here, put it in source,
command arguments, shell history, or the iPhone bundle. On the **backend host**:

```sh
mkdir -p .data
uv run smartspend-ai --config .data/openrouter.json configure
uv run smartspend-ai --config .data/openrouter.json status
```

`configure` accepts hidden interactive terminal input only and creates a new
mode-600 credential file. It refuses to overwrite existing credentials or fall
back to echoed input. Keep its parent directory private. `status` checks local
configuration only: it does **not** validate credit, network access or API success.
The private `.data/` directory and JSON files are Git-ignored. To rotate later,
configure a new filename, explicitly test it, then update the command's path.
Do not delete a working credential until its replacement is verified.

Alternatively use server-provided secrets with these nonsecret settings:

```dotenv
OPENAI_BASE_URL=https://openrouter.ai/api/v1
OPENAI_MODEL=openai/gpt-6-luna
# Supply OPENAI_API_KEY privately, or use OPENROUTER_API_KEY.
```

Omit `--config` to use these environment variables. This version accepts only
this exact endpoint/model; it will not send credentials to an arbitrary base URL
or silently replace Luna. It requests `reasoning.effort: none` for lightweight
extraction, strict JSON Schema and providers supporting the requested parameters.
It requests providers that disallow training data collection, **not a blanket
zero-retention guarantee**: review OpenRouter/provider privacy policies before
sending sensitive transcripts.

After explicitly importing an app snapshot, one owner-authorized billable call:

```sh
uv run smartspend-ai --config .data/openrouter.json interpret \
  --db .data/ledger.sqlite3 --reference-date 2026-10-20 \
  --time-zone Asia/Tashkent --send-to-ai < /private/path/transcript.txt
```

This sends only the transcript, up to 100 category names/IDs, default currency,
explicit reference date and timezone. It sends no audio, past expenses, salary,
budgets, or ledger identity. The transcript is limited to 4,000 characters and the
response to 10 drafts, 2,200 output tokens and 64 KiB. Missing/ambiguous amounts
must remain null; decimal strings and existing category IDs are validated again
locally, even when a provider claims schema compliance. Amounts require verbatim
transcript evidence; this does **not** prove the numerical interpretation is correct.
Date phrases are returned for client-side resolution/confirmation, not guessed
timestamps. Explicit foreign currencies are flagged, never converted. Income,
loans, cards and counterparties can be recognized in a draft but are flagged as
unsupported by the current app; they never become expenses automatically.

Every response has `requires_review: true` and `saved: false`. This CLI has no
ledger write path. It has no automatic retries, redirects, public listener, or
provider response-body logging. Its explicit output contains financial text;
do not pipe it to shared logs. The connect/read timeouts and elapsed-stream guard
bound stalled requests; a timeout is not proof the provider did not bill a call.
The mocked tests verify validation/transport safety, **not real EN/RU accuracy or
iPhone latency**. A real paired evaluation still needs a privately configured key.

On the private Ubuntu installation, replace `uv run smartspend-ai` with
`/home/ubuntu/smartspend-mcp/.venv/bin/smartspend-ai` and use absolute paths.

## Private iPhone voice preview

On Dashboard or Expenses, tap the microphone button at the bottom to start listening.
The **+** button next to it opens only the manual form. Recording requires microphone/speech
permission. The current inline voice flow uses Apple's on-device English recognizer.
Runtime language/model availability is checked;
unavailable local recognition does not silently fall back to uploading audio.
The transcript remains editable; keyboard dictation follows iOS's own settings.

The separate `smartspend-voice` service binds **127.0.0.1 only**, port 18769.
`deploy/smartspend-voice.service` is an owner user-service example. Configure the
provider key privately first, then install/start this unit using the appropriate
account and absolute paths. Unlike the stdio MCP service, this private gateway
has a network transport and can make owner-approved billable model calls.

For tailnet-only access use Tailscale Serve on an unused HTTPS port:

```sh
sudo tailscale serve --bg --https=9443 http://127.0.0.1:18769
```

Inspect `tailscale serve status --json` first. Preserve existing services on other
ports; never run a global `reset`. This setup needs host-admin authority for Serve
and leaves 443/8443 untouched. In this private mode both devices need Tailscale.
For the owner's temporary domain-free preview, public Funnel is explicitly
authorized on **10000 only**, forwarding to the same loopback service:

```sh
sudo tailscale funnel --bg --https=10000 --yes http://127.0.0.1:18769
```

The iPhone default is `https://ubuntu.onca-albacore.ts.net:10000`; no phone VPN
is required in this mode. The endpoint is publicly reachable, but model calls
still require a paired phone bearer. Existing 443/8443/9443 listeners are preserved.
The Mac helper accepts `--public-funnel` and uses hidden sudo input; no password
or invite belongs in shell arguments or shared logs. To stop only this public
listener: `sudo tailscale funnel --https=10000 off`. Never use global reset.
Funnel is a temporary single-owner preview, not an App Store production backend.
Do not substitute insecure HTTP, disable TLS validation, or bind to 0.0.0.0.
The phone requires a valid HTTPS `.ts.net`
server address, performs normal certificate checks, and rejects HTTP redirects.

Issue a phone pairing code from the owner CLI, keeping output out of shared logs:

```sh
smartspend-voice --state /private/path/voice.sqlite3 pair-code
```

The 32-character code has 192 bits of entropy, expires in ten minutes, is
single-use, and locks after five
incorrect attempts. Up to five phones can be paired. Enter it in **Voice
connection** on the iPhone, never the OpenRouter key. A separate random phone
credential is saved in iOS Keychain as `WhenUnlockedThisDeviceOnly`; only its hash
is persisted on the server. Disconnect revokes that credential and removes the
local Keychain item. If the server is offline, local removal still works; owner
CLI `revoke-all` can revoke every phone later. Do not log API tokens or pairing
codes. This remains a single-owner private preview, not public OAuth/multi-user
authentication suitable for an App Store service.

Gateway contract (JSON, no cookies or audio):

- `GET /health`: service status only, no provider configuration.
- `POST /v1/pair`: `{ "code": "32-character one-use invite" }` → one phone bearer credential.
- `POST /v1/drafts`: phone bearer required; explicit `consent: true`, canonical
  `request_id` UUID, transcript, categories, currency, reference date and timezone.
- `DELETE /v1/device`: revoke the calling phone credential.

Requests have a 64-KiB cap, no compressed bodies, one active model call, ten calls
per minute and 100 calls per UTC day across this owner's phones. Unauthorized,
malformed or nonconsensual requests cannot call the model. Budget counters contain
only hashed device IDs/timestamps, not text. Successful drafts stay in memory for
at most five minutes, up to 32 requests, to avoid duplicate billing on a retry with
the same device/request UUID and payload. Changed payloads with the same ID fail;
after eviction, expiry or server restart a retry can bill again. No automatic
retry is performed. Access logging is disabled. Hostname checks are enabled.

The gateway never opens the expense ledger and never saves an expense. iPhone
drafts must be reviewed one at a time in the existing Add Expense form. Unsupported
income/loan/card/foreign-currency drafts cannot be saved as ordinary expenses.
The legacy-named `date_expression` field now contains an exact `YYYY-MM-DD` or
null. GPT resolves clear relative dates using each request's `reference_date`
and `time_zone`, never the server clock; invalid/unresolved dates are rejected.
Missing or ambiguous amounts need manual entry; missing dates need explicit
date confirmation. Stable draft IDs prevent repeated Save taps from duplicating
a reviewed expense. A failed local storage flush leaves the review open.

## Run privately on Ubuntu over SSH

The same stdio server can run on a private Ubuntu host. No public web listener,
reverse proxy or OAuth workaround is necessary for this transport:

```sh
python3 -m venv /home/ubuntu/smartspend-mcp/.venv
/home/ubuntu/smartspend-mcp/.venv/bin/pip install /home/ubuntu/smartspend-mcp
```

Use a private database path and initialize it with an explicitly transferred
snapshot. A compatible local client can invoke an SSH subprocess:

```json
{
  "mcpServers": {
    "smartspend-private": {
      "command": "ssh",
      "args": [
        "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-i", "/absolute/path/to/dedicated_private_key",
        "ubuntu@YOUR_PRIVATE_HOST",
        "/home/ubuntu/smartspend-mcp/.venv/bin/smartspend-mcp",
        "--db", "/home/ubuntu/smartspend-mcp/.data/ledger.sqlite3",
        "serve", "--allow-writes"
      ]
    }
  }
}
```

Establish and verify the SSH host key separately. Use a dedicated restricted key
and Unix account for production use, ideally a forced command with forwarding/PTY
disabled. Do not reuse an unrestricted administrative key in a distributed client.
The server does not provide multi-user tenant isolation: **one database is one
owner/ledger**. Separate owners require separate processes/files/accounts until a
real authenticated multi-tenant service is implemented.

Browser ChatGPT remote connectors need an authenticated reachable MCP transport;
an SSH/stdio process is not such a connector. Do not expose an unauthenticated
Streamable HTTP endpoint to bridge this gap. A hosted version still needs verified
account linking, token scopes/revocation, per-user storage, consent, authenticated
app sync and conflict handling before real financial data should be connected.
For a private ChatGPT connection, [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
is another option where the account/workspace permits it. Tunnel setup and host
access controls are separate steps; this package does not create that connection.

## Available tools

| Tool | Purpose |
| --- | --- |
| `get_context` | Ledger UUID, currency, timezone, revision, counts, pending operations |
| `list_categories` | Stable existing category UUIDs |
| `list_expenses` | Literal title search, date/category filters, keyset pagination |
| `get_expense` | Exact record, archived status, row revision and fingerprint |
| `get_spending_summary` | Exact decimal totals by category and local calendar day |
| `get_expense_history` | Bounded version/audit history |
| `create_expense` | Stage a new positive expense |
| `update_expense` | Stage a full replacement with a current revision precondition |
| `archive_expense` | Reversible removal, no hard-delete |
| `restore_expense` | Restore an archived record |
| `undo_operation` | Auditable inverse if the record has not changed since that action |

Date filters are **inclusive start, exclusive end**. Timestamps require an explicit
offset; results normalize to UTC milliseconds. Summary day grouping uses the
ledger's IANA timezone unless explicitly overridden. No "today" date is guessed.
Daily breakdowns are capped at 366 populated days (`byDayTruncated` indicates
longer histories); use narrower ranges for further days. Full totals remain exact.

Money is a positive **decimal string**, e.g. `"15800"` or `"12.5"`, never a float,
formatted display string or an inferred currency. There is one explicit supported
ISO currency per ledger, with no currency conversion/relabeling. To match the
existing iOS Double model safely, amounts are less than one trillion, at most six
fractional digits and at most fifteen significant decimal digits. Totals use
Python `Decimal`, not floating point.

Every intended write needs a fresh UUID `idempotency_key`; retries reuse it.
Reusing a key with different arguments fails. Edits/archive/restore need the
current **row** `expected_revision` from `get_expense`, not the ledger revision.
Simultaneous writes are serialized in SQLite transactions. Revisions reject stale
edits rather than last-write-wins overwriting them. Pagination is at most 100 rows;
cursors become invalid after writes, avoiding silent skips while data changes.

No tool can read arbitrary files, import arbitrary snapshots, run a shell, change
credentials, choose another database, or export files without owner CLI action.
Expense titles are untrusted user data, not instructions.

## iPhone snapshot → MCP → reviewed patch → iPhone

1. In SmartSpend's integration exchange screen, export a snapshot explicitly.
2. Move that file privately to this machine/server. It contains financial data.
3. Import it with the owner CLI command above, then connect an MCP client.
4. AI reads or stages writes in this mirror. Nothing automatically changes in iOS.
5. Export pending operations to a **new** filename:

   ```sh
   uv run smartspend-mcp --db .data/ledger.sqlite3 export-operations /absolute/private/path/review-patch.json
   ```

6. Import the patch in SmartSpend, inspect the preview, and explicitly approve it.
   The app validates identity, currency and fingerprints before applying it.
7. Export a fresh app snapshot containing `appliedOperationIds`. Get the server's
   current **ledger** revision using `status`, then reconcile explicitly:

   ```sh
   uv run smartspend-mcp --db .data/ledger.sqlite3 import-snapshot /absolute/private/path/new-snapshot.json --expected-revision 4
   ```

Exporting a patch **never clears its queue**: interrupted transfers/retries are
safe. A snapshot cannot silently overwrite a different owner/currency. Reimport
requires an exact ledger-revision precondition and acknowledgment of **all pending
operations** by the app. If a patch conflicts with newer app edits, resolve the
conflict explicitly; do not forge acknowledgments or blindly overwrite records.
This first version deliberately has no automatic conflict resolver/discard command.
Before starting a replacement mirror, retain the original database and history.

Absent rows in a reviewed reimport become archived tombstones, not hard-deletes.
Removed categories can leave historical tombstones; restore requires a category
that still exists. Snapshots/history cover expenses, **not** the whole app's salary,
budgets, debts, account/card balances or settings.

The existing iPhone Deleted Expenses screen expires its tombstones after 30 days.
The server audit trail is retained, but a restore patch cannot restore an ID whose
app tombstone is already missing. After reviewing the retained history, recovery
can instead be staged as a new record with a new UUID. This is not yet a unified,
permanent cross-device Trash/version-history feature.

## Wire contract, version 1

Snapshot (all UUID examples below are synthetic):

```json
{
  "schemaVersion": 1,
  "ledgerId": "11111111-1111-4111-8111-111111111111",
  "currency": "UZS",
  "timeZone": "Asia/Tashkent",
  "categories": [{
    "id": "22222222-2222-4222-8222-222222222222",
    "name": "Food", "iconSystemName": "fork.knife", "colorName": "orange"
  }],
  "expenses": [{
    "id": "33333333-3333-4333-8333-333333333333",
    "title": "Lunch", "amount": "15800",
    "categoryId": "22222222-2222-4222-8222-222222222222",
    "date": "2026-10-20T07:30:00.000Z"
  }],
  "archivedExpenses": [],
  "appliedOperationIds": []
}
```

`timeZone` is optional and defaults to UTC. `archivedExpenses` and
`appliedOperationIds` are optional arrays. Active/archived UUIDs must not overlap.
Category icon/color are optional metadata. The CLI validates the whole snapshot
before transactionally changing the mirror; snapshots are limited to 50 MiB.

Exported patch:

```json
{
  "schemaVersion": 1,
  "ledgerId": "11111111-1111-4111-8111-111111111111",
  "currency": "UZS",
  "operations": [{
    "id": "44444444-4444-4444-8444-444444444444",
    "kind": "create",
    "expenseId": "55555555-5555-4555-8555-555555555555",
    "baseFingerprint": null,
    "expense": {
      "id": "55555555-5555-4555-8555-555555555555",
      "title": "Taxi", "amount": "20000",
      "categoryId": "22222222-2222-4222-8222-222222222222",
      "date": "2026-10-20T08:30:00.000Z"
    }
  }]
}
```

Operations are ordered. `kind` is `create`, `update`, `archive` or `restore`.
`expense` contains the full post-operation record, including archive/restore;
the `kind` carries the active/archived state. Create has a null fingerprint and
must fail if the ID exists even as a tombstone. All other operations require the
fingerprint of their immediately preceding state; restore requires an archived
record, archive/update an active one. Each operation UUID must be remembered by
the app for duplicate-safe import and included in the next snapshot receipt.

**Fingerprint algorithm**, shared with Swift CryptoKit:

1. Canonicalize UUIDs lowercase, amount without redundant fractional zeros, date
   UTC exactly `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`. Preserve title's exact UTF-8 bytes.
2. Fields in order: `id`, `title`, `amount`, `categoryId`, `date`.
3. Prefix **each** UTF-8 field with its byte length as an unsigned 32-bit
   **big-endian** integer; concatenate the five prefixed byte sequences.
4. SHA-256 that buffer; encode lowercase hexadecimal.

This avoids cross-language JSON formatting differences and ambiguous embedded
newlines. It is a conflict token, **not a signature or authentication credential**.

## Privacy, persistence, verification

- Database directories newly created by the server use mode `0700`; database and
  exported patches use `0600`. Existing parent-directory permissions are untouched.
- SQLite is **not encrypted** by this package. Use disk encryption, private Unix
  permissions and encrypted transport. Keep DB files, snapshots and patches out of
  Git; `.gitignore` here covers common private artifacts, not arbitrary filenames.
- Connected AI hosts can receive the expense fields requested through tools and
  may send them to their model provider. This is not "everything stays on iPhone".
  Explicitly choose a trusted host/provider and grant read/write access separately.
- No real user data is seeded or auto-discovered. Synthetic fixtures only in tests.
- Keep private backups; version history is not disaster recovery or live sync.
- Reads do not invoke an LLM or external API. No subscription is required by this
  server; your chosen AI host or server hosting may have its own costs.

Run tests:

```sh
uv run pytest -q
```

Tests cover a real stdio client `initialize`/`tools/list`/`tools/call`, default
read-only behavior, decimals/timezones, safe pagination, parallel retries,
persistence, validation, ledger/category/currency ownership, stale conflicts,
archive/restore/undo, fingerprint chaining and receipt-guarded reimport. They do
not prove a public ChatGPT connection or autonomous real-device sync.
