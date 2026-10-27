import Foundation
import SwiftUI
import UIKit
import CoreText

class DataExporter: ObservableObject {
    static let shared = DataExporter()
    
    private init() {}
    
    enum ExportFormat: String, CaseIterable {
        case csv = "CSV"
        case json = "JSON"
        case pdf = "PDF"
        
        var fileExtension: String {
            switch self {
            case .csv:
                return "csv"
            case .json:
                return "json"
            case .pdf:
                return "pdf"
            }
        }
        
        var icon: String {
            switch self {
            case .csv:
                return "tablecells"
            case .json:
                return "doc.text"
            case .pdf:
                return "doc.richtext"
            }
        }
    }
    
    enum ExportData: String, CaseIterable {
        case expenses = "Expenses"
        case recurringExpenses = "Recurring Expenses"
        case budgets = "Budgets"
        case spendingGoals = "Spending Goals"
        case monthlySalaries = "Monthly Salaries"
        case all = "All Data"
        
        var icon: String {
            switch self {
            case .expenses:
                return "list.bullet.rectangle"
            case .recurringExpenses:
                return "repeat"
            case .budgets:
                return "target"
            case .spendingGoals:
                return "flag.checkered"
            case .monthlySalaries:
                return "calendar.badge.plus"
            case .all:
                return "doc.on.doc"
            }
        }
        
        var localizedName: String {
            switch self {
            case .expenses:
                return "Expenses"
            case .recurringExpenses:
                return "Recurring Expenses"
            case .budgets:
                return "Budgets"
            case .spendingGoals:
                return "Spending Goals"
            case .monthlySalaries:
                return "Monthly Salaries"
            case .all:
                return "All Data"
            }
        }
    }
    
    // MARK: - Export Methods
    
    func exportData(
        dataTypes: Set<ExportData>,
        format: ExportFormat,
        dateRange: DateInterval? = nil,
        dataManager: DataManager = .shared
    ) -> URL? {
        switch format {
        case .csv:
            return exportToCSV(dataTypes: dataTypes, dataManager: dataManager, dateRange: dateRange)
        case .json:
            return exportToJSON(dataTypes: dataTypes, dataManager: dataManager, dateRange: dateRange)
        case .pdf:
            return exportToPDF(dataTypes: dataTypes, dataManager: dataManager, dateRange: dateRange)
        }
    }
    
    // MARK: - CSV Export
    
    private func exportToCSV(
        dataTypes: Set<ExportData>,
        dataManager: DataManager,
        dateRange: DateInterval?
    ) -> URL? {
        var csvContent = ""
        
        if dataTypes.contains(.expenses) || dataTypes.contains(.all) {
            csvContent += exportExpensesToCSV(dataManager: dataManager, dateRange: dateRange)
            csvContent += "\n\n"
        }
        
        if dataTypes.contains(.recurringExpenses) || dataTypes.contains(.all) {
            csvContent += exportRecurringExpensesToCSV(dataManager: dataManager)
            csvContent += "\n\n"
        }
        
        if dataTypes.contains(.budgets) || dataTypes.contains(.all) {
            csvContent += exportBudgetsToCSV(dataManager: dataManager)
            csvContent += "\n\n"
        }
        
        if dataTypes.contains(.spendingGoals) || dataTypes.contains(.all) {
            csvContent += exportSpendingGoalsToCSV(dataManager: dataManager)
            csvContent += "\n\n"
        }
        
        if dataTypes.contains(.monthlySalaries) || dataTypes.contains(.all) {
            csvContent += exportMonthlySalariesToCSV(dataManager: dataManager)
        }
        
        return saveToFile(content: csvContent, fileName: "Cenzio_Export", extension: "csv")
    }
    
    private func exportExpensesToCSV(dataManager: DataManager, dateRange: DateInterval?) -> String {
        var csv = "EXPENSES\n"
        csv += "Date,Title,Amount,Category,Currency\n"
        
        let filteredExpenses = filterExpensesByDate(dataManager.expenses, dateRange: dateRange)
        
        for expense in filteredExpenses.sorted(by: { $0.date > $1.date }) {
            let dateString = DateFormatter.exportDate.string(from: expense.date)
            let title = escapeCSVField(expense.title)
            let amount = String(expense.amount)
            let category = escapeCSVField(dataManager.resolveCategory(id: expense.categoryId).name)
            let currency = dataManager.user.currency.rawValue
            
            csv += "\(dateString),\(title),\(amount),\(category),\(currency)\n"
        }
        
        return csv
    }
    
    private func exportRecurringExpensesToCSV(dataManager: DataManager) -> String {
        var csv = "RECURRING EXPENSES\n"
        csv += "Title,Amount,Category,Recurrence,Start Date,End Date,Active,Last Processed\n"
        
        for recurring in dataManager.recurringExpenses {
            let title = escapeCSVField(recurring.title)
            let amount = String(recurring.amount)
            let category = escapeCSVField(dataManager.resolveCategory(id: recurring.categoryId).name)
            let recurrence = recurring.recurrenceType.rawValue
            let startDate = DateFormatter.exportDate.string(from: recurring.startDate)
            let endDate = recurring.endDate.map { DateFormatter.exportDate.string(from: $0) } ?? ""
            let active = recurring.isActive ? "Yes" : "No"
            let lastProcessed = recurring.lastProcessedDate.map { DateFormatter.exportDate.string(from: $0) } ?? ""
            
            csv += "\(title),\(amount),\(category),\(recurrence),\(startDate),\(endDate),\(active),\(lastProcessed)\n"
        }
        
        return csv
    }
    
    private func exportBudgetsToCSV(dataManager: DataManager) -> String {
        var csv = "BUDGETS\n"
        csv += "Category,Amount,Enabled\n"
        
        for budget in dataManager.categoryBudgets {
            let category = escapeCSVField(dataManager.resolveCategory(id: budget.categoryId).name)
            let amount = String(budget.amount)
            let enabled = budget.isEnabled ? "Yes" : "No"
            
            csv += "\(category),\(amount),\(enabled)\n"
        }
        
        return csv
    }
    
    private func exportSpendingGoalsToCSV(dataManager: DataManager) -> String {
        var csv = "SPENDING GOALS\n"
        csv += "Title,Target Amount,Current Amount,Deadline,Category,Completed\n"
        
        for goal in dataManager.spendingGoals {
            let title = escapeCSVField(goal.title)
            let targetAmount = String(goal.targetAmount)
            let currentAmount = String(goal.currentAmount)
            let deadline = DateFormatter.exportDate.string(from: goal.deadline)
            let category = escapeCSVField(dataManager.resolveCategory(id: goal.categoryId).name)
            let completed = goal.isCompleted ? "Yes" : "No"
            
            csv += "\(title),\(targetAmount),\(currentAmount),\(deadline),\(category),\(completed)\n"
        }
        
        return csv
    }
    
    private func exportMonthlySalariesToCSV(dataManager: DataManager) -> String {
        var csv = "MONTHLY SALARIES\n"
        csv += "Year,Month,Amount,Currency\n"
        
        for salary in dataManager.monthlySalaries.sorted(by: { $0.year > $1.year || ($0.year == $1.year && $0.month > $1.month) }) {
            csv += "\(salary.year),\(salary.month),\(salary.amount),\(salary.currency.rawValue)\n"
        }
        
        return csv
    }
    
    // MARK: - JSON Export
    
    private func exportToJSON(
        dataTypes: Set<ExportData>,
        dataManager: DataManager,
        dateRange: DateInterval?
    ) -> URL? {
        var exportData: [String: Any] = [:]
        exportData["exportDate"] = DateFormatter.exportDate.string(from: Date())
        exportData["appVersion"] = "2.0"
        
        if dataTypes.contains(.expenses) || dataTypes.contains(.all) {
            let filteredExpenses = filterExpensesByDate(dataManager.expenses, dateRange: dateRange)
            exportData["expenses"] = filteredExpenses.map { expenseToDict($0, currency: dataManager.user.currency, dataManager: dataManager) }
        }
        
        if dataTypes.contains(.recurringExpenses) || dataTypes.contains(.all) {
            exportData["recurringExpenses"] = dataManager.recurringExpenses.map { recurringExpenseToDict($0, dataManager: dataManager) }
        }
        
        if dataTypes.contains(.budgets) || dataTypes.contains(.all) {
            exportData["budgets"] = dataManager.categoryBudgets.map { budgetToDict($0, dataManager: dataManager) }
        }
        
        if dataTypes.contains(.spendingGoals) || dataTypes.contains(.all) {
            exportData["spendingGoals"] = dataManager.spendingGoals.map { spendingGoalToDict($0, dataManager: dataManager) }
        }
        
        if dataTypes.contains(.monthlySalaries) || dataTypes.contains(.all) {
            exportData["monthlySalaries"] = dataManager.monthlySalaries.map(monthlySalaryToDict)
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            return saveToFile(content: jsonString, fileName: "Cenzio_Export", extension: "json")
        } catch {
            return nil
        }
    }
    
    // MARK: - PDF Export
    
    private func exportToPDF(
        dataTypes: Set<ExportData>,
        dataManager: DataManager,
        dateRange: DateInterval?
    ) -> URL? {
        var content = "SMARTSPEND DATA EXPORT\n"
        content += "Generated on: \(DateFormatter.exportDateTime.string(from: Date()))\n\n"
        
        if let range = dateRange {
            content += "Date Range: \(DateFormatter.exportDate.string(from: range.start)) - \(DateFormatter.exportDate.string(from: range.end))\n\n"
        }
        
        if dataTypes.contains(.expenses) || dataTypes.contains(.all) {
            content += exportExpensesToText(dataManager: dataManager, dateRange: dateRange)
            content += "\n\n"
        }
        
        if dataTypes.contains(.recurringExpenses) || dataTypes.contains(.all) {
            content += exportRecurringExpensesToText(dataManager: dataManager)
            content += "\n\n"
        }
        
        if dataTypes.contains(.budgets) || dataTypes.contains(.all) {
            content += "BUDGETS\n"
            for budget in dataManager.categoryBudgets {
                content += "\(dataManager.resolveCategory(id: budget.categoryId).name) — \(CurrencyFormatter.formatFull(budget.amount, currency: dataManager.user.currency)) — \(budget.isEnabled ? "Enabled" : "Disabled")\n"
            }
            content += "\n"
        }
        if dataTypes.contains(.spendingGoals) || dataTypes.contains(.all) {
            content += "SPENDING GOALS\n"
            for goal in dataManager.spendingGoals {
                content += "\(goal.title) — \(dataManager.resolveCategory(id: goal.categoryId).name)\n"
                content += "\(CurrencyFormatter.formatFull(goal.currentAmount, currency: dataManager.user.currency)) / \(CurrencyFormatter.formatFull(goal.targetAmount, currency: dataManager.user.currency)) — Due \(DateFormatter.exportDate.string(from: goal.deadline)) — \(goal.isCompleted ? "Completed" : "In progress")\n"
            }
            content += "\n"
        }
        if dataTypes.contains(.monthlySalaries) || dataTypes.contains(.all) {
            content += "MONTHLY SALARIES\n"
            for salary in dataManager.monthlySalaries.sorted(by: { ($0.year, $0.month) > ($1.year, $1.month) }) {
                content += "\(salary.year)-\(String(format: "%02d", salary.month)) — \(CurrencyFormatter.formatFull(salary.amount, currency: salary.currency))\n"
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cenzio_Export_\(UUID().uuidString).pdf")
        do {
            try Self.pdfData(content: content).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Core Text flows long reports across pages without truncating long titles.
    static func pdfData(content: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let textBounds = page.insetBy(dx: 36, dy: 40)
        let attributed = NSAttributedString(string: content, attributes: [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.black
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            var offset = 0
            repeat {
                context.beginPage()
                let graphics = context.cgContext
                graphics.saveGState()
                graphics.translateBy(x: 0, y: page.height)
                graphics.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: textBounds, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                CTFrameDraw(frame, graphics)
                graphics.restoreGState()
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { break }
                offset += visible.length
            } while offset < attributed.length
        }
    }
    
    private func exportExpensesToText(dataManager: DataManager, dateRange: DateInterval?) -> String {
        var text = "EXPENSES\n"
        text += "--------\n"
        
        let filteredExpenses = filterExpensesByDate(dataManager.expenses, dateRange: dateRange)
        
        for expense in filteredExpenses.sorted(by: { $0.date > $1.date }) {
            let dateString = DateFormatter.exportDate.string(from: expense.date)
            let amount = CurrencyFormatter.formatFull(expense.amount, currency: dataManager.user.currency)
            let categoryName = dataManager.resolveCategory(id: expense.categoryId).name
            text += "\(dateString) - \(expense.title) - \(amount) - \(categoryName)\n"
        }
        
        return text
    }
    
    private func exportRecurringExpensesToText(dataManager: DataManager) -> String {
        var text = "RECURRING EXPENSES\n"
        text += "------------------\n"
        
        for recurring in dataManager.recurringExpenses {
            let amount = CurrencyFormatter.formatFull(recurring.amount, currency: dataManager.user.currency)
            let status = recurring.isActive ? "Active" : "Inactive"
            text += "\(recurring.title) - \(amount) - \(dataManager.resolveCategory(id: recurring.categoryId).name) - \(recurring.recurrenceType.rawValue) - \(status)\n"
            text += "Start: \(DateFormatter.exportDate.string(from: recurring.startDate)); End: \(recurring.endDate.map { DateFormatter.exportDate.string(from: $0) } ?? "None"); Last processed: \(recurring.lastProcessedDate.map { DateFormatter.exportDate.string(from: $0) } ?? "Never")\n"
        }
        
        return text
    }
    
    // MARK: - Helper Methods
    
    private func filterExpensesByDate(_ expenses: [Expense], dateRange: DateInterval?) -> [Expense] {
        guard let dateRange = dateRange else { return expenses }
        
        return expenses.filter { expense in
            expense.date >= dateRange.start && expense.date <= dateRange.end
        }
    }
    
    private func saveToFile(content: String, fileName: String, extension: String) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let timestamp = DateFormatter.fileTimestamp.string(from: Date())
        let fullFileName = "\(fileName)_\(timestamp)_\(UUID().uuidString).\(`extension`)"
        let fileURL = documentsPath.appendingPathComponent(fullFileName)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
    
    private func escapeCSVField(_ field: String) -> String {
        ExpenseCSVDocument.escape(field)
    }
    
    // MARK: - Dictionary Converters
    
    private func expenseToDict(_ expense: Expense, currency: Currency, dataManager: DataManager) -> [String: Any] {
        return [
            "id": expense.id.uuidString,
            "title": expense.title,
            "amount": expense.amount,
            "category": dataManager.resolveCategory(id: expense.categoryId).name,
            "date": DateFormatter.exportDate.string(from: expense.date),
            "currency": currency.rawValue
        ]
    }
    
    private func recurringExpenseToDict(_ recurring: RecurringExpense, dataManager: DataManager) -> [String: Any] {
        var dict: [String: Any] = [
            "id": recurring.id.uuidString,
            "title": recurring.title,
            "amount": recurring.amount,
            "category": dataManager.resolveCategory(id: recurring.categoryId).name,
            "recurrenceType": recurring.recurrenceType.rawValue,
            "startDate": DateFormatter.exportDate.string(from: recurring.startDate),
            "isActive": recurring.isActive
        ]
        
        if let endDate = recurring.endDate {
            dict["endDate"] = DateFormatter.exportDate.string(from: endDate)
        }
        
        if let lastProcessed = recurring.lastProcessedDate {
            dict["lastProcessedDate"] = DateFormatter.exportDate.string(from: lastProcessed)
        }
        
        return dict
    }
    
    private func budgetToDict(_ budget: CategoryBudget, dataManager: DataManager) -> [String: Any] {
        return [
            "category": dataManager.resolveCategory(id: budget.categoryId).name,
            "amount": budget.amount,
            "isEnabled": budget.isEnabled
        ]
    }
    
    private func spendingGoalToDict(_ goal: SpendingGoal, dataManager: DataManager) -> [String: Any] {
        return [
            "id": goal.id.uuidString,
            "title": goal.title,
            "targetAmount": goal.targetAmount,
            "currentAmount": goal.currentAmount,
            "deadline": DateFormatter.exportDate.string(from: goal.deadline),
            "category": dataManager.resolveCategory(id: goal.categoryId).name,
            "isCompleted": goal.isCompleted
        ]
    }
    
    private func monthlySalaryToDict(_ salary: MonthlySalary) -> [String: Any] {
        return [
            "year": salary.year,
            "month": salary.month,
            "amount": salary.amount,
            "currency": salary.currency.rawValue
        ]
    }
}

// MARK: - DateFormatter Extensions
extension DateFormatter {
    static let exportDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    
    static let exportDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
    
    static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}
