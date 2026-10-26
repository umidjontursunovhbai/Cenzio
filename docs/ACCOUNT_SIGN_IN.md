# Optional account sign-in

Google, Apple and Telegram identify a SmartSpend account. They do not authorize
Google Sheets or Notion, upload local expenses, link an existing ledger, or grant
MCP access. Those permissions remain separate. The app continues working without
sign-in. Provider identities are keyed by provider and verified subject, never
merged by matching email.

## Operator setup

Configure providers once on the server, not separately on each user's phone.
Only configured providers are offered as available. Do not reuse a Sheets OAuth
callback or Telegram bot token as a sign-in secret.

Use a stable HTTPS origin for release. For the current development origin, register
these exact callbacks with the corresponding providers:

- Google: `https://ubuntu.onca-albacore.ts.net:10000/oauth/account/google/callback`
- Apple: `https://ubuntu.onca-albacore.ts.net:10000/oauth/account/apple/callback`
- Telegram: `https://ubuntu.onca-albacore.ts.net:10000/oauth/account/telegram/callback`

Google requires a web OAuth client with the account callback registered; its
consent audience/test-user restrictions still apply. Requested identity scopes
are `openid email profile`, not Drive scopes.

Apple requires Sign in with Apple configuration in the authorized paid Developer
team: a primary App ID, linked Services ID, registered domain/return URL, Key ID,
Team ID and the private signing key. Native app signing and App Groups must not
be changed merely to configure the web identity service.

Telegram uses `@smartspend_aibot`. In BotFather's **Bot Settings → Web Login**,
register allowed callback URLs and obtain the OIDC client ID and separate client
secret. A bot username or Bot API token alone is not an OIDC configuration.
Only `openid profile` is requested; no phone number or bot messaging permission.

Store only configured provider entries in an owner-owned mode `0600` JSON file,
inside a mode `0700` directory. The shape is:

```json
{
  "google": {"client_id": "YOUR_WEB_CLIENT_ID", "client_secret": "ENTER_PRIVATELY"},
  "apple": {"client_id": "YOUR_SERVICES_ID", "team_id": "YOUR_TEAM_ID", "key_id": "YOUR_KEY_ID", "private_key": "YOUR_PRIVATE_PEM"},
  "telegram": {"client_id": "YOUR_OIDC_CLIENT_ID", "client_secret": "ENTER_PRIVATELY"}
}
```

Never paste credentials into chat or source. Omit providers that are not ready.
Add `--account-client-config /private/operator/account-clients.json` to the
existing `smartspend-sync serve` command. Configure the HTTPS proxy to forward
`/v1/account` and `/oauth/account` to the sync service, preserving their paths;
keep existing voice, sync and provider routes untouched. Disable access logging
for callbacks and never log authorization headers or request/response bodies.

## Security and release checks

- Use fixed provider endpoints, signature-verified ID tokens, issuer/audience,
  expiry and nonce validation. Telegram must use its RS256 configuration.
- Provider OAuth state is one-use and expires in ten minutes. Native completion
  codes expire in two minutes and require matching state and S256 PKCE proof.
- The iPhone stores its session in device-only Keychain, not preferences.
  Server sessions are hashed, expire, and can be revoked with Sign out.
- Account deletion must remove the account and its sessions, and revoke Apple
  authorization. It must not silently delete unrelated local financial data.
- Apple refresh credentials are encrypted under the private `accounts/tokens.key`.
  Back up this key together with `accounts/accounts.sqlite3`; a lost key cannot
  revoke existing Apple grants. Account sessions are separate from ledger grants.
- Test provider login, user cancellation, callback replay, expiry, sign-out and
  account deletion with synthetic accounts before release. Unit tests and an
  available provider flag do not prove a real provider login succeeded.
- General availability also requires reviewed abuse protection, privacy policy
  disclosures, OAuth audience/domain setup and provider review where required.

Official references: [Google OIDC](https://developers.google.com/identity/openid-connect/openid-connect),
[Telegram Login](https://core.telegram.org/bots/telegram-login),
[Sign in with Apple](https://developer.apple.com/sign-in-with-apple/),
[Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/).
