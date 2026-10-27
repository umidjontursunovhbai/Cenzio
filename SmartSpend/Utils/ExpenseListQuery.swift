import Foundation

/// Quick time windows offered on the Expenses tab.
enum ExpensePeriod: String, CaseIterable, Hashable {
    case all
    case today
    case yesterday
    case week
    case month
    case custom

    /// Periods shown as one-tap chips; `custom` opens the range picker instead.
    static let quickPeriods: [ExpensePeriod] = [.all, .today, .yesterday, .week, .month]

    var localizedName: String {
        switch self {
        case .all: return "all".localized
        case .today: return "time_period_today".localized
        case .yesterday: return "yesterday".localized
        case .week: return "time_period_this_week".localized
        case .month: return "time_period_this_month".localized
        case .custom: return "time_period_custom".localized
        }
    }
}

/// Everything that narrows the Expenses list. Pure so it can be unit-tested
/// and computed once per input change rather than on every view update.
struct ExpenseListQuery: Equatable {
    var searchText = ""
    var period: ExpensePeriod = .all
    var categoryIds: Set<UUID> = []
    var customStart = Date()
    var customEnd = Date()

    var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedSearch.isEmpty }

    /// Period or category filters (search is reported separately).
    var hasFilters: Bool { period != .all || !categoryIds.isEmpty }

    func matchesPeriod(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch period {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return false }
            return calendar.isDate(date, inSameDayAs: yesterday)
        case .week:
            return ExpenseDateFilter.contains(date, in: .weekOfYear, relativeTo: now, calendar: calendar)
        case .month:
            return ExpenseDateFilter.contains(date, in: .month, relativeTo: now, calendar: calendar)
        case .custom:
            return ExpenseDateFilter.contains(date, from: customStart, through: customEnd, calendar: calendar)
        }
    }

    /// Search matches the title or category name (case- and diacritic-insensitive),
    /// or the exact amount when the query is a number ("2,500" finds 2500).
    func matchesSearch(_ expense: Expense, categoryName: String?) -> Bool {
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if expense.title.range(of: query, options: options) != nil { return true }
        if let categoryName, categoryName.range(of: query, options: options) != nil { return true }
        if query.contains(where: \.isNumber), query.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." || $0 == " " }),
           let value = AmountInputFormatter.parse(query) {
            return abs(expense.amount - value) < 0.005
        }
        return false
    }

    /// Matching expenses, newest first. Same-timestamp entries (common for
    /// imports) keep a stable order: the most recently added first.
    func apply(
        to expenses: [Expense],
        categoryNames: [UUID: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Expense] {
        expenses.enumerated()
            .filter { _, expense in
                (categoryIds.isEmpty || categoryIds.contains(expense.categoryId))
                    && matchesPeriod(expense.date, now: now, calendar: calendar)
                    && matchesSearch(expense, categoryName: categoryNames[expense.categoryId])
            }
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset > rhs.offset
            }
            .map(\.element)
    }
}

/// One day of the list. `total` and `count` always cover the whole day, even
/// when pagination shows only some of its rows.
struct ExpenseDayGroup: Identifiable, Equatable {
    let day: Date
    let expenses: [Expense]
    let total: Double
    let count: Int

    var id: Date { day }

    /// Groups newest-first expenses by calendar day, showing at most `limit` rows.
    static func make(from sortedExpenses: [Expense], limit: Int = .max, calendar: Calendar = .current) -> [ExpenseDayGroup] {
        var groups: [ExpenseDayGroup] = []
        var day: Date?
        var visible: [Expense] = []
        var total = 0.0
        var count = 0
        var remaining = max(limit, 0)

        func flush() {
            if let day, !visible.isEmpty {
                groups.append(ExpenseDayGroup(day: day, expenses: visible, total: total, count: count))
            }
        }

        for expense in sortedExpenses {
            let start = calendar.startOfDay(for: expense.date)
            if start != day {
                flush()
                if remaining == 0 { return groups }
                day = start
                visible = []
                total = 0
                count = 0
            }
            total += expense.amount
            count += 1
            if remaining > 0 {
                visible.append(expense)
                remaining -= 1
            }
        }
        flush()
        return groups
    }

    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "today".localized }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "yesterday".localized
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }
}

enum ExpenseSelection {
    /// "Select all" selects every matching expense; when all are already selected it clears.
    static func toggleAll(selected: Set<UUID>, visible: [UUID]) -> Set<UUID> {
        let visibleSet = Set(visible)
        return visibleSet.isSubset(of: selected) && !visibleSet.isEmpty ? [] : visibleSet
    }

    /// Only expenses still in the current results can be deleted, in list order.
    static func deletable(from results: [Expense], selected: Set<UUID>) -> [Expense] {
        results.filter { selected.contains($0.id) }
    }
}

/// Human-readable custom range, e.g. "Oct 3 – Oct 12" or "Oct 3, 2025".
enum ExpenseRangeText {
    static func text(from start: Date, through end: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let lower = min(start, end)
        let upper = max(start, end)
        let needsYear = !calendar.isDate(lower, equalTo: now, toGranularity: .year)
            || !calendar.isDate(upper, equalTo: now, toGranularity: .year)
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if needsYear { style = style.year() }
        if calendar.isDate(lower, inSameDayAs: upper) { return lower.formatted(style) }
        return "\(lower.formatted(style)) – \(upper.formatted(style))"
    }
}

/// Validation shared by the edit form.
enum ExpenseEditValidator {
    static func title(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A positive, finite amount, or nil.
    static func amount(_ text: String) -> Double? {
        guard let value = AmountInputFormatter.parse(text), value.isFinite, value > 0 else { return nil }
        return value
    }
}
