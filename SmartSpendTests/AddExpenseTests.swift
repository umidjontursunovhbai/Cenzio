import Foundation
import Testing
@testable import SmartSpend

@Suite("Add expense flow")
struct AddExpenseTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @MainActor
    private func withManager(_ body: (DataManager, UserDefaults) throws -> Void) throws {
        let suite = "SmartSpendTests.AddExpense.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults)), defaults)
    }

    // MARK: Amount input

    @Test("A comma typed on a comma-decimal keyboard becomes the decimal point")
    func typedCommaIsDecimal() {
        #expect(AmountInputFormatter.formatEditingText("12,", previous: "12") == "12.")
        #expect(AmountInputFormatter.formatEditingText(",", previous: "") == "0.")
        #expect(AmountInputFormatter.formatEditingText("1,500,", previous: "1,500") == "1,500.")
        // A second decimal key press is ignored.
        #expect(AmountInputFormatter.formatEditingText("12.5,", previous: "12.5") == "12.5")
        #expect(AmountInputFormatter.parse(AmountInputFormatter.formatEditingText("12,", previous: "12") + "5") == 12.5)
    }

    @Test("Deleting a digit regroups instead of reading the grouping comma as a decimal")
    func deletionRegroups() {
        #expect(AmountInputFormatter.formatEditingText("1,23", previous: "1,234") == "123")
        #expect(AmountInputFormatter.formatEditingText("1,2345", previous: "1,234") == "12,345")
    }

    @Test("Pasted amounts in either notation are read as the number they show")
    func pastedAmounts() {
        #expect(AmountInputFormatter.formatEditingText("1.234,56", previous: "") == "1,234.56")
        #expect(AmountInputFormatter.formatEditingText("1,234.56", previous: "") == "1,234.56")
        #expect(AmountInputFormatter.formatEditingText("12,50", previous: "") == "12.50")
        #expect(AmountInputFormatter.formatEditingText("1 500 000", previous: "") == "1,500,000")
        #expect(AmountInputFormatter.formatEditingText("1,500", previous: "") == "1,500")
        #expect(AmountInputFormatter.formatEditingText("1.234.567", previous: "") == "1,234,567")
        #expect(AmountInputFormatter.formatEditingText("$12.50", previous: "") == "12.50")
        #expect(AmountInputFormatter.formatEditingText("-5", previous: "") == "5")
    }

    @Test("Integer digits are capped while typing, but parsing never truncates")
    func integerCap() {
        #expect(AmountInputFormatter.formatEditingText("1234567890123") == "123,456,789,012")
        #expect(AmountInputFormatter.formatEditingText("000012") == "12")
        #expect(AmountInputFormatter.parse("1234567890123") == 1_234_567_890_123)
    }

    @Test("Only real decimal digits count; other numeric characters are ignored")
    func unicodeDigits() {
        #expect(AmountInputFormatter.parse("٣٤") == 34)
        #expect(AmountInputFormatter.parse("½") == nil)
        #expect(AmountInputFormatter.parse("5½") == 5)
        #expect(AmountInputFormatter.formatEditingText("Ⅻ7") == "7")
    }

    // MARK: Form rules

    @Test("Titles are saved on one line without surrounding whitespace")
    func titleNormalization() {
        #expect(AddExpenseDraft.normalizedTitle("  Coffee\n") == "Coffee")
        #expect(AddExpenseDraft.normalizedTitle("Bus\nticket") == "Bus ticket")
        #expect(AddExpenseDraft.normalizedTitle(" \n ").isEmpty)
    }

    @Test("Save is enabled only for a complete, positive expense")
    func saveEnabled() {
        let id = UUID()
        func can(_ title: String = "Bus", amount: String = "2,500", category: UUID? = nil,
                 available: Set<UUID>? = nil, currency: Bool = true) -> Bool {
            AddExpenseDraft.canSave(title: title, amount: amount, categoryID: category ?? id,
                                    availableCategoryIDs: available ?? [id], currencyMatches: currency)
        }
        #expect(can())
        #expect(!can(" \n"))
        #expect(!can(amount: ""))
        #expect(!can(amount: "0"))
        #expect(!can(amount: "0."))
        #expect(!can(amount: "."))
        #expect(!can(available: [])) // category deleted while the form was open
        #expect(!can(currency: false))
        #expect(!AddExpenseDraft.canSave(title: "Bus", amount: "5", categoryID: nil, availableCategoryIDs: [id],
                                         currencyMatches: true))
    }

    @Test("The chosen day keeps the current time of day and never lies in the future")
    func expenseDate() {
        let now = date(2026, 10, 26, hour: 14, minute: 30)
        #expect(AddExpenseDraft.date(onDayOf: date(2026, 10, 25), timeFrom: now, calendar: calendar)
                == date(2026, 10, 25, hour: 14, minute: 30))
        #expect(AddExpenseDraft.date(onDayOf: date(2026, 10, 26), timeFrom: now, calendar: calendar) == now)
        let latest = AddExpenseDraft.latestAllowedDate(now: now, calendar: calendar)
        #expect(latest == date(2026, 10, 27).addingTimeInterval(-1))
        #expect(AddExpenseDraft.date(onDayOf: date(2026, 11, 3), timeFrom: now, calendar: calendar) == latest)
    }

    @Test("A learned category replaces only the default, never the user's choice")
    func autoCategory() {
        let food = UserCategory(name: "Food")
        let current = UUID()
        #expect(AddExpenseDraft.autoSelectedCategoryID(current: current, userChose: false, suggestions: [(food, 0.9)]) == food.id)
        #expect(AddExpenseDraft.autoSelectedCategoryID(current: current, userChose: true, suggestions: [(food, 0.9)]) == current)
        #expect(AddExpenseDraft.autoSelectedCategoryID(current: current, userChose: false, suggestions: [(food, 0.4)]) == current)
        #expect(AddExpenseDraft.autoSelectedCategoryID(current: nil, userChose: false, suggestions: []) == nil)
    }

    // MARK: DataManager

    @Test("Category suggestions never offer a deleted category")
    @MainActor
    func suggestionsSkipDeletedCategories() throws {
        try withManager { manager, _ in
            let transport = UserCategory(name: "Transport")
            let deleted = UUID()
            manager.userCategories = [transport]
            manager.addExpensesBatch([
                Expense(title: "Bus", amount: 2500, categoryId: deleted),
                Expense(title: "Bus", amount: 2500, categoryId: deleted),
                Expense(title: "Bus", amount: 2500, categoryId: transport.id),
            ])
            let suggestions = manager.getTopCategorySuggestions(for: "Bus")
            #expect(suggestions.map(\.category.id) == [transport.id])
        }
    }

    @Test("Merging similar patterns keeps real prices instead of suggesting 0")
    @MainActor
    func mergeKeepsPrices() throws {
        try withManager { manager, _ in
            let food = UserCategory(name: "Food")
            manager.userCategories = [food]
            // Different titles with identical keywords are merged by the learning engine.
            manager.addExpensesBatch([
                Expense(title: "Coffee latte", amount: 5, categoryId: food.id),
                Expense(title: "Coffee, latte", amount: 5, categoryId: food.id),
            ])
            #expect(manager.learnedPatterns.count == 1)
            #expect(manager.learnedPatterns.allSatisfy { $0.combinations.allSatisfy { $0.price > 0 } })
            #expect(manager.getCategoryFocusedSuggestions(for: "Coffee latte").first?.mostUsedPrice == 5)
        }
    }

    @Test("A manually added expense is persisted")
    @MainActor
    func addExpensePersists() throws {
        try withManager { manager, defaults in
            let food = UserCategory(name: "Food")
            manager.userCategories = [food]
            let expense = Expense(title: "Lunch", amount: 12.5, categoryId: food.id)
            manager.addExpense(expense)
            let restored = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
            #expect(restored.expenses.map(\.id) == [expense.id])
        }
    }
}
