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
    
    func nextDate(from date: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
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
        return nextDueDate < Date()
    }
    
    var isDue: Bool {
        let calendar = Calendar.current
        return calendar.isDate(nextDueDate, inSameDayAs: Date()) || isOverdue
    }
    
    var isExpired: Bool {
        guard let endDate = endDate else { return false }
        return Date() > endDate
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
        let anchor = calendar.startOfDay(for: startDate)
        let component: Calendar.Component
        let interval: Int
        switch recurrenceType {
        case .daily: (component, interval) = (.day, 1)
        case .weekly: (component, interval) = (.day, 7)
        case .biweekly: (component, interval) = (.day, 14)
        case .monthly: (component, interval) = (.month, 1)
        case .quarterly: (component, interval) = (.month, 3)
        case .yearly: (component, interval) = (.year, 1)
        }
        return calendar.date(byAdding: component, value: index * interval, to: anchor) ?? anchor
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
    
    func createExpense() -> Expense {
        return Expense(
            title: title,
            amount: amount,
            categoryId: categoryId,
            date: nextDueDate
        )
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
        case upcoming // 1 day before
        
        var title: String {
            switch self {
            case .due:
                return "Recurring Expense Due"
            case .overdue:
                return "Overdue Recurring Expense"
            case .upcoming:
                return "Upcoming Recurring Expense"
            }
        }
        
        var icon: String {
            switch self {
            case .due:
                return "bell.fill"
            case .overdue:
                return "exclamationmark.triangle.fill"
            case .upcoming:
                return "clock.fill"
            }
        }
        
        var color: String {
            switch self {
            case .due:
                return "blue"
            case .overdue:
                return "red"
            case .upcoming:
                return "orange"
            }
        }
    }
    
    var message: String {
        switch type {
        case .due:
            return "\(recurringExpense.title) is due today"
        case .overdue:
            return "\(recurringExpense.title) is overdue"
        case .upcoming:
            return "\(recurringExpense.title) is due tomorrow"
        }
    }
}
