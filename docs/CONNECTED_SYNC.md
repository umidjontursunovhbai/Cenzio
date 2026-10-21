# Optional integrations and connected sync preview

This development branch adds an opt-in canonical expense ledger, foreground iPhone
sync, Google Sheets/Notion adapters, history and OAuth-protected remote MCP. It is
separate from [manual snapshot/patch exchange](../mcp-server/README.md) and the
transcript-only voice gateway. The mobile entry is **Settings → Integrations**;
technical MCP/file-exchange tools are not exposed in normal mobile settings.

Deployment evidence must stay separate from source: the October 20 private
service deployed at revision `aa06b38` had healthy sync, rejected unauthenticated
requests, and exposed the previously configured HTTPS routes alongside voice.
That does **not** mean the new per-installation enrollment, public Notion OAuth,
or mapped-table preview in this branch is deployed. This turn made no deployment:
SSH to Ubuntu was unavailable from the Mac's current tailnet. No live
Google/Notion/ChatGPT end-to-end success is established by mocked tests or this
guide. PR review, merge, deployment, device install and App Store release are
separate gates.

## Connect an iPhone

1. The operator deploys a dedicated HTTPS origin and configures the Google/Notion
   **public application** credentials once. Users must not create OAuth clients,
   paste integration tokens, or configure MCP to connect their own accounts.
2. In **Settings → Integrations**, choose Google Sheets or Notion. Review the
   upload consent, then authorize the chosen provider in its browser consent
   screen. Each installation connects its own authorized accounts/workspace;
   one owner's provider token is not a shared credential for everybody.
3. Google creates a dedicated spreadsheet. Notion lets the user choose an
   OAuth-shared page for a new dedicated database. Existing Notion tables can
   instead be inspected through **read-only mapping preview**, described below.
4. The initial sync bootstrap sends categories, current expenses and Trash once,
   only after upload consent and only into an empty ledger. An initialized ledger
   is never replaced by another snapshot. Different existing contents are blocked
   for reviewed reconciliation rather than silently merged.

Self-service enrollment is **disabled unless `serve --allow-device-enrollment`
is explicitly supplied**. It is a bounded installation-ownership preview, not a
consumer account system: a random 256-bit owner proof is retained in device-only
Keychain, and the server verifies it before resuming/renewing that installation.
A ledger UUID alone cannot claim another installation or an operator-created
ledger. Session grants last 30 days and can be renewed only by the same proof;
revoked installations cannot renew. Losing the Keychain proof is not account
recovery; there is no supported cross-device login, transfer or recovery flow.
The durable expense outbox contains no credential.

Default server limits are 1,000 lifetime installation records, 100 new
installations per rolling day, 30 enrollment attempts per direct peer/hour and
3,000 attempts globally/hour. Failed ownership guesses count. Behind a loopback
proxy, peers may share that limit; untrusted forwarding headers are not accepted
as identity. These bounds are **not App Attest** or sufficient internet abuse
protection. Configure an edge policy, resource/storage limits, operational
monitoring, a verified App Attest strategy or equivalent production authentication,
and reviewer access before enabling public enrollment. Do not ship the preview as
production account security.

Expense changes are checked about every 12 seconds while the app is open; local
edits are debounced for 800 ms. Provider workers poll independently about every
15 seconds. Offline edits retry later; there is no guaranteed background or
instant delivery. Concurrent edits and unsafe removals pause for review.
Disconnecting a provider stops scheduled changes and removes that connection's
server tokens. Notion also attempts provider revocation. Google project-wide grant
revocation is deliberately not automatic because it could disconnect the same
person's other installations; remove the grant in Google settings when desired.
Disconnect does not erase the external table, server history or backups. The
disconnect response waits for a worker already using that connection to finish.

## Start the private service

Requires Python 3.11+ and `uv`. Run from `mcp-server/`. Examples use synthetic
identities and paths; replace the ledger with the actual reviewed UUID.

```sh
uv sync --frozen
umask 077
mkdir -p /private/tmp/smartspend-preview
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  create-token --ledger 11111111-1111-4111-8111-111111111111 \
  --public-url https://sync.example.com \
  --output /private/tmp/smartspend-preview/iphone-connection.json --days 30
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  serve --public-url https://sync.example.com --port 18770
```

Use a persistent private directory for deployment, not the temporary example.
The root must be owner-owned mode 0700. `create-token` exclusively creates a mode
0600 file containing `server`, `ledgerId`, `token`; it prints only the grant ID,
not the token. Transfer the server/token to the phone privately, never through
chat, logs, shell arguments or source. `--read-only` limits grants to
`ledger:read`; normal phone sync/bootstrap needs `ledger:write`. Grants expire
(default 30 days, maximum 90) and can be revoked with `revoke --grant-id`.

`serve` binds only `127.0.0.1:18770`. Configure and verify a dedicated HTTPS reverse
proxy separately, preserving the expected host. The CLI does not deploy it, change
ports of the voice service or register provider OAuth clients. Installation
enrollment is off unless the explicit flag above is supplied.
REST routes are `/v1/sync/{context,snapshot,bootstrap,exchange,categories,restore}`
and `/v1/sync/history/{expense_id}`; `/health` checks this service only.
`GET /v1/connectors/capabilities` reports configured enrollment/providers without tokens;
`POST /v1/device/enroll` requires installation proof and explicit consent. Voice
credentials are not accepted as sync credentials. Operator-issued tokens remain
available for controlled administration; they are not the normal mobile flow.

## Google Sheets enrollment

Register a Google web OAuth client with the exact callback
`https://sync.example.com/oauth/google/callback`. Store its downloaded web-client
JSON in an owner-only file, then add this option to `serve`:

```sh
--google-client-config /private/operator/google-web-client.json
```

If the creation dialog's JSON download failed, the owner can create a replacement
secret manually in Google Console and enter it at a hidden terminal prompt:

```sh
uv run smartspend-sync --root /private/operator/sync configure-google-client \
  --client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --public-url https://sync.example.com \
  --output /private/operator/google-web-client.json
```

Never put the secret in command arguments, chat, screenshots or the repository.
This command refuses visible input fallback and existing output files, and writes
an owner-only file. Keep the existing secret until the replacement works; do not
delete the OAuth client. The callback must be deployed before testing login.

After native enrollment, tap **Google Sheets → Connect** and approve the separate
consent. Authorization uses S256 PKCE and single-use state and requests only
`https://www.googleapis.com/auth/drive.file`. It creates a **new dedicated**
SmartSpend spreadsheet with `Sheet1`; choosing an existing file requires Picker
and is unsupported. The service polls ready Google connections about every 15
seconds independently of whether the phone is open. Phone delivery still waits
for foreground sync.

Google access/refresh tokens are encrypted with a local Fernet key in the private
`google-oauth/` directory and refreshed before expiry. Protect that key and database
together; encryption does not protect against compromise of the service account.
An uncertain enrollment/create outcome stays pending instead of creating another
sheet automatically. Owner reconciliation is required; no repair CLI is provided.
Do not remove pending state and repeatedly reconnect without inspecting the outcome.

Google Cloud's project/client configuration is an operator task, not a task for
each user. In **Testing**, external-user sign-in is limited to configured test
users and refresh-token lifetime may be restricted. An enabled Drive/Sheets API
alone does not make OAuth public. Before general availability, configure the
external audience, approved domains and consent disclosures, production status,
exact HTTPS callback, minimum scopes and any required Google verification; test
with a separate eligible account. Do not promise universal sign-in while the
OAuth app is still test-user-only. No API key or client secret belongs in iOS.

## Notion public OAuth enrollment

The operator creates one **public Notion connection** that other users can
authorize in their own workspaces. An internal workspace-only token does not
provide multi-user onboarding. Configure the exact callback
`https://sync.example.com/oauth/notion/callback` and the minimum page/database
capabilities needed to read/update expense records and create the dedicated table.
Keep the application secret in an owner-only server file, never in the app:

```json
{
  "client_id": "YOUR_PUBLIC_NOTION_CLIENT_ID",
  "client_secret": "ENTER_PRIVATELY_NOT_IN_SOURCE",
  "redirect_uri": "https://sync.example.com/oauth/notion/callback"
}
```

This is the **file shape**, not a usable credential or a suggestion to paste a
secret into chat. Restrict the parent directory to 0700 and file to 0600. Add
`--notion-client-config /private/operator/notion-public-client.json` to `serve`.
The app reports Notion as unavailable if this server configuration is absent.

Prefer the hidden-input helper instead of writing the secret through shell text:

```sh
uv run smartspend-sync --root /private/operator/sync configure-notion-client \
  --client-id YOUR_PUBLIC_NOTION_CLIENT_ID \
  --public-url https://sync.example.com \
  --output /private/operator/notion-public-client.json
```

It refuses existing output files and visible-input fallback. Enter the secret
only at its hidden prompt; do not put it in an argument, screenshot or chat.

Every user then follows their own Notion OAuth consent/page picker. State is
single-use and ledger-bound; tokens are encrypted in private `notion-oauth/`
storage and rotating refresh outcomes are guarded against ambiguous retries.
Authorization alone does not start Notion sync. For the new-table flow, the user
explicitly chooses an accessible shared page; the service creates **one dedicated**
SmartSpend database and its data source there, leaving other content untouched.
The selected schema uses Title/title, Amount/number, Date/date, Deleted/checkbox,
and SmartSpend ID, Category ID, Currency/rich_text. No broad financial-row search
is needed to select the destination. Unknown create outcomes stay pending for
owner reconciliation rather than automatically creating a duplicate table.

Public-integration configuration, capabilities, consent, token revoke/refresh and
real workspace behavior still need live validation. No real workspace/table
write is authorized merely by the presence of the preview UI or these examples.

## Existing Notion tables: read-only preview only

Users may already have a table with their own property names and types—for
example Expense/title, Amount/number, Category/select and Date/date. Do not
rename it, add identity columns or create a second table without approval.
The current implementation can discover OAuth-shared data-source metadata/schema
and, after separate consent, preview the **explicitly chosen** table's rows.

Mapping is per ledger, not hardcoded to English property/category names:

```json
{
  "title": "Expense",
  "amount": "Amount",
  "date": "Date",
  "category": "Category",
  "categoryMap": {"Groceries": "22222222-2222-4222-8222-222222222222"}
}
```

Category targets must belong to the authenticated ledger's current categories.
Category source properties may be select or rich text. Currency and timezone
come from the canonical ledger, not caller-supplied values; date-only values are
interpreted in that timezone. The preview checks complete bounded pagination,
rejects incomplete/duplicate results, reports unmapped category labels and
returns at most five samples. Archived rows are excluded, not treated as delete
instructions. Schema/row properties and extra columns are never modified.

Routes: `GET /v1/connectors/notion/sources` returns metadata/schema;
`POST /v1/connectors/notion/preview` requires
`{consent:true,dataSourceId,mapping}`. Its result explicitly says `readOnly:true`
and `canSync:false`. It does **not** bind the existing table, import expenses,
mark it connected, or schedule sync. No canonical financial copy is persisted by
preview. This is a staged safety boundary, not completed bidirectional sync.

Full existing-table sync still needs durable page↔expense identities and
destination/mapping revision binding; safe unknown-create handling without a
Notion idempotency guarantee; mapped-field-only updates preserving extras;
explicit reverse category/date/currency semantics; conflict and trash guards;
reviewed initial merge; and reconnect/disconnect worker serialization. Matching
rows by similar titles/amounts is not a safe substitute.

## Provider configuration and workers

Public Notion OAuth above is the consumer connection path. The following legacy
token-based runner is an **operator-only alternative**, not a mobile-user setup
requirement. It expects a dedicated data source prepared exactly as follows:
`Title` (title), `SmartSpend ID`,
`Category ID`, `Currency` (rich text), `Amount` (number), `Date` (date), `Deleted`
(checkbox). Category IDs must already exist in the canonical ledger. Sheets use
the seven header cells `SmartSpend ID`, `Title`, `Amount`, `Category ID`, `Date`,
`Currency`, `Deleted`, in that order; amounts/dates must be valid for the ledger.

Connector JSON accepts **exactly** these keys, all nonempty strings:

| `provider` | Keys in addition to `provider`, `ledgerId`, `connectorId` |
| --- | --- |
| `google_oauth` | `googleClientConfig`, `publicUrl` |
| `google_sheets` | `token`, `spreadsheetId`, `tab` |
| `notion` | `token`, `dataSourceId` |

Prefer `google_oauth` for refresh-managed enrollment. `google_sheets` is an owner
injected access token, without the refresh manager. Connector files must be
owner-owned regular files, mode 0600, at most 64 KiB. Reuse a connector ID only
for the same ledger/provider/resource/tab; changing scope requires a new ID.

For example, this local script creates a fresh Notion config using hidden terminal
input, without placing a token in shell history. The parent directory must already
be private; substitute the synthetic identities before running. It refuses overwrite.

```sh
uv run python - <<'PY'
import getpass, json, os, warnings
config = {
    "provider": "notion",
    "ledgerId": "11111111-1111-4111-8111-111111111111",
    "connectorId": "notion-personal",
    "dataSourceId": "22222222-2222-4222-8222-222222222222",
}
warnings.simplefilter('error', getpass.GetPassWarning)
config["token"] = getpass.getpass("Notion integration credential: ")
fd = os.open('/private/tmp/smartspend-preview/notion.json',
             os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(config, stream)
PY
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  connector-run --config /private/tmp/smartspend-preview/notion.json
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  connector-status --config /private/tmp/smartspend-preview/notion.json
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  connector-watch --config /private/tmp/smartspend-preview/notion.json --interval 15
```

`connector-watch` runs in the foreground (5–3600 second interval); supervise it
with launchd/systemd for persistence. It honors durable provider retry state and
prints count-only status. Google enrollment through `serve` already has a worker;
an extra watch is optional for separately configured connectors.

Use `connector-status --config PATH --details` privately to inspect financial
records, conflict details and digests. After reviewing the exact canonical/provider
versions, run `connector-resolve --config PATH --expense-id UUID --prefer canonical`
(or `provider`) with `--conflict-digest DIGEST_FROM_REVIEW`. Stale digests are rejected.

A single explicit `Deleted` flag can archive an expense. Multiple deletion proposals
or missing known rows require separate review and `connector-run --config PATH
--confirmation-digest DIGEST_FROM_REVIEW`. The digest approves the current proposed
UUID/revision/record set only. Missing/empty/unavailable sources never automatically
erase the ledger. Provider errors and incomplete scans preserve canonical data.

## History and backups

SQLite stores canonical records, immutable before/after expense history, catalog
history and operation IDs. Archive is a soft deletion; History & Trash can restore
a saved version as a **new** revision. Conflicting revisions are rejected. History
is not a separate backup and provider spreadsheets are not a full app backup.

```sh
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  backup --ledger 11111111-1111-4111-8111-111111111111 \
  --output /private/tmp/smartspend-preview/ledger-backup.sqlite3
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  validate-backup /private/tmp/smartspend-preview/ledger-backup.sqlite3
```

Backup creates a separate new file and validates SQLite/record integrity. Copy it
to a separately protected location. It contains ledger/history, not grants,
connector reconciliation state, Google/Notion keys/tokens, installation ownership
keys/grants, or the full iOS app settings, budgets and goals. Validation is not a
tested disaster restore; there is no automatic
restore-backup CLI. Preserve and separately protect service configuration/state.

## Privacy and retention boundaries

Local use sends no expenses to this sync service. Enabling Integrations requires
separate upload consent and sends current/archived expense titles, amounts,
dates, category IDs/names and currency/timezone context to the configured server.
Enabled providers receive the mapped expense records; budgets, goals, salary and
microphone audio are not included by the sync protocol. Voice interpretation has
its own transcript-only consent and service, not an implicit ledger upload.

The server retains canonical expenses, immutable before/after history, operation
receipts, connection/reconciliation state, installation ownership/grant metadata
and protected backups. Provider access/refresh tokens are encrypted with private
local keys; ledger/history SQLite itself is not encrypted by this package. Use
disk encryption, owner-only filesystem permissions and HTTPS. Encryption at rest
does not protect against compromise of the running service account.

Disconnect is not erasure. It stops future polling/revokes the link as described
above but leaves existing server history, provider tables and backups intact.
Deleting the iPhone app also does not delete those copies. There is no completed
self-service server-account/history/backup erasure or automatic retention policy;
an operator must define one, provide a support/deletion procedure and reconcile
it with user disclosures before public release. Do not advertise indefinite
recoverability, zero retention, account deletion, or a full app backup. The
in-app policy, public privacy page and App Store answers must describe the final
enabled deployment; changing documentation does not publish the privacy site.

## Remote MCP authentication

`/mcp` is a separate OAuth resource server. Without OAuth configuration it returns
503. Native opaque grants are not remote MCP login. Supply `serve` with both
`--oauth-issuer https://identity.example.com` and
`--oauth-jwks-url https://identity.example.com/.well-known/jwks.json`. Configure an
upstream identity provider for authorization-code + S256 PKCE and an appropriate
MCP client. This project does not supply that authorization server or consumer
OAuth login.

The verifier checks RS256 signature, issuer, expiry and audience
`https://sync.example.com/mcp`, then applies an owner-managed subject-to-ledger
binding and intersects token scopes with binding scopes:

```sh
uv run smartspend-sync --root /private/tmp/smartspend-preview \
  bind-subject --issuer https://identity.example.com --subject synthetic-user \
  --ledger 11111111-1111-4111-8111-111111111111 --read-only
```

Omit `--read-only` only when financial writes are authorized; use
`unbind-subject --issuer ISSUER --subject SUBJECT` to remove the binding. Tool
writes update the canonical ledger durably and propagate to opted-in workers and
devices on their next successful sync. A tool response cannot prove an offline
iPhone received it. Live IdP/client registration, Google/Notion behavior, revoke/
refresh, network failures and cross-device delivery still require private live QA.
