# Private connected sync preview

This development branch adds an opt-in canonical expense ledger, foreground iPhone
sync, Google Sheets/Notion adapters, history and OAuth-protected remote MCP. It is
separate from [manual snapshot/patch exchange](../mcp-server/README.md) and the
transcript-only voice gateway. Public HTTPS deployment is **not done**; the existing
voice listener on port 10000 does not serve these routes. No live Google, Notion or
ChatGPT success is established by this guide or mocked tests. The change is for
PR review, not evidence of merge, deployment or App Store availability.

## Connect an iPhone

1. Obtain the iPhone's ledger UUID from its reviewed MCP snapshot. Keep that file
   private: it contains financial records. Provision a dedicated credential for
   that UUID with the owner CLI below; voice credentials are not accepted.
2. Deploy the separate service behind HTTPS at an origin such as
   `https://sync.example.com`. The native app accepts an HTTPS origin without a
   path, credentials, query or fragment.
3. Open Settings → AI tools (MCP) → Connected sync. Enter the server and dedicated
   token privately. Review the consent prompt. Enable initialization only for an
   empty server ledger; bootstrap sends categories, expenses and Trash once.
   Existing initialized ledgers cannot be overwritten by another snapshot.
4. Without bootstrap, initial connection requires the same ledger/currency and
   matching active/archived records. Different contents are blocked; reconcile
   with reviewed manual exchange first.

This is administrator enrollment, not consumer login. The iPhone stores its
credential in device-only, when-unlocked Keychain; the durable outbox/state file
contains no token. Changes are checked about every 12 seconds while the app is
open; local expense/Trash notifications are debounced for 800 ms. Offline edits
retry later. There is no background or guaranteed instant delivery. Concurrent
edits and unsafe removals pause sync for review rather than silently replacing data.
Disconnect removes the iPhone credential but leaves server/provider copies and
the server grant intact; revoke that grant separately.

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
ports of the voice service, register OAuth clients or provide public onboarding.
REST routes are `/v1/sync/{context,snapshot,bootstrap,exchange,categories,restore}`
and `/v1/sync/history/{expense_id}`; `/health` checks this service only.

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

After native enrollment, tap **Connect Google Sheets…** and approve the separate
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

## Provider configuration and workers

Notion currently uses an administrator-configured integration token shared only
with the selected data source; there is no public Notion OAuth enrollment flow.
Prepare properties exactly as follows: `Title` (title), `SmartSpend ID`,
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
connector reconciliation state, Google keys/tokens, or the full iOS app settings,
budgets and goals. Validation is not a tested disaster restore; there is no automatic
restore-backup CLI. Preserve and separately protect service configuration/state.

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
