import CryptoKit
import Foundation

enum RecurrenceType: String, CaseIterable, Codable {
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Bi-weekly"
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case yearly = "Yearly"
    
    var icon: String {
        switch self {
        case .daily:
            return "calendar.day.timeline.left"
        case .weekly:
            return "calendar.badge.clock"
        case .biweekly:
            return "calendar.badge.clock"
        case .monthly:
            return "calendar"
        case .quarterly:
            return "calendar.badge.plus"
        case .yearly:
            return "calendar.badge.exclamationmark"
        }
    }
    
    /// The `index`-th billing day counted from the original anchor, so Jan 31 → Feb 28 → Mar 31.
    func occurrence(_ index: Int, from startDate: Date, calendar: Calendar = .current) -> Date {
        let anchor = calendar.startOfDay(for: startDate)
        let component: Calendar.Component
        let interval: Int
        switch self {
        case .daily: (component, interval) = (.day, 1)
        case .weekly: (component, interval) = (.day, 7)
        case .biweekly: (component, interval) = (.day, 14)
        case .monthly: (component, interval) = (.month, 1)
        case .quarterly: (component, interval) = (.month, 3)
        case .yearly: (component, interval) = (.year, 1)
        }
        return calendar.date(byAdding: component, value: index * interval, to: anchor) ?? anchor
    }

    /// Localized frequency label for UI; `rawValue` stays the stable storage/export value.
    var localizedName: String {
        switch self {
        case .daily: return "recurrence_daily".localized
        case .weekly: return "recurrence_weekly".localized
        case .biweekly: return "recurrence_biweekly".localized
        case .monthly: return "recurrence_monthly".localized
        case .quarterly: return "recurrence_quarterly".localized
        case .yearly: return "recurrence_yearly".localized
        }
    }

    /// Average charges per calendar month, used to show a comparable monthly cost.
    var occurrencesPerMonth: Double {
        switch self {
        case .daily: return 365.0 / 12
        case .weekly: return 52.0 / 12
        case .biweekly: return 26.0 / 12
        case .monthly: return 1
        case .quarterly: return 1.0 / 3
        case .yearly: return 1.0 / 12
        }
    }
}

struct RecurringExpense: Identifiable, Codable {
    let id: UUID
    var title: String
    var amount: Double
    var categoryId: UUID
    var recurrenceType: RecurrenceType
    var startDate: Date
    var endDate: Date?
    var isActive: Bool
    var lastProcessedDate: Date?
    var createdDate: Date
    
    init(title: String, amount: Double, categoryId: UUID, recurrenceType: RecurrenceType, startDate: Date, endDate: Date? = nil) {
        self.id = UUID()
        self.title = title
        self.amount = amount
        self.categoryId = categoryId
        self.recurrenceType = recurrenceType
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = true
        self.createdDate = Date()
    }
    
    var nextDueDate: Date {
        occurrenceDate(at: nextOccurrenceIndex(calendar: .current), calendar: .current)
    }
    
    var isOverdue: Bool {
        nextDueDate < Calendar.current.startOfDay(for: Date())
    }
    
    var isDue: Bool {
        let calendar = Calendar.current
        return calendar.isDate(nextDueDate, inSameDayAs: Date()) || isOverdue
    }
    
    var isExpired: Bool { isExpired(on: Date()) }

    /// Ended once the end day has passed or no occurrence is left on or before it.
    /// Compared by calendar day so a bill ending today still counts today's charge.
    func isExpired(on date: Date, calendar: Calendar = .current) -> Bool {
        guard let endDate else { return false }
        let lastDay = calendar.startOfDay(for: endDate)
        if calendar.startOfDay(for: date) > lastDay { return true }
        return occurrenceDate(at: nextOccurrenceIndex(calendar: calendar), calendar: calendar) > lastDay
    }

    /// Cost of this schedule averaged to one month (a yearly 120 is 10 a month).
    var monthlyEquivalentAmount: Double {
        amount * recurrenceType.occurrencesPerMonth
    }
    
    func shouldCreateExpense(on date: Date = Date()) -> Bool {
        guard isActive else { return false }
        let calendar = Calendar.current
        let dueDate = nextDueDate
        if let endDate, dueDate > calendar.startOfDay(for: endDate) { return false }
        return dueDate <= calendar.startOfDay(for: date)
    }

    /// Unprocessed calendar-day occurrences, including the chosen start date.
    /// Always calculate from the original anchor so Jan 31 returns to Mar 31
    /// after February, and reopening late never shifts future billing dates.
    func dueDates(through date: Date, calendar: Calendar = .current) -> [Date] {
        guard isActive else { return [] }
        let limit = min(calendar.startOfDay(for: date), endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture)
        var index = nextOccurrenceIndex(calendar: calendar)
        var dueDate = occurrenceDate(at: index, calendar: calendar)
        var result: [Date] = []
        while dueDate <= limit {
            result.append(dueDate)
            index += 1
            let next = occurrenceDate(at: index, calendar: calendar)
            guard next > dueDate else { break }
            dueDate = next
        }
        return result
    }

    private func occurrenceDate(at index: Int, calendar: Calendar) -> Date {
        recurrenceType.occurrence(index, from: startDate, calendar: calendar)
    }

    private func nextOccurrenceIndex(calendar: Calendar) -> Int {
        guard let lastProcessedDate else { return 0 }
        let lastDay = calendar.startOfDay(for: lastProcessedDate)
        let anchor = calendar.startOfDay(for: startDate)
        let days = calendar.dateComponents([.day], from: anchor, to: lastDay).day ?? 0
        let months = calendar.dateComponents([.month], from: anchor, to: lastDay).month ?? 0
        let years = calendar.dateComponents([.year], from: anchor, to: lastDay).year ?? 0
        var index: Int
        switch recurrenceType {
        case .daily: index = days
        case .weekly: index = days / 7
        case .biweekly: index = days / 14
        case .monthly: index = months
        case .quarterly: index = months / 3
        case .yearly: index = years
        }
        index = max(0, index)
        while occurrenceDate(at: index, calendar: calendar) <= lastDay {
            index += 1
        }
        return index
    }
    
    /// Unrecorded occurrences inside `interval` (end exclusive), stopping at the end day.
    /// Uses the anchored schedule so projections match what processing will record.
    func upcomingOccurrences(in interval: DateInterval, calendar: Calendar = .current) -> [Date] {
        guard isActive else { return [] }
        let lastDay = endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        var index = nextOccurrenceIndex(calendar: calendar)
        var previous: Date?
        var result: [Date] = []
        for _ in 0..<1_000 {
            let date = occurrenceDate(at: index, calendar: calendar)
            if let previous, date <= previous { break }
            guard date < interval.end, date <= lastDay else { break }
            if date >= interval.start { result.append(date) }
            previous = date
            index += 1
        }
        return result
    }
}

extension RecurringExpense {
    /// Stable id for the charge recorded on `dueDate`. Every device that processes the same
    /// schedule produces the same expense id, so iCloud sync merges them instead of
    /// recording the bill twice.
    func occurrenceExpenseID(for dueDate: Date, calendar: Calendar = .current) -> UUID {
        let day = calendar.dateComponents([.year, .month, .day], from: dueDate)
        let seed = "smartspend-recurring:\(id.uuidString.lowercased()):\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based UUID layout (version 5 bits)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Recurring Expense Notification
struct RecurringExpenseNotification: Identifiable {
    let id = UUID()
    let recurringExpense: RecurringExpense
    let type: NotificationType

    enum NotificationType {
        case due
        case overdue
    }
}
