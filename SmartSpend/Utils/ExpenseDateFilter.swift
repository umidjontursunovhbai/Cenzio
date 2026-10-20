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
}
