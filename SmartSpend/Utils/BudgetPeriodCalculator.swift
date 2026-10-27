import Foundation

struct SpendableTodaySnapshot: Equatable {
    let monthlyIncome: Double
    let spentThisMonth: Double
    let upcomingRecurring: Double
    let remainingBeforeBills: Double
    let availableAfterBills: Double
    let daysRemaining: Int
    let spendableToday: Double
}

enum BudgetPeriodCalculator {
    static func monthInterval(
        containing date: Date,
        calendar: Calendar = .current
    ) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)
            ?? DateInterval(start: date, duration: 0)
    }

    static func expenses(
        _ expenses: [Expense],
        in interval: DateInterval
    ) -> [Expense] {
        expenses.filter { interval.contains($0.date) }
    }

    static func total(
        for expenses: [Expense],
        in interval: DateInterval
    ) -> Double {
        self.expenses(expenses, in: interval)
            .reduce(0) { $0 + $1.amount }
    }

    static func totalsByCategory(
        for expenses: [Expense],
        in interval: DateInterval
    ) -> [UUID: Double] {
        expenses.reduce(into: [:]) { totals, expense in
            guard interval.contains(expense.date) else { return }
            totals[expense.categoryId, default: 0] += expense.amount
        }
    }

    static func projectedRecurringTotal(
        recurringExpenses: [RecurringExpense],
        in interval: DateInterval,
        calendar: Calendar = .current
    ) -> Double {
        recurringExpenses.reduce(0) { total, recurring in
            total + projectedTotal(for: recurring, in: interval, calendar: calendar)
        }
    }

    static func spendableToday(
        monthlyIncome: Double,
        expenses: [Expense],
        recurringExpenses: [RecurringExpense],
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> SpendableTodaySnapshot {
        let month = monthInterval(containing: date, calendar: calendar)
        let today = max(calendar.startOfDay(for: date), month.start)
        let remainingInterval = DateInterval(start: today, end: month.end)
        let spent = total(for: expenses, in: month)
        let upcoming = projectedRecurringTotal(
            recurringExpenses: recurringExpenses,
            in: remainingInterval,
            calendar: calendar
        )
        let remainingBeforeBills = monthlyIncome - spent
        let availableAfterBills = remainingBeforeBills - upcoming
        let daysRemaining = max(
            calendar.dateComponents([.day], from: today, to: month.end).day ?? 1,
            1
        )

        return SpendableTodaySnapshot(
            monthlyIncome: monthlyIncome,
            spentThisMonth: spent,
            upcomingRecurring: upcoming,
            remainingBeforeBills: remainingBeforeBills,
            availableAfterBills: availableAfterBills,
            daysRemaining: daysRemaining,
            spendableToday: max(availableAfterBills, 0) / Double(daysRemaining)
        )
    }

    private static func projectedTotal(
        for recurring: RecurringExpense,
        in interval: DateInterval,
        calendar: Calendar
    ) -> Double {
        // Anchored occurrences: Jan 31 monthly stays on month-end instead of drifting to the 28th.
        Double(recurring.upcomingOccurrences(in: interval, calendar: calendar).count) * recurring.amount
    }
}
