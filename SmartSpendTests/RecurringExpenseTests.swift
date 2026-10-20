import Foundation
import Testing
@testable import SmartSpend

@Suite("Recurring expense schedule")
struct RecurringExpenseTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func bill(_ type: RecurrenceType, start: Date, end: Date? = nil) -> RecurringExpense {
        RecurringExpense(title: "Rent", amount: 100, categoryId: UUID(), recurrenceType: type, startDate: start, endDate: end)
    }

    @Test("Start day is first occurrence even before the picked time")
    func startDay() {
        let expense = bill(.monthly, start: date(2026, 10, 10, hour: 18))
        #expect(expense.dueDates(through: date(2026, 10, 10, hour: 8), calendar: calendar) == [date(2026, 10, 10)])
        #expect(expense.dueDates(through: date(2026, 10, 9), calendar: calendar).isEmpty)
    }

    @Test("Late reopen catches up every occurrence and retries do not duplicate")
    func catchUp() {
        var expense = bill(.monthly, start: date(2026, 7, 10))
        expense.lastProcessedDate = date(2026, 7, 10)
        let due = expense.dueDates(through: date(2026, 10, 20), calendar: calendar)
        #expect(due == [date(2026, 8, 10), date(2026, 9, 10), date(2026, 10, 10)])
        expense.lastProcessedDate = due.last
        #expect(expense.dueDates(through: date(2026, 10, 20), calendar: calendar).isEmpty)
        #expect(expense.dueDates(through: date(2026, 11, 10), calendar: calendar) == [date(2026, 11, 10)])
    }

    @Test("Month-end and leap-day schedules keep their original anchor")
    func anchoredCalendarDates() {
        let monthEnd = bill(.monthly, start: date(2026, 1, 31))
        #expect(monthEnd.dueDates(through: date(2026, 3, 31), calendar: calendar) == [date(2026, 1, 31), date(2026, 2, 28), date(2026, 3, 31)])
        var leapDay = bill(.yearly, start: date(2024, 2, 29))
        leapDay.lastProcessedDate = date(2027, 2, 28)
        #expect(leapDay.dueDates(through: date(2028, 3, 1), calendar: calendar) == [date(2028, 2, 29)])
    }

    @Test("Ended schedules still recover historical charges through inclusive end day")
    func historicalEndDate() {
        var expense = bill(.daily, start: date(2026, 10, 1), end: date(2026, 10, 3))
        #expect(expense.dueDates(through: date(2026, 10, 10), calendar: calendar) == [date(2026, 10, 1), date(2026, 10, 2), date(2026, 10, 3)])
        expense.isActive = false
        #expect(expense.dueDates(through: date(2026, 10, 10), calendar: calendar).isEmpty)
    }

    @Test("Legacy processing timestamps continue on the original billing day")
    func legacyCursor() {
        var expense = bill(.monthly, start: date(2026, 1, 10))
        expense.lastProcessedDate = date(2026, 3, 17, hour: 13)
        #expect(expense.dueDates(through: date(2026, 4, 20), calendar: calendar) == [date(2026, 4, 10)])
    }
}
