import Foundation
import Testing
@testable import SmartSpend

@Suite("Recurring page review fixes")
struct RecurringReviewTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func bill(_ type: RecurrenceType, start: Date, end: Date? = nil, amount: Double = 100) -> RecurringExpense {
        RecurringExpense(title: "Rent", amount: amount, categoryId: UUID(), recurrenceType: type, startDate: start, endDate: end)
    }

    @MainActor
    private func withManager(_ body: (DataManager, UserDefaults) throws -> Void) throws {
        let suite = "SmartSpendTests.RecurringReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults)), defaults)
    }

    // MARK: - Expiry

    @Test("A bill ending today is not expired until the day is over")
    func expiryIsDayGranular() {
        let expense = bill(.daily, start: date(2026, 10, 1), end: date(2026, 10, 26))
        #expect(!expense.isExpired(on: date(2026, 10, 26, hour: 18), calendar: calendar))
        #expect(expense.isExpired(on: date(2026, 10, 27, hour: 1), calendar: calendar))
    }

    @Test("A bill with no charge left before its end date counts as ended")
    func expiryWhenNoOccurrenceLeft() {
        var expense = bill(.monthly, start: date(2026, 9, 10), end: date(2026, 11, 5))
        expense.lastProcessedDate = date(2026, 10, 10)
        #expect(expense.isExpired(on: date(2026, 10, 26), calendar: calendar))
        expense.endDate = date(2026, 11, 10)
        #expect(!expense.isExpired(on: date(2026, 10, 26), calendar: calendar))
    }

    // MARK: - Editing the schedule

    @Test("Switching frequency on a charged bill does not backfill the new schedule")
    @MainActor
    func frequencyChangeDoesNotBackfill() throws {
        try withManager { manager, _ in
            let rent = bill(.monthly, start: date(2026, 9, 10))
            manager.recurringExpenses = [rent]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)
            #expect(manager.expenses.count == 2)

            var weekly = rent
            weekly.recurrenceType = .weekly
            manager.updateRecurringExpense(weekly, resumedOn: date(2026, 10, 26), calendar: calendar)

            // Weekly from Sep 10 would have been Sep 17 ... Oct 22; none of those are added.
            #expect(manager.expenses.count == 2)
            let stored = try #require(manager.recurringExpenses.first)
            #expect(stored.id == rent.id)
            #expect(stored.dueDates(through: date(2026, 10, 29), calendar: calendar) == [date(2026, 10, 29)])
        }
    }

    @Test("Moving the billing day earlier does not charge the month twice")
    @MainActor
    func startDateChangeDoesNotDuplicate() throws {
        try withManager { manager, _ in
            let rent = bill(.monthly, start: date(2026, 9, 10))
            manager.recurringExpenses = [rent]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)

            var moved = rent
            moved.startDate = date(2026, 9, 5)
            manager.updateRecurringExpense(moved, resumedOn: date(2026, 10, 26), calendar: calendar)

            #expect(manager.expenses.count == 2)
            let stored = try #require(manager.recurringExpenses.first)
            #expect(stored.dueDates(through: date(2026, 11, 30), calendar: calendar) == [date(2026, 11, 5)])
        }
    }

    @Test("Moving the start into the future waits for the new start day")
    @MainActor
    func startDateMovedLater() throws {
        try withManager { manager, _ in
            let rent = bill(.monthly, start: date(2026, 9, 10))
            manager.recurringExpenses = [rent]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)

            var moved = rent
            moved.startDate = date(2026, 12, 1)
            manager.updateRecurringExpense(moved, resumedOn: date(2026, 10, 26), calendar: calendar)

            let stored = try #require(manager.recurringExpenses.first)
            #expect(stored.dueDates(through: date(2026, 11, 30), calendar: calendar).isEmpty)
            #expect(stored.dueDates(through: date(2026, 12, 1), calendar: calendar) == [date(2026, 12, 1)])
        }
    }

    @Test("A schedule change that lands on today still charges today once")
    @MainActor
    func scheduleChangeChargesToday() throws {
        try withManager { manager, _ in
            let rent = bill(.monthly, start: date(2026, 9, 10))
            manager.recurringExpenses = [rent]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)

            var moved = rent
            moved.startDate = date(2026, 9, 26)
            manager.updateRecurringExpense(moved, resumedOn: date(2026, 10, 26), calendar: calendar)

            #expect(manager.expenses.count == 3)
            #expect(manager.expenses.contains { $0.date == date(2026, 10, 26) })
        }
    }

    @Test("Editing only the amount keeps id, created date and cursor")
    @MainActor
    func plainEditKeepsIdentity() throws {
        try withManager { manager, _ in
            let rent = bill(.monthly, start: date(2026, 9, 10))
            manager.recurringExpenses = [rent]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)
            let cursor = manager.recurringExpenses.first?.lastProcessedDate

            var edited = try #require(manager.recurringExpenses.first)
            edited.amount = 250
            manager.updateRecurringExpense(edited, resumedOn: date(2026, 10, 26), calendar: calendar)

            let stored = try #require(manager.recurringExpenses.first)
            #expect(manager.recurringExpenses.count == 1)
            #expect(stored.id == rent.id)
            #expect(stored.createdDate == rent.createdDate)
            #expect(stored.lastProcessedDate == cursor)
            #expect(stored.amount == 250)
            #expect(manager.expenses.count == 2)
        }
    }

    // MARK: - Delete

    @Test("Bulk delete removes only the chosen schedules and keeps recorded expenses")
    @MainActor
    func bulkDelete() throws {
        try withManager { manager, defaults in
            let rent = bill(.monthly, start: date(2026, 10, 1))
            let gym = bill(.monthly, start: date(2026, 10, 2))
            let phone = bill(.monthly, start: date(2026, 10, 3))
            manager.recurringExpenses = [rent, gym, phone]
            manager.processRecurringExpenses(through: date(2026, 10, 26), calendar: calendar)
            #expect(manager.expenses.count == 3)

            manager.deleteRecurringExpenses(ids: [rent.id, phone.id])

            let restored = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
            #expect(restored.recurringExpenses.map(\.id) == [gym.id])
            #expect(restored.expenses.count == 3)
        }
    }

    // MARK: - Projections and totals

    @Test("Projected bills keep the month-end anchor instead of drifting")
    func projectionAnchored() {
        var expense = bill(.monthly, start: date(2026, 1, 31))
        expense.lastProcessedDate = date(2026, 2, 28)
        let march = DateInterval(start: date(2026, 3, 1), end: date(2026, 4, 1))
        #expect(expense.upcomingOccurrences(in: march, calendar: calendar) == [date(2026, 3, 31)])
        #expect(BudgetPeriodCalculator.projectedRecurringTotal(recurringExpenses: [expense], in: march, calendar: calendar) == 100)
    }

    @Test("Projected bills stop at the end date and skip paused bills")
    func projectionRespectsEndAndPause() {
        var expense = bill(.weekly, start: date(2026, 10, 1), end: date(2026, 10, 20))
        expense.lastProcessedDate = date(2026, 10, 8)
        let october = DateInterval(start: date(2026, 10, 9), end: date(2026, 11, 1))
        #expect(expense.upcomingOccurrences(in: october, calendar: calendar) == [date(2026, 10, 15)])
        expense.isActive = false
        #expect(expense.upcomingOccurrences(in: october, calendar: calendar).isEmpty)
    }

    @Test("Monthly equivalent averages each frequency to one month")
    func monthlyEquivalent() {
        #expect(bill(.monthly, start: date(2026, 1, 1), amount: 15_800).monthlyEquivalentAmount == 15_800)
        #expect(bill(.yearly, start: date(2026, 1, 1), amount: 120).monthlyEquivalentAmount == 10)
        #expect(bill(.quarterly, start: date(2026, 1, 1), amount: 300).monthlyEquivalentAmount == 100)
        #expect(bill(.weekly, start: date(2026, 1, 1), amount: 12).monthlyEquivalentAmount == 52)
        #expect(bill(.biweekly, start: date(2026, 1, 1), amount: 12).monthlyEquivalentAmount == 26)
        #expect(abs(bill(.daily, start: date(2026, 1, 1), amount: 12).monthlyEquivalentAmount - 365) < 0.0001)
    }

    // MARK: - Preview

    @Test("Form preview lists the next charges from today, within the end date")
    func previewFromToday() {
        let dates = RecurrencePreviewView.upcomingDates(
            recurrenceType: .monthly,
            startDate: date(2026, 1, 31),
            endDate: date(2026, 12, 31),
            from: date(2026, 10, 26, hour: 15),
            limit: 5,
            calendar: calendar
        )
        #expect(dates == [date(2026, 10, 31), date(2026, 11, 30), date(2026, 12, 31)])
    }

    @Test("Form preview starts at a future start day")
    func previewFutureStart() {
        let dates = RecurrencePreviewView.upcomingDates(
            recurrenceType: .biweekly,
            startDate: date(2026, 11, 2),
            endDate: nil,
            from: date(2026, 10, 26),
            limit: 2,
            calendar: calendar
        )
        #expect(dates == [date(2026, 11, 2), date(2026, 11, 16)])
    }

    // MARK: - Attention card and reminders

    @Test("A missed charge is reported as overdue, today's as due")
    @MainActor
    func notificationTypes() throws {
        try withManager { manager, _ in
            let today = Calendar.current.startOfDay(for: Date())
            let overdue = RecurringExpense(title: "Old", amount: 1, categoryId: UUID(), recurrenceType: .monthly,
                                           startDate: Calendar.current.date(byAdding: .day, value: -3, to: today)!)
            let dueToday = RecurringExpense(title: "Now", amount: 1, categoryId: UUID(), recurrenceType: .monthly, startDate: today)
            manager.recurringExpenses = [dueToday, overdue]

            let notifications = manager.getRecurringExpenseNotifications()
            #expect(notifications.map(\.recurringExpense.id) == [overdue.id, dueToday.id])
            #expect(notifications.map(\.type) == [.overdue, .due])
        }
    }

    @Test("Bill reminders include a bill due today and skip paused bills")
    @MainActor
    func billReminders() throws {
        try withManager { manager, _ in
            let today = Calendar.current.startOfDay(for: Date())
            var bill = RecurringExpense(title: "Internet", amount: 10, categoryId: UUID(), recurrenceType: .monthly, startDate: today)
            manager.recurringExpenses = [bill]
            #expect(manager.getUpcomingBillReminders().count == 1)
            #expect(manager.getUpcomingBillReminders().first?.contains("today") == true)

            bill.isActive = false
            manager.recurringExpenses = [bill]
            #expect(manager.getUpcomingBillReminders().isEmpty)
        }
    }
}
