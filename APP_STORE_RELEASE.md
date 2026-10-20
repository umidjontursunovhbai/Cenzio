# SmartSpend App Store release preparation

Audit date: October 10, 2026. This is a preparation checklist, not proof of App Store approval or publication.

## Verified locally

- Bundle ID: `com.tursunov.SmartSpend`; widget: `com.tursunov.SmartSpend.Widget`.
- Version in the current project: `2.0 (1)`. Check App Store Connect before deciding whether build `1` is reusable.
- Minimum OS: iOS 18.5. The project currently supports iPhone **and iPad**; both need release QA and appropriate screenshots.
- Xcode 27 Release archive built successfully with signing disabled during the October 10 audit. The paid-team signing check failed because the available profile does not support the current App Group. An unsigned archive is not an App Store IPA.
- The app and widget bundle their privacy manifests. The 1024×1024 app icons have no alpha channel.
- The app uses local storage/App Group and has no active CloudKit sync, in-app account, ads, or third-party analytics in this build.
- An in-app privacy policy and support email are reachable from Settings.

## Blockers before upload

The optional connected-sync development preview is documented in
[the operator guide](docs/CONNECTED_SYNC.md). Explicit enrollment uploads expense
records/categories/history to an owner-operated service; enabling Google Sheets
or Notion also exchanges records with that provider. Reconcile in-app and public
privacy disclosures, App Store privacy answers, retention/deletion behavior and
reviewer access with the final shipped build. Native sync uses an administrator-issued
ledger-scoped credential in Keychain, not consumer account onboarding. Remote MCP
requires a separately configured upstream OAuth identity provider. Public HTTPS
sync deployment, live Google/Notion/ChatGPT QA, and production authentication/review
access remain release gates. The existing voice listener on port 10000 does not
provide sync routes. Local tests or a successful build do not establish these gates.

The inline voice flow now uses GPT-6 Luna rather than a static local parser.
The owner's phone is provisioned over its paired Mac with a revocable device
credential. This one-time file import is DEBUG-only and excluded from Release;
it is not App Attest or production account onboarding. Do not distribute a
development credential or include its import file in an archive. Production
authentication and an approved App Review access path remain required.

The October 20 development build adds an optional private voice/AI preview.
Microphone audio is recognized on-device, but user-approved transcript/context is
processed by OpenRouter/OpenAI. Re-review App Store privacy disclosures against
the providers' actual retention practices; do not claim that nothing ever leaves
the phone. The local privacy pages have been updated but are not automatically
published. Temporary public Funnel with owner-only pairing is not a production multi-user service or
an App Review-ready connection; supply an approved review path or exclude this
private preview from the store build before submission.

1. The intended paid team is `HUMBLE BEE AI, MCHJ` (`94MJH9FHS9`), but a local archive check with that team failed: the current `group.com.tursunov.SmartSpend` App Group is unavailable to it. The project's current personal team (`4R72PTT5ZJ`) can build an archive but cannot create App Store distribution profiles. Do **not** silently replace the App Group: the current iPhone build stores records there, so changing it can hide existing records. First back up/export data, determine whether the original group can be moved or a new group is necessary, and test migration with a disposable data copy. Then configure app and widget identifiers/entitlements/profiles under the paid team, rebuild, export an `app-store-connect` IPA, and validate it. No App Store IPA exists yet.
2. Public URLs are now available: [Privacy](https://umidjontursunovhbai.github.io/SmartSpend/privacy.html) and [Support](https://umidjontursunovhbai.github.io/SmartSpend/support.html). GitHub Pages is enabled from `main` / `/docs`; both returned HTTP 200 on October 10, 2026. Enter these verified URLs in App Store Connect and recheck them before submission.
3. Confirm the app record, bundle ID, version/build uniqueness, distribution agreements, and appropriate account roles in App Store Connect.
   A public App Store listing already uses the name **Smartspend**; treat `SmartSpend` as provisional until App Store Connect confirms name availability for the chosen localization. Select a distinct name if it is unavailable; do not imitate another app's branding.
4. Capture screenshots of the **release build with synthetic data**, not private expense records. At least one screenshot is required; provide the device classes and localizations App Store Connect requests for this iPhone+iPad app. Visually test empty, populated, import/export, budgets, recurring expenses, widget, and narrow/iPad layouts.
5. Complete App Store Connect fields: app name, primary language/category, age-rating questionnaire, content rights, pricing/availability, Digital Services Act status where applicable, app privacy answers, privacy policy URL, support URL, description, keywords, copyright, and App Review contact/notes. Complete export-compliance questions if requested. Review these answers against the final shipped binary.

## Suggested English metadata draft

Name: `SmartSpend` (provisional; App Store Connect availability check required)

Subtitle: `Track spending with clarity`

Primary category: `Finance` (confirm in App Store Connect)

Keywords: `expense tracker,budget,spending,recurring bills,money,csv`

Description:

> SmartSpend helps you record expenses, see where your money goes, and plan around monthly income.
>
> Add expenses and organize them by category. Set category budgets and spending goals. See this month's spending, recent expenses, and upcoming recurring bills at a glance. Import expenses from a CSV file or export a copy of your records when you need one.
>
> No account is required. In the current version, SmartSpend records are stored on your device and can be shared with its iOS widget.

Do not claim bank sync, live account balances, AI advice, or generally available
cloud sync in the listing. The private connected preview is not a verified public
service; describe only features enabled and validated in the final release build.

## Submission boundary

CSV import restores expense rows only, including legacy sectioned expense exports. JSON/PDF exports and non-expense CSV sections are reports, not a full app backup. Do not delete the original installation or change the App Group on the assumption that these reports restore categories/styles, budgets, goals, preferences and recurrence cursors. Full migration verification remains part of the signing blocker.

Creating a local archive is not the same as exporting a distribution-signed IPA. Export is not upload. Upload/processing is not App Review submission. Approval is not public release. Record evidence for each step separately.

References: [Apple upload requirements](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds), [required App Store properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties), [privacy declarations](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy), and [screenshot requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/).
