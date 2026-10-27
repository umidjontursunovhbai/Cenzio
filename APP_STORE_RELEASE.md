# Cenzio App Store release preparation

Updated October 27, 2026. This is a preparation checklist, not proof of App Store approval or publication.

## Current setup

- App Store name: **Cenzio**. Subtitle: **Expense Tracker & Budget App**. SKU `smartspend-ios` (cannot be changed).
- Team: HUMBLE BEE AI, MCHJ (`94MJH9FHS9`). App Store Connect app ID `6827398944`.
- Bundle IDs: `ai.humblebee.smartspend` and `ai.humblebee.smartspend.widget`. App Group `group.ai.humblebee.smartspend`. iCloud container `iCloud.ai.humblebee.smartspend`.
- Sign in with Apple is required at launch. Records sync automatically through the user's private CloudKit database (always on).
- No Notion, Google Sheets or other connected-sync service in the app.
- Public pages: [Privacy](https://umidjontursunovhbai.github.io/Cenzio/privacy.html) and [Support](https://umidjontursunovhbai.github.io/Cenzio/support.html) (served from the default branch).
- Support email: umidjon.muydinov@icloud.com.

## Before TestFlight sync works

1. Run a Development build on a real device signed in to iCloud so every record type exists (Expense, Category, CategoryBudget, SpendingGoal, MonthlySalary, RecurringExpense, Settings).
2. In CloudKit Console, **Deploy Schema Changes** to Production. TestFlight and App Store builds use Production.
3. Test on two devices with the same Apple ID.

## Before App Review

1. **Voice AI depends on a private server** (`ubuntu.onca-albacore.ts.net:10000`). Public users have no production credential, so the AI step will not work for them. Either provide a production service and review access, or hide AI voice preparation in the store build.
2. **Login requirement.** Apple guideline 5.1.1 discourages requiring sign-in when core features do not need an account. Be ready to explain why sign-in is required, or make it optional.
3. **Account deletion.** If App Review treats Sign in with Apple as account creation, the app needs an in-app way to delete the account (sign out plus clearing local and iCloud data).
4. In App Store Connect set the Privacy Policy URL and Support URL above, then answer **App Privacy**: data is not collected by the developer; AI voice text goes to a third-party provider only with consent.
5. Age rating questionnaire, content rights, pricing and availability, category **Finance**.
6. Screenshots of the release build with synthetic data (6.9" iPhone, plus iPad if iPad stays supported).
7. Description and keywords (keywords field: `xarajat,byudjet,расходы,бюджет,spending,money,budget planner,bills`).

## Submission boundary

An archive is not an upload, an upload is not a submission, and App Review approval is not publication. Submit only with the owner's explicit approval.
