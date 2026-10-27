//
//  SmartSpendTests.swift
//  SmartSpendTests
//
//  Created by Umidjon Tursunov on 23/08/2025.
//

import Testing
import Foundation
@testable import SmartSpend

@Suite("SmartSpend Tests")
struct SmartSpendTests {

    @Test("Example test")
    func example() async throws {
        #expect(true, "This test should pass")
    }

    @Test("Expense creation")
    func expenseCreation() async throws {
        let categoryId = UUID()
        let expense = Expense(
            title: "Test Expense",
            amount: 100.0,
            categoryId: categoryId,
            date: Date()
        )
        
        #expect(expense.title == "Test Expense")
        #expect(expense.amount == 100.0)
        #expect(expense.categoryId == categoryId)
    }
    
    @Test("Monthly salary creation")
    func monthlySalaryCreation() async throws {
        let salary = MonthlySalary(
            year: 2025,
            month: 11,
            amount: 5000.0,
            currency: .usd
        )
        
        #expect(salary.year == 2025)
        #expect(salary.month == 11)
        #expect(salary.amount == 5000.0)
        #expect(salary.currency == .usd)
        #expect(!salary.id.uuidString.isEmpty)
    }

    @Test("Imported category gets default style")
    func importedCategoryDefaultStyle() async throws {
        let food = UserCategory.imported(name: "Food")
        let other = UserCategory.imported(name: "Other")

        #expect(food.iconSystemName == "shopping-cart")
        #expect(food.colorName == "systemOrange")
        #expect(other.iconSystemName == "tag")
        #expect(other.colorName == "systemGray")
    }

    @Test("Category icon presets are unique Heroicons")
    @MainActor
    func categoryIconPresetsAreUniqueHeroicons() async throws {
        let icons = UserCategory.presetIcons
        let resolvedIcons = icons.map { HeroIcon.resolvedName($0) }

        #expect(Set(icons).count == icons.count)
        #expect(Set(resolvedIcons).count == icons.count)
        #expect(HeroIcon.resolvedName("fork.knife") == "shopping-cart")
    }

    @Test("Amount input formatter groups while preserving typed decimals")
    func amountInputFormatterGroupsWhilePreservingTypedDecimals() async throws {
        #expect(AmountInputFormatter.formatEditingText("1500000") == "1,500,000")
        #expect(AmountInputFormatter.formatEditingText("1500000.") == "1,500,000.")
        #expect(AmountInputFormatter.formatEditingText("1500000.50") == "1,500,000.50")
        #expect(AmountInputFormatter.formatValue(150000.0) == "150,000")
        #expect(AmountInputFormatter.parse("1,500,000.50") == 1_500_000.50)
    }

    @Test("Currency display omits unnecessary decimal zeros")
    func currencyDisplayOmitsDecimalZeros() async throws {
        #expect(CurrencyFormatter.formatFull(15_800, currency: .uzs) == "15,800 so'm")
        #expect(CurrencyFormatter.format(15_800, currency: .uzs) == "15,800 so'm")
        #expect(CurrencyFormatter.formatFull(15_800, currency: .usd) == "$15,800")
        #expect(CurrencyFormatter.formatFull(15_800.5, currency: .usd) == "$15,800.50")
    }

    @Test("Monthly budget excludes expenses from earlier months")
    func monthlyBudgetUsesCurrentMonthOnly() async throws {
        let calendar = testCalendar
        let currentDate = makeDate(2026, 8, 15, calendar: calendar)
        let categoryId = UUID()
        let expenses = [
            Expense(
                title: "Previous month",
                amount: 900,
                categoryId: categoryId,
                date: makeDate(2026, 7, 31, calendar: calendar)
            ),
            Expense(
                title: "Current month",
                amount: 300,
                categoryId: categoryId,
                date: makeDate(2026, 8, 10, calendar: calendar)
            )
        ]

        let snapshot = BudgetPeriodCalculator.spendableToday(
            monthlyIncome: 1_000,
            expenses: expenses,
            recurringExpenses: [],
            on: currentDate,
            calendar: calendar
        )

        #expect(snapshot.spentThisMonth == 300)
        #expect(snapshot.remainingBeforeBills == 700)
        #expect(snapshot.daysRemaining == 17)
    }

    @Test("Monthly category totals scan expenses once and exclude other months")
    func monthlyCategoryTotals() async throws {
        let calendar = testCalendar
        let currentDate = makeDate(2026, 8, 15, calendar: calendar)
        let month = BudgetPeriodCalculator.monthInterval(containing: currentDate, calendar: calendar)
        let foodId = UUID()
        let travelId = UUID()
        let expenses = [
            Expense(title: "Food one", amount: 120, categoryId: foodId, date: makeDate(2026, 8, 1, calendar: calendar)),
            Expense(title: "Food two", amount: 80, categoryId: foodId, date: makeDate(2026, 8, 31, calendar: calendar)),
            Expense(title: "Travel", amount: 300, categoryId: travelId, date: makeDate(2026, 8, 10, calendar: calendar)),
            Expense(title: "Old food", amount: 999, categoryId: foodId, date: makeDate(2026, 7, 31, calendar: calendar))
        ]

        let totals = BudgetPeriodCalculator.totalsByCategory(for: expenses, in: month)

        #expect(totals[foodId] == 200)
        #expect(totals[travelId] == 300)
        #expect(totals.values.reduce(0, +) == 500)
    }

    @Test("Dashboard shows only current-month spending and orders categories")
    func dashboardOverviewUsesCurrentMonth() async throws {
        let calendar = testCalendar
        let now = makeDate(2026, 8, 15, calendar: calendar)
        let food = UUID()
        let travel = UUID()
        let expenses = [
            Expense(title: "Old", amount: 900, categoryId: food, date: makeDate(2026, 7, 31, calendar: calendar)),
            Expense(title: "Food", amount: 80, categoryId: food, date: makeDate(2026, 8, 1, calendar: calendar)),
            Expense(title: "Travel", amount: 120, categoryId: travel, date: makeDate(2026, 8, 15, calendar: calendar)),
            Expense(title: "Future this month", amount: 600, categoryId: food, date: makeDate(2026, 8, 20, calendar: calendar)),
            Expense(title: "Next month", amount: 700, categoryId: food, date: makeDate(2026, 9, 1, calendar: calendar))
        ]

        let overview = DashboardOverview(expenses: expenses, now: now, calendar: calendar)

        #expect(overview.monthExpenses.count == 2)
        #expect(overview.monthTotal == 200)
        #expect(overview.categoryTotals[food] == 80)
        #expect(overview.sortedCategories.map(\.categoryID) == [travel, food])
        #expect(overview.recentExpenses.first?.title == "Travel")
        #expect(overview.previousMonthsWithExpenses.map(\.amount) == [900])
    }

    @Test("Dashboard handles an empty month without invented category data")
    func dashboardOverviewEmptyMonth() async throws {
        let overview = DashboardOverview(
            expenses: [],
            now: makeDate(2026, 8, 15, calendar: testCalendar),
            calendar: testCalendar
        )

        #expect(overview.monthTotal == 0)
        #expect(overview.categoryTotals.isEmpty)
        #expect(overview.sortedCategories.isEmpty)
        #expect(overview.recentExpenses.isEmpty)
        #expect(overview.previousMonthsWithExpenses.isEmpty)
    }

    @Test("Previous months show recorded totals newest first without empty months")
    func previousMonthsShowOnlyRecordedSpending() async throws {
        let calendar = testCalendar
        let category = UUID()
        let overview = DashboardOverview(
            expenses: [
                Expense(title: "July", amount: 120, categoryId: category, date: makeDate(2026, 7, 10, calendar: calendar)),
                Expense(title: "May", amount: 80, categoryId: category, date: makeDate(2026, 5, 3, calendar: calendar)),
                Expense(title: "May again", amount: 20, categoryId: category, date: makeDate(2026, 5, 20, calendar: calendar)),
                Expense(title: "Old record", amount: 40, categoryId: category, date: makeDate(2025, 11, 2, calendar: calendar)),
                Expense(title: "Older record", amount: 30, categoryId: category, date: makeDate(2025, 10, 2, calendar: calendar)),
                Expense(title: "Current", amount: 500, categoryId: category, date: makeDate(2026, 8, 2, calendar: calendar))
            ],
            now: makeDate(2026, 8, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(overview.previousMonthsWithExpenses.map(\.amount) == [120, 100, 40])
        #expect(overview.previousMonthsWithExpenses.map { calendar.component(.month, from: $0.month) } == [7, 5, 11])
    }

    @Test("Dashboard calendar covers the whole month with per-day totals")
    func dashboardCalendarDays() async throws {
        let calendar = testCalendar
        let category = UUID()
        let overview = DashboardOverview(
            expenses: [
                Expense(title: "Lunch", amount: 50, categoryId: category, date: makeDate(2026, 8, 3, calendar: calendar)),
                Expense(title: "Taxi", amount: 30, categoryId: category, date: makeDate(2026, 8, 3, calendar: calendar)),
                Expense(title: "Future", amount: 600, categoryId: category, date: makeDate(2026, 8, 20, calendar: calendar)),
                Expense(title: "July", amount: 40, categoryId: category, date: makeDate(2026, 7, 31, calendar: calendar))
            ],
            now: makeDate(2026, 8, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(overview.calendarDays.count == 31)
        // 1 Aug 2026 is a Saturday; the Gregorian calendar starts weeks on Sunday.
        #expect(overview.leadingBlankDays == 6)
        let third = try #require(overview.calendarDays.first { $0.day == 3 })
        #expect(third.amount == 80)
        #expect(third.count == 2)
        #expect(overview.calendarDays.first { $0.day == 1 }?.amount == 0)
        #expect(overview.calendarDays.first { $0.day == 15 }?.isFuture == false)
        let twentieth = try #require(overview.calendarDays.first { $0.day == 20 })
        #expect(twentieth.isFuture)
        #expect(twentieth.amount == 0)
    }

    @Test("Weekday pattern averages from the first recorded day, not empty weeks")
    func dashboardWeekdayAverages() async throws {
        let calendar = testCalendar
        let category = UUID()
        // 15 Aug 2026 is a Saturday.
        let overview = DashboardOverview(
            expenses: [
                Expense(title: "Sat", amount: 100, categoryId: category, date: makeDate(2026, 8, 8, calendar: calendar)),
                Expense(title: "Mon", amount: 30, categoryId: category, date: makeDate(2026, 8, 10, calendar: calendar)),
                Expense(title: "Sat again", amount: 50, categoryId: category, date: makeDate(2026, 8, 15, calendar: calendar)),
                Expense(title: "Too old", amount: 999, categoryId: category, date: makeDate(2026, 1, 3, calendar: calendar))
            ],
            now: makeDate(2026, 8, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(overview.weekdaySampleDays == 8)
        #expect(overview.weekdayAverages.map(\.weekday) == [1, 2, 3, 4, 5, 6, 7])
        #expect(overview.weekdayAverages.first { $0.weekday == 7 }?.average == 75)
        #expect(overview.weekdayAverages.first { $0.weekday == 2 }?.average == 30)
        #expect(overview.weekdayAverages.first { $0.weekday == 1 }?.average == 0)
        #expect(overview.peakWeekday?.weekday == 7)
    }

    @Test("Top titles merge case and spacing; largest expenses rank by amount")
    func dashboardTopTitlesAndLargest() async throws {
        let calendar = testCalendar
        let food = UUID()
        let travel = UUID()
        let overview = DashboardOverview(
            expenses: [
                Expense(title: "Coffee", amount: 10, categoryId: food, date: makeDate(2026, 8, 2, calendar: calendar)),
                Expense(title: " coffee ", amount: 15, categoryId: food, date: makeDate(2026, 8, 4, calendar: calendar)),
                Expense(title: "Taxi", amount: 20, categoryId: travel, date: makeDate(2026, 8, 5, calendar: calendar)),
                Expense(title: "Rent", amount: 5, categoryId: food, date: makeDate(2026, 8, 6, calendar: calendar)),
                Expense(title: "Coffee", amount: 500, categoryId: food, date: makeDate(2026, 7, 6, calendar: calendar))
            ],
            now: makeDate(2026, 8, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(overview.topTitles.map(\.amount) == [25, 20, 5])
        #expect(overview.topTitles.first?.count == 2)
        #expect(overview.topTitles.first?.title == "coffee")
        #expect(overview.largestExpenses.map(\.amount) == [20, 15, 10, 5])
    }

    @Test("Monthly history spans six months and pace compares to an even spread")
    func dashboardMonthlyHistoryAndPace() async throws {
        let calendar = testCalendar
        let category = UUID()
        let overview = DashboardOverview(
            expenses: [
                Expense(title: "Aug", amount: 2_000, categoryId: category, date: makeDate(2026, 8, 2, calendar: calendar)),
                Expense(title: "Jun", amount: 300, categoryId: category, date: makeDate(2026, 6, 9, calendar: calendar)),
                Expense(title: "Ancient", amount: 700, categoryId: category, date: makeDate(2025, 12, 9, calendar: calendar))
            ],
            now: makeDate(2026, 8, 15, calendar: calendar),
            calendar: calendar
        )

        #expect(overview.monthlyHistory.map { calendar.component(.month, from: $0.month) } == [3, 4, 5, 6, 7, 8])
        #expect(overview.monthlyHistory.map(\.amount) == [0, 0, 0, 300, 0, 2_000])
        // 3,100 over 31 days → 1,500 expected by day 15.
        #expect(overview.paceDifference(monthlyIncome: 3_100) == 500)
        #expect(overview.paceDifference(monthlyIncome: 0) == 0)
    }

    @Test("Dashboard insights stay empty for a month without spending")
    func dashboardInsightsEmptyMonth() async throws {
        let overview = DashboardOverview(
            expenses: [],
            now: makeDate(2026, 8, 15, calendar: testCalendar),
            calendar: testCalendar
        )

        #expect(overview.calendarDays.count == 31)
        #expect(overview.calendarDays.allSatisfy { $0.amount == 0 && $0.count == 0 })
        #expect(overview.topTitles.isEmpty)
        #expect(overview.largestExpenses.isEmpty)
        #expect(overview.peakWeekday == nil)
        #expect(overview.weekdaySampleDays == 0)
        #expect(overview.monthlyHistory.count == 6)
        #expect(overview.monthlyHistory.allSatisfy { $0.amount == 0 })
    }

    @Test("Spendable today reserves recurring bills before month end")
    func spendableTodayReservesRecurringBills() async throws {
        let calendar = testCalendar
        let currentDate = makeDate(2026, 8, 15, calendar: calendar)
        let categoryId = UUID()
        let weeklyBill = RecurringExpense(
            title: "Weekly bill",
            amount: 50,
            categoryId: categoryId,
            recurrenceType: .weekly,
            startDate: makeDate(2026, 8, 10, calendar: calendar)
        )

        let snapshot = BudgetPeriodCalculator.spendableToday(
            monthlyIncome: 1_000,
            expenses: [],
            recurringExpenses: [weeklyBill],
            on: currentDate,
            calendar: calendar
        )

        #expect(snapshot.upcomingRecurring == 150)
        #expect(snapshot.availableAfterBills == 850)
        #expect(abs(snapshot.spendableToday - 50) < 0.001)
    }

    private var testCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
