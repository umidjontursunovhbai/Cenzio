import Foundation
import Testing
@testable import SmartSpend

@Suite("Expense and recurring edit regressions")
struct ExpenseAndRecurringFixTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @MainActor
    private func withManager(_ body: (DataManager, UserDefaults) throws -> Void) throws {
        let suite = "SmartSpendTests.EditFixes.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults)), defaults)
    }

    @Test("Custom date range includes the whole last day and a single-day range")
    func inclusiveRange() {
        let day = date(2026, 10, 12)
        #expect(ExpenseDateFilter.contains(date(2026, 10, 12, hour: 18), from: day, through: day, calendar: calendar))
        #expect(ExpenseDateFilter.contains(date(2026, 10, 15, hour: 23), from: date(2026, 10, 12, hour: 9), through: date(2026, 10, 15, hour: 8), calendar: calendar))
        #expect(!ExpenseDateFilter.contains(date(2026, 10, 16), from: day, through: date(2026, 10, 15), calendar: calendar))
        #expect(!ExpenseDateFilter.contains(date(2026, 10, 11, hour: 23), from: day, through: date(2026, 10, 15), calendar: calendar))
    }

    @Test("Bulk archive moves only the given expenses and persists them")
    @MainActor
    func bulkArchive() throws {
        try withManager { manager, defaults in
            let a = Expense(title: "A", amount: 1, categoryId: UUID(), date: date(2026, 10, 1))
            let b = Expense(title: "B", amount: 2, categoryId: UUID(), date: date(2026, 10, 2))
            let c = Expense(title: "C", amount: 3, categoryId: UUID(), date: date(2026, 10, 3))
            manager.addExpensesBatch([a, b, c])
            manager.moveToDeletedExpenses([a, c])
            let restored = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
            #expect(restored.expenses.map(\.id) == [b.id])
            #expect(Set(restored.deletedExpenses.map(\.id)) == [a.id, c.id])
        }
    }

    @Test("Saving a stale edit sheet does not rewind the cursor and duplicate charges")
    @MainActor
    func staleEditKeepsCursor() throws {
        try withManager { manager, _ in
            let bill = RecurringExpense(title: "Rent", amount: 100, categoryId: UUID(), recurrenceType: .monthly, startDate: date(2026, 9, 10))
            manager.recurringExpenses = [bill]
            var staleCopy = bill // edit sheet opened before processing
            manager.processRecurringExpenses(through: date(2026, 10, 20), calendar: calendar)
            #expect(manager.expenses.count == 2)
            staleCopy.title = "Rent (new)"
            manager.updateRecurringExpense(staleCopy, resumedOn: date(2026, 10, 20), calendar: calendar)
            #expect(manager.expenses.count == 2)
            #expect(manager.recurringExpenses.first?.title == "Rent (new)")
            #expect(manager.recurringExpenses.first?.lastProcessedDate == date(2026, 10, 10))
        }
    }

    @Test("Resuming a paused bill continues from today without backfilling the pause")
    @MainActor
    func resumeSkipsPausedPeriod() throws {
        try withManager { manager, _ in
            var bill = RecurringExpense(title: "Gym", amount: 50, categoryId: UUID(), recurrenceType: .monthly, startDate: date(2026, 5, 20))
            bill.lastProcessedDate = date(2026, 5, 20)
            bill.isActive = false
            manager.recurringExpenses = [bill]
            bill.isActive = true
            manager.updateRecurringExpense(bill, resumedOn: date(2026, 10, 20), calendar: calendar)
            // Only today's (Oct 20) occurrence, not Jun–Sep.
            #expect(manager.expenses.map(\.date) == [date(2026, 10, 20)])
        }
    }

    @Test("Preview occurrences keep the month-end anchor")
    func previewAnchor() {
        let dates = (0..<3).map { RecurrenceType.monthly.occurrence($0, from: date(2026, 1, 31), calendar: calendar) }
        #expect(dates == [date(2026, 1, 31), date(2026, 2, 28), date(2026, 3, 31)])
    }
}
