import Foundation

enum ExpenseDateFilter {
    /// Calendar periods include their start and exclude the next period's start.
    static func contains(
        _ date: Date,
        in component: Calendar.Component,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let interval = calendar.dateInterval(of: component, for: referenceDate) else {
            return false
        }
        return date >= interval.start && date < interval.end
    }

    /// Whole calendar days from `startDay` through the end of `endDay`, whatever their time of day.
    static func contains(
        _ date: Date,
        from startDay: Date,
        through endDay: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let start = calendar.startOfDay(for: min(startDay, endDay))
        let lastDay = calendar.startOfDay(for: max(startDay, endDay))
        guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return false }
        return date >= start && date < end
    }
}
