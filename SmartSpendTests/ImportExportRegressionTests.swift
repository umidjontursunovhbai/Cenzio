import Foundation
import PDFKit
import Testing
@testable import SmartSpend

@Suite("Import and export regression tests")
@MainActor
struct ImportExportRegressionTests {
    @Test("Exported expense CSV can be imported into an isolated empty store")
    func exportedFileRoundTrip() throws {
        let sourceSuite = "SmartSpend.ExportTest.Source.\(UUID().uuidString)"
        let targetSuite = "SmartSpend.ExportTest.Target.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
        }
        let source = DataManager(defaults: sourceDefaults, activityManager: GamificationManager(defaults: sourceDefaults))
        let target = DataManager(defaults: targetDefaults, activityManager: GamificationManager(defaults: targetDefaults))
        let category = UserCategory.imported(name: "Food, drinks")
        source.updateCurrency(.uzs)
        target.updateCurrency(.usd)
        source.userCategories = [category]
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        let title = "Coffee, \"large\"\nSecond line \\ receipt"
        source.expenses = [Expense(title: title, amount: 15_800, categoryId: category.id, date: date)]
        let url = try #require(DataExporter.shared.exportData(dataTypes: [.expenses], format: .csv, dataManager: source))
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try #require(DataImporter.shared.previewCSVImport(fileURL: url))
        #expect(preview.totalRows == 1)
        let result = DataImporter.shared.importFromCSV(fileURL: url, dataManager: target)
        guard case .success(let importedCount, let skippedCount, let errors) = result else {
            Issue.record("Exported CSV failed to import")
            return
        }
        #expect(importedCount == 1)
        #expect(skippedCount == 0)
        #expect(errors.isEmpty)
        #expect(target.expenses.first?.title == title)
        #expect(target.expenses.first?.amount == 15_800)
        #expect(target.user.currency == .uzs)
        #expect(target.expenses.first?.date == date)
        #expect(target.userCategories.map(\.name) == [category.name])
        #expect(target.userCategories.contains(where: { $0.name == "Other" }) == false)
        #expect(target.resolveCategory(id: target.expenses[0].categoryId).name == category.name)
    }

    @Test("Invalid or mixed CSV currencies reject the whole import without mutations", arguments: ["UZS\n2026-10-10,Second,100,New Category,USD", "XYZ", ""])
    func rejectsInvalidCurrencies(currencyRows: String) throws {
        let suiteName = "SmartSpend.ImportTest.Currency.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        manager.updateCurrency(.usd)
        let originalCategories = manager.userCategories.map(\.id)
        let csv = "Date,Title,Amount,Category,Currency\n2026-10-10,First,15800,New Category,\(currencyRows)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("currency-\(UUID().uuidString).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure(let error) = DataImporter.shared.importFromCSV(fileURL: url, dataManager: manager) else {
            Issue.record("Invalid currency import unexpectedly succeeded")
            return
        }
        #expect(error.lowercased().contains("currenc"))
        #expect(manager.expenses.isEmpty)
        #expect(manager.userCategories.map(\.id) == originalCategories)
        #expect(manager.user.currency == .usd)
    }

    @Test("Any financial data prevents importing a different currency", arguments: ["expenses", "recurring", "budgets", "goals", "salaries", "archived"])
    func rejectsLedgerCurrencyMismatch(ledger: String) throws {
        let suiteName = "SmartSpend.ImportTest.Ledger.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        manager.updateCurrency(.usd)
        let categoryID = UUID()
        let expense = Expense(title: "Existing", amount: 100, categoryId: categoryID, date: Date())
        switch ledger {
        case "expenses": manager.expenses = [expense]
        case "recurring": manager.recurringExpenses = [RecurringExpense(title: "Existing", amount: 100, categoryId: categoryID, recurrenceType: .monthly, startDate: Date())]
        case "budgets": manager.categoryBudgets = [CategoryBudget(categoryId: categoryID, amount: 100, isEnabled: true)]
        case "goals": manager.spendingGoals = [SpendingGoal(title: "Existing", targetAmount: 100, deadline: Date(), categoryId: categoryID)]
        case "salaries": manager.monthlySalaries = [MonthlySalary(year: 2026, month: 10, amount: 100, currency: .usd)]
        default: manager.deletedExpenses = [ArchivedExpense(from: expense)]
        }
        let originalCategories = manager.userCategories.map(\.id)
        let originalExpenseIDs = manager.expenses.map(\.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).csv")
        try "Date,Title,Amount,Category,Currency\n2026-10-10,Imported,15800,New Category,UZS\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure(let error) = DataImporter.shared.importFromCSV(fileURL: url, dataManager: manager) else {
            Issue.record("Conflicting currency import unexpectedly succeeded")
            return
        }
        #expect(error.contains("UZS") && error.contains("USD"))
        #expect(manager.user.currency == .usd)
        #expect(manager.userCategories.map(\.id) == originalCategories)
        #expect(manager.expenses.map(\.id) == originalExpenseIDs)
    }

    @Test("Legacy CSV without currency keeps the ledger currency")
    func legacyImportKeepsCurrency() throws {
        let suiteName = "SmartSpend.ImportTest.Legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        manager.updateCurrency(.uzs)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).csv")
        try "Date,Title,Amount,Category\n2026-10-10,Bus,15800,Transport\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let count, let skipped, _) = DataImporter.shared.importFromCSV(fileURL: url, dataManager: manager) else {
            Issue.record("Legacy CSV failed to import")
            return
        }
        #expect(count == 1 && skipped == 0)
        #expect(manager.user.currency == .uzs)
    }

    @Test("All-data PDF includes every selected data type and the final salary record")
    func exportedAllDataPDF() throws {
        let suiteName = "SmartSpend.ExportTest.PDF.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        let category = UserCategory.imported(name: "Report category")
        manager.userCategories = [category]
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        manager.expenses = (1...200).map { Expense(title: "Export expense \($0)", amount: 15_800, categoryId: category.id, date: date) }
        manager.recurringExpenses = [RecurringExpense(title: "Internet recurring", amount: 100, categoryId: category.id, recurrenceType: .monthly, startDate: date)]
        manager.categoryBudgets = [CategoryBudget(categoryId: category.id, amount: 700, isEnabled: true)]
        manager.spendingGoals = [SpendingGoal(title: "Camera savings", targetAmount: 900, deadline: date, categoryId: category.id)]
        manager.monthlySalaries = [MonthlySalary(year: 2026, month: 10, amount: 7_654_321, currency: .usd)]
        let url = try #require(DataExporter.shared.exportData(dataTypes: [.all], format: .pdf, dataManager: manager))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.pathExtension == "pdf")
        let document = try #require(PDFDocument(url: url))
        let text = try #require(document.string)
        #expect(document.pageCount > 1)
        for expected in ["EXPENSES", "Export expense 200", "RECURRING EXPENSES", "Internet recurring", "BUDGETS", "Report category", "SPENDING GOALS", "Camera savings", "MONTHLY SALARIES", "2026-10", "$7,654,321"] {
            #expect(text.contains(expected), "PDF missing \(expected)")
        }
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("$7,654,321") == true)
    }

    @Test("SmartSpend sectioned CSV imports only expenses and preserves quoted fields")
    func sectionedCSVRoundTrip() throws {
        let title = "Coffee, \"large\"\nSecond line \\ receipt"
        let category = "Food, drinks"
        let csv = "EXPENSES\nDate,Title,Amount,Category,Currency\n2026-10-10,\(ExpenseCSVDocument.escape(title)),15800,\(ExpenseCSVDocument.escape(category)),UZS\n\nRECURRING EXPENSES\nTitle,Amount,Category,Recurrence\nRent,900,Home,Monthly\n"
        let document = try ExpenseCSVDocument.parse(csv)
        #expect(document.headers == ["Date", "Title", "Amount", "Category", "Currency"])
        #expect(document.rows.count == 1)
        #expect(document.rows[0] == ["2026-10-10", title, "15800", category, "UZS"])
        let categoryID = UUID()
        let expenses = try DataImporter.shared.expensesFromCSV(csv, categoryMap: [category.lowercased(): categoryID])
        #expect(expenses.count == 1)
        #expect(expenses[0].title == title)
        #expect(expenses[0].amount == 15_800)
        #expect(expenses[0].categoryId == categoryID)
        #expect(Calendar.current.component(.day, from: expenses[0].date) == 10)
    }

    @Test("Plain CSV, BOM, CRLF and semicolons remain supported")
    func plainCSV() throws {
        let document = try ExpenseCSVDocument.parse("\u{FEFF}Date;Title;Amount;Category\r\n2026-10-10;Bus;15;Transport\r\n")
        #expect(document.rows == [["2026-10-10", "Bus", "15", "Transport"]])
        #expect(document.headers.count == 4)
    }

    @Test("Other export sections never become expense rows")
    func rejectsNonExpenseExport() throws {
        #expect(throws: ExpenseCSVDocument.CSVError.self) {
            try ExpenseCSVDocument.parse("SPENDING GOALS\nTitle,Target Amount,Current Amount,Deadline,Category,Completed\nHouse,100,10,2027-01-01,Home,No")
        }
        #expect(throws: ExpenseCSVDocument.CSVError.self) {
            try ExpenseCSVDocument.parse("Date,Title,Amount,Category\n2026-10-10,\"unfinished,50,Food")
        }
        #expect(throws: DataImporter.ImportError.self) {
            try DataImporter.shared.expensesFromCSV("Date,Title,Amount,Category\ninvalid-date,Coffee,50,Food", categoryMap: ["food": UUID()])
        }
    }

    @Test("Reports are real multi-page PDFs and include the final record")
    func multiPagePDF() throws {
        let content = (1...200).map { "Expense \($0): 15,800 so'm" }.joined(separator: "\n")
        let data = DataExporter.pdfData(content: content)
        #expect(String(data: data.prefix(5), encoding: .ascii) == "%PDF-")
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        #expect(document.string?.contains("Expense 200") == true)
    }
}
