# Cenzio (SmartSpend) — Claude Context

## Project Overview
Privacy-first iOS expense tracker, App Store name **Cenzio**. Swift 6, SwiftUI, MVVM. Data lives on-device and syncs through the user's private iCloud (CKSyncEngine, `SmartSpend/Sync/`).

- **Bundle ID**: `ai.humblebee.smartspend` (team 94MJH9FHS9)
- **App Group**: `group.ai.humblebee.smartspend` (shared between app and Widget extension)
- **Minimum iOS**: 17.0 | **Xcode**: 16.0+

## Architecture

### Key Files
| File | Role |
|------|------|
| `SmartSpend/DataManager/DataManager.swift` | Central singleton — all state, persistence, filtering, smart learning |
| `SmartSpend/Models/` | Data models: Expense, Budget, LearnedPattern, RecurringExpense, etc. |
| `SmartSpend/Views/` | SwiftUI views |
| `SmartSpend/Utils/` | Helpers: CurrencyFormatter, DataImporter, DataExporter, ReceiptOCRService |
| `Widget/Widget.swift` | WidgetKit provider — reads from shared UserDefaults using lightweight mirror types |

### Data Persistence
All data is JSON-encoded into `UserDefaults(suiteName: "group.ai.humblebee.smartspend")`.
Every mutation calls `saveData()` which re-encodes and saves **all** collections at once.

### Smart Learning Engine
`LearnedPattern` stores per-title frequency tables. Matching uses:
1. Exact title match → score 1.0
2. Keyword Jaccard similarity (weight 0.7)
3. Levenshtein distance (weight 0.3)

Patterns rebuild from the last 3 months of expenses every 10 additions or on app launch.

## Known Issues / Tech Debt
- `DataManager` is a God Object (~980 lines). All 9 data collections + filtering + smart learning in one class.
- `saveData()` encodes everything on every write — no partial saves.
- UserDefaults has a ~4 MB practical limit; large datasets could silently fail to save.
- Recurring expense processing runs on a 1-hour `Timer` — won't fire if app is backgrounded for days.
- `SupportChatView` is actually the Insights screen (not a chat) — computes spending insights locally.

## Fixed (2026-06)
- **Lag:** `CurrencyFormatter` now caches one `NumberFormatter` per currency (was allocating one per call, on every list row). See `Utils/CurrencyFormatter.swift`.
- **Lag:** `AddExpenseView.formatNumberWithCommas` formatter is now `static` (was per-keystroke).
- **Logic:** `getDailyAverageForPeriod` / `getWeeklyAverageForPeriod` divided by transaction count instead of days/weeks. Now divide by distinct calendar days/weeks.
- **Logic:** `ExpenseStreak` compared raw timestamps instead of calendar days — streaks miscounted across midnight. Now uses `calendar.startOfDay`.

## Build
- Scheme `SmartSpend`, simulator iPhone 17 (`xcodebuild ... -destination 'platform=iOS Simulator,id=...'`).
- App and Widget share `MARKETING_VERSION` (2.0), so the version-mismatch warning is gone.

## Localization
Keys are in `SmartSpend.xcodeproj/Localizable.strings`. `.localized` is a `String` extension.
Supported languages: English, Uzbek (and more per README).

## Widget Notes
Widget uses private `WExpense / WUser / WCategory / WMonthlySalary` mirror structs to decode
shared UserDefaults independently — avoids importing the full app module.
Timeline refreshes every 1 hour.
