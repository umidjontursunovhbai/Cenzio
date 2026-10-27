import Foundation
import Testing
@testable import SmartSpend

@Suite("Expenses page logic")
struct ExpenseListTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US_POSIX")
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func expense(_ title: String, _ amount: Double, _ date: Date, category: UUID = UUID()) -> Expense {
        Expense(title: title, amount: amount, categoryId: category, date: date)
    }

    // MARK: - Query

    @Test("Period filters use the injected 'now' and calendar days")
    func periods() {
        let now = date(2026, 10, 26, hour: 10)
        let today = expense("today", 1, date(2026, 10, 26, hour: 23, minute: 59))
        let yesterday = expense("yesterday", 1, date(2026, 10, 25, hour: 0))
        let lastMonth = expense("sep", 1, date(2026, 9, 30, hour: 23))
        let all = [today, yesterday, lastMonth]

        func titles(_ period: ExpensePeriod) -> [String] {
            ExpenseListQuery(period: period).apply(to: all, now: now, calendar: calendar).map(\.title)
        }

        #expect(titles(.all) == ["today", "yesterday", "sep"])
        #expect(titles(.today) == ["today"])
        #expect(titles(.yesterday) == ["yesterday"])
        #expect(titles(.month) == ["today", "yesterday"])

        var custom = ExpenseListQuery(period: .custom)
        custom.customStart = date(2026, 9, 30, hour: 15)
        custom.customEnd = date(2026, 10, 25, hour: 1)
        #expect(custom.apply(to: all, now: now, calendar: calendar).map(\.title) == ["yesterday", "sep"])
    }

    @Test("Search matches title, category name and exact amount, ignoring case, accents and padding")
    func search() {
        let food = UUID()
        let items = [
            expense("Café latte", 15_800, date(2026, 10, 1), category: food),
            expense("Bus", 2_500, date(2026, 10, 2)),
            expense("Taxi", 25_000, date(2026, 10, 3)),
        ]
        let names = [food: "Food"]

        func titles(_ text: String) -> [String] {
            ExpenseListQuery(searchText: text).apply(to: items, categoryNames: names, calendar: calendar).map(\.title)
        }

        #expect(titles("  cafe ") == ["Café latte"])
        #expect(titles("FOOD") == ["Café latte"])
        #expect(titles("2,500") == ["Bus"])
        #expect(titles("2500") == ["Bus"])
        #expect(titles("   ").count == 3)
        #expect(titles("pizza").isEmpty)
    }

    @Test("Category filter keeps only selected categories; empty means all")
    func categories() {
        let a = UUID(), b = UUID()
        let items = [expense("a", 1, date(2026, 10, 1), category: a), expense("b", 1, date(2026, 10, 2), category: b)]
        #expect(ExpenseListQuery().apply(to: items, calendar: calendar).count == 2)
        #expect(ExpenseListQuery(categoryIds: [a]).apply(to: items, calendar: calendar).map(\.title) == ["a"])
        #expect(ExpenseListQuery(categoryIds: [a]).hasFilters)
        #expect(!ExpenseListQuery(searchText: "x").hasFilters)
    }

    @Test("Same-timestamp expenses keep a stable newest-added-first order")
    func stableOrder() {
        let day = date(2026, 10, 1)
        let items = (0..<20).map { expense("\($0)", 1, day) }
        let result = ExpenseListQuery().apply(to: items, calendar: calendar).map(\.title)
        #expect(result == (0..<20).reversed().map(String.init))
    }

    // MARK: - Day groups

    @Test("Day totals cover the whole day even when pagination cuts it")
    func dayTotalsIgnorePagination() {
        let items = [
            expense("a", 100, date(2026, 10, 2, hour: 20)),
            expense("b", 200, date(2026, 10, 2, hour: 9)),
            expense("c", 300, date(2026, 10, 1, hour: 18)),
            expense("d", 400, date(2026, 10, 1, hour: 8)),
            expense("e", 500, date(2026, 9, 30, hour: 8)),
        ]
        let groups = ExpenseDayGroup.make(from: items, limit: 3, calendar: calendar)
        #expect(groups.count == 2)
        #expect(groups[0].expenses.map(\.title) == ["a", "b"])
        #expect(groups[0].total == 300)
        #expect(groups[1].expenses.map(\.title) == ["c"])
        #expect(groups[1].total == 700, "Day header must show the whole day's total, not just loaded rows")
        #expect(groups[1].count == 2)

        let full = ExpenseDayGroup.make(from: items, calendar: calendar)
        #expect(full.map(\.total) == [300, 700, 500])
        #expect(full.map(\.day) == [date(2026, 10, 2), date(2026, 10, 1), date(2026, 9, 30)])
        #expect(ExpenseDayGroup.make(from: items, limit: 0, calendar: calendar).isEmpty)
    }

    @Test("Day titles: Today, Yesterday, then weekday dates with a year only when needed")
    func dayTitles() {
        let now = date(2026, 10, 26, hour: 9)
        let locale = Locale(identifier: "en_US")
        #expect(ExpenseDayGroup.title(for: date(2026, 10, 26), now: now, calendar: calendar, locale: locale) == "today".localized)
        #expect(ExpenseDayGroup.title(for: date(2026, 10, 25), now: now, calendar: calendar, locale: locale) == "yesterday".localized)
        let thisYear = ExpenseDayGroup.title(for: date(2026, 10, 20), now: now, calendar: calendar, locale: locale)
        #expect(thisYear.contains("Tuesday") && thisYear.contains("20") && !thisYear.contains("2026"))
        #expect(ExpenseDayGroup.title(for: date(2025, 12, 31), now: now, calendar: calendar, locale: locale).contains("2025"))
    }

    @Test("Custom range text orders its ends and collapses a single day")
    func rangeText() {
        let now = date(2026, 10, 26)
        let locale = Locale(identifier: "en_US")
        let range = ExpenseRangeText.text(from: date(2026, 10, 12), through: date(2026, 10, 3), now: now, calendar: calendar, locale: locale)
        #expect(range == "Oct 3 – Oct 12")
        #expect(ExpenseRangeText.text(from: date(2026, 10, 3, hour: 8), through: date(2026, 10, 3, hour: 20), now: now, calendar: calendar, locale: locale) == "Oct 3")
        #expect(ExpenseRangeText.text(from: date(2025, 12, 30), through: date(2026, 1, 2), now: now, calendar: calendar, locale: locale).contains("2025"))
    }

    // MARK: - Selection

    @Test("Select all toggles over the current results and deletion only takes visible ones")
    func selection() {
        let items = (0..<3).map { expense("\($0)", 1, date(2026, 10, 1)) }
        let ids = items.map(\.id)
        #expect(ExpenseSelection.toggleAll(selected: [], visible: ids) == Set(ids))
        #expect(ExpenseSelection.toggleAll(selected: Set(ids), visible: ids).isEmpty)
        #expect(ExpenseSelection.toggleAll(selected: [ids[0]], visible: ids) == Set(ids))
        #expect(ExpenseSelection.toggleAll(selected: [], visible: []).isEmpty)

        let hidden = UUID()
        let deletable = ExpenseSelection.deletable(from: items, selected: [ids[2], hidden])
        #expect(deletable.map(\.id) == [ids[2]])
    }

    // MARK: - Edit validation

    @Test("Edit rejects zero, empty and whitespace-only input")
    func editValidation() {
        #expect(ExpenseEditValidator.amount("0") == nil)
        #expect(ExpenseEditValidator.amount("0.00") == nil)
        #expect(ExpenseEditValidator.amount("") == nil)
        #expect(ExpenseEditValidator.amount(".") == nil)
        #expect(ExpenseEditValidator.amount("15,800") == 15_800)
        #expect(ExpenseEditValidator.amount("0.5") == 0.5)
        #expect(ExpenseEditValidator.title("  \n ") == nil)
        #expect(ExpenseEditValidator.title("  Lunch ") == "Lunch")
    }

    // MARK: - Restore

    @MainActor
    private func withManager(_ body: (DataManager, UserDefaults) throws -> Void) throws {
        let suite = "SmartSpendTests.ExpenseList.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults)), defaults)
    }

    @Test("Restoring keeps the Notion link and original id, and persists")
    @MainActor
    func restoreKeepsNotionId() throws {
        try withManager { manager, defaults in
            var linked = Expense(title: "Linked", amount: 10, categoryId: UUID(), date: date(2026, 10, 1), notionId: "notion-page-1")
            linked.id = UUID()
            manager.expenses = [linked]
            manager.moveToDeletedExpenses(linked)
            #expect(manager.deletedExpenses.first?.notionId == "notion-page-1")

            manager.restoreExpense(try #require(manager.deletedExpenses.first))
            #expect(manager.expenses.map(\.id) == [linked.id])
            #expect(manager.expenses.first?.notionId == "notion-page-1")
            #expect(manager.deletedExpenses.isEmpty)

            let reloaded = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
            #expect(reloaded.expenses.first?.notionId == "notion-page-1")
        }
    }

    @Test("Undo restores a whole batch and skips ids that are already active")
    @MainActor
    func batchRestore() throws {
        try withManager { manager, _ in
            let items = (0..<3).map { expense("\($0)", Double($0 + 1), date(2026, 10, $0 + 1)) }
            manager.expenses = items
            manager.moveToDeletedExpenses(items)
            #expect(manager.expenses.isEmpty)

            manager.restoreExpenses(ids: [items[0].id, items[2].id, UUID()])
            #expect(Set(manager.expenses.map(\.id)) == [items[0].id, items[2].id])
            #expect(manager.deletedExpenses.map(\.id) == [items[1].id])

            // An archived copy whose id is already active stays archived (no duplicates).
            manager.expenses.append(items[1])
            manager.restoreExpenses(ids: [items[1].id])
            #expect(manager.expenses.filter { $0.id == items[1].id }.count == 1)
        }
    }

    @Test("Archives saved before notionId existed still decode")
    func legacyArchiveDecodes() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","title":"Old","amount":5,"categoryId":"\(UUID().uuidString)",
          "date":0,"archivedDate":0}]
        """
        let decoded = try JSONDecoder().decode([ArchivedExpense].self, from: Data(json.utf8))
        #expect(decoded.first?.notionId == nil)
        #expect(decoded.first?.title == "Old")
    }
}
