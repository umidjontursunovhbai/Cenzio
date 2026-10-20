import Foundation
import Testing
@testable import SmartSpend

@Suite("Release persistence regressions")
struct DataManagerReleaseRegressionTests {
    @Test("Recurring catch-up persists due dates and cursor together without duplicates on relaunch")
    @MainActor
    func recurringCatchUpSurvivesRelaunch() throws {
        let suite = "SmartSpendTests.RecurringPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        let reopened = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        manager.recurringExpenses = [RecurringExpense(title: "Daily bill", amount: 25,
            categoryId: UUID(), recurrenceType: .daily, startDate: first, endDate: end)]
        manager.processRecurringExpenses(through: reopened, calendar: calendar)
        #expect(manager.expenses.count == 3)
        #expect(manager.expenses.reduce(0) { $0 + $1.amount } == 75)
        #expect(manager.expenses.map(\.date) == [first, first.addingTimeInterval(86_400), end])

        let restored = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(restored.recurringExpenses.first?.lastProcessedDate == end)
        restored.processRecurringExpenses(through: reopened, calendar: calendar)
        #expect(restored.expenses.count == 3)
        #expect(Set(restored.expenses.map(\.id)) == Set(manager.expenses.map(\.id)))
    }

    @Test("Clear All Data resets persisted financial records, date range and earned progress")
    @MainActor
    func clearAllDataPersists() throws {
        let suite = "SmartSpendTests.ClearAll.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let activity = GamificationManager(defaults: defaults)
        var level = UserLevel()
        level.addXP(700)
        defaults.set(try JSONEncoder().encode(level), forKey: "userLevel")
        let manager = DataManager(defaults: defaults, activityManager: activity)
        manager.expenses = [Expense(title: "Old", amount: 5, categoryId: UUID(), date: Date())]
        manager.recurringExpenses = [RecurringExpense(title: "Old bill", amount: 5,
            categoryId: UUID(), recurrenceType: .monthly, startDate: Date())]
        manager.customStartDate = .distantPast
        manager.customEndDate = .distantFuture
        defaults.set(true, forKey: "openAddExpense")
        manager.clearAllData()

        let restoredActivity = GamificationManager(defaults: defaults)
        let restored = DataManager(defaults: defaults, activityManager: restoredActivity)
        #expect(restored.expenses.isEmpty)
        #expect(restored.recurringExpenses.isEmpty)
        #expect(restored.customStartDate == restored.customEndDate)
        #expect(restored.customStartDate != .distantPast)
        #expect(restoredActivity.userLevel.totalXP == 0)
        #expect(restoredActivity.achievements.allSatisfy { !$0.isUnlocked && $0.progress == 0 })
        #expect(!defaults.bool(forKey: "openAddExpense"))
    }
}
