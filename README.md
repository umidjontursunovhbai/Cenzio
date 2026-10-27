# Cenzio

Cenzio helps you keep track of everyday spending without making money management feel complicated. Add an expense, see where this month's money went, and keep your budget in view.

## What you can do

- **See the essentials at a glance.** The Dashboard shows this month's spending, your budget context, categories, recent expenses, and upcoming recurring bills. It also shows previous months when you have recorded expenses for them.
- **Record and find expenses.** Add expenses, then search or filter the list by date and category.
- **Plan ahead.** Set category budgets and spending goals, enter monthly income, and keep track of recurring expenses.
- **Make it yours.** Create your own categories, choose a currency, and import or export your records.
- **Check from your Home Screen.** Widgets show spending information, and supported iPhone configurations offer a quick Add Expense control.

The app has four tabs: **Dashboard, Expenses, Recurring, and Settings**. Spending summaries live on the Dashboard; there is no separate Analytics tab.

## Your data stays in your hands

Cenzio does not require an account for local use. By default, records stay on your device and are shared locally with its widgets. CloudKit sync is not active. Development builds also offer the optional Integrations preview described below.

You can export a copy from **Settings → Export Data**. CSV expense records can be imported again; JSON/PDF reports and other exported sections are not a full restorable app backup. Keep exported files somewhere safe: they contain your financial information, and deleting data inside the app does not delete copies you have saved or shared elsewhere. See the [Privacy Policy](https://umidjontursunovhbai.github.io/Cenzio/privacy.html) for details.

## Optional Notion connection

**Settings → Integrations** is the place to connect your own Notion
account. There is no technical MCP/token/file-exchange setup in the normal mobile
settings. Connections are optional; check the upload consent before continuing.

- **Notion:** authorize your own workspace, then choose a shared page for a new
  dedicated expense database. Existing pages and tables are not replaced.
- **Existing Notion tables:** inspect their fields, map them to your categories,
  and preview records without changing the table. This is **read-only preview**,
  not import or bidirectional sync. An existing table such as Expense / Amount /
  Category / Date does not need to be renamed or modified to preview it.

The preview retains offline expense edits, checks for changes while Cenzio is
open, and includes History & Trash. It is tied to this installation, not a
cross-device account or a recovery service. Disconnecting stops future sync but
does not erase server history, backups, or external copies; an operation already
in progress may finish. Those copies need separate deletion/revocation.

This branch contains the connection flow, but public availability still requires
server configuration, provider consent setup and live QA. A successful build is
not proof that Notion or ChatGPT is connected. See the [operator guide](docs/CONNECTED_SYNC.md)
for rollout limits. The separate [MCP guide](mcp-server/README.md) is for operators
and AI clients, not a required mobile setup step.

## Add an expense by voice

To dictate an expense, tap the **microphone button** at the bottom of
Dashboard or Expenses, next to the **+** button. Listening starts immediately
(iOS asks permission the first time); **+** opens the manual form. The
microphone becomes a red Stop button — no recording popup. Voice capture currently supports English only;
there is no language picker or recording-language banner. Tap Stop to transcribe
locally, then let **GPT-6 Luna** prepare an expense preview. First use may download
Apple's speech model and asks permission to send text to AI. After that, Stop
automatically runs STT → GPT → review. Check the amount, title, category and date,
then tap Save. Each request includes your current category IDs/names, even when
they are in different languages. GPT chooses from those options by meaning;
there is no static expense/category parser or silent local fallback. Income,
loans, cards and foreign-currency conversion are not recorded as expenses.

GPT preparation requires an authenticated internet connection to the voice
gateway. The owner's development iPhone can be provisioned from the paired Mac
without typing a code; this uses a device-specific credential imported into
Keychain, not an API key bundled in the app. This DEBUG-only provisioning is NOT
public multi-user onboarding. Public release still needs production authentication.
The temporary HTTPS connection works over Wi-Fi or mobile internet, without
Tailscale on the iPhone. The OpenRouter key stays on Ubuntu; the phone stores only its own
revocable credential in Keychain. Microphone speech requires on-device support
for the chosen language; availability depends on the device/language assets.
Only text and category/date/currency context go to OpenRouter/OpenAI after your
consent—not audio or past expenses. This is not offline AI or live ledger sync.

## Availability and support

Cenzio is being prepared for App Store release; it is **not yet published on the App Store**. If you are using a development build, keep the existing installation until you have verified how to move all the records you need. Exported reports alone do not restore the entire app.

Need help or want to share feedback? Visit [Cenzio Support](https://umidjontursunovhbai.github.io/Cenzio/support.html) or email [tursunov.umidjon.uz@gmail.com](mailto:tursunov.umidjon.uz@gmail.com).

For developers: [release preparation](APP_STORE_RELEASE.md) · [deployment notes](DEPLOYMENT.md) · [third-party notices](THIRD_PARTY_NOTICES.md)
