import Foundation
import SwiftUI

class DataImporter: ObservableObject {
    static let shared = DataImporter()
    private let fallbackCategoryName = "Other"
    
    private init() {}
    
    enum ImportFormat: String, CaseIterable {
        case csv = "CSV"
        
        var fileExtension: String {
            switch self {
            case .csv:
                return "csv"
            }
        }
        
        var icon: String {
            switch self {
            case .csv:
                return "tablecells"
            }
        }
        
        var localizedName: String {
            switch self {
            case .csv:
                return "CSV"
            }
        }
    }
    
    enum ImportResult {
        case success(importedCount: Int, skippedCount: Int, errors: [String])
        case failure(error: String)
    }
    
    // MARK: - CSV Import
    
    func importFromCSV(fileURL: URL, dataManager: DataManager) -> ImportResult {
        // Start accessing the security-scoped resource
        let accessedResource = fileURL.startAccessingSecurityScopedResource()
        
        defer {
            if accessedResource { fileURL.stopAccessingSecurityScopedResource() }
        }
        
        do {
            // Try multiple encodings to handle different CSV formats
            let encodings: [String.Encoding] = [.utf8, .utf16, .ascii, .isoLatin1]
            var csvContent: String?
            
            for encoding in encodings {
                if let content = try? String(contentsOf: fileURL, encoding: encoding) {
                    csvContent = content
                    break
                }
            }
            
            guard let content = csvContent else {
                return .failure(error: "Failed to read file - unsupported encoding")
            }
            
            // Clean up the content - remove BOM and normalize line endings
            let cleanedContent = content
                .replacingOccurrences(of: "\u{FEFF}", with: "") // Remove BOM
                .replacingOccurrences(of: "\r\n", with: "\n") // Normalize line endings
                .replacingOccurrences(of: "\r", with: "\n")
            
            let document = try ExpenseCSVDocument.parse(cleanedContent)
            let header = document.headers
            
            guard !header.isEmpty else {
                return .failure(error: "Invalid CSV header")
            }
            
            let dataRows = document.rows
            // Currency is ledger-wide. Validate the entire file before creating categories
            // or expenses so an incompatible import cannot partially change the store.
            let importedCurrency = try currencyFromCSV(header: header, rows: dataRows)
            let validateLedgerCurrency = {
                if let importedCurrency, importedCurrency != dataManager.user.currency,
                   !self.isFinancialStoreEmpty(dataManager) {
                    throw ImportError.invalidData("This CSV uses \(importedCurrency.rawValue), but your existing data uses \(dataManager.user.currency.rawValue). Import a file in your current currency; currency conversion is not supported.")
                }
            }
            if Thread.isMainThread { try validateLedgerCurrency() }
            else { try DispatchQueue.main.sync(execute: validateLedgerCurrency) }
            
            // Detect CSV format (SmartSpend or custom)
            let format = detectCSVFormat(header: header)
            print("📝 Detected Format: \(format)")
            
            var importedCount = 0
            var skippedCount = 0
            var errors: [String] = []
            var expensesToAdd: [Expense] = []
            var foundCategories: Set<String> = []
            
            // First pass: collect all categories from the CSV
            print("🔄 First Pass: Collecting categories...")
            for row in dataRows {
                let parsedColumns = row
                if let categoryString = extractCategoryString(parsedColumns, header: header, format: format) {
                    let normalized = categoryString.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Safety check: Don't treat dates as categories
                    // This prevents the error where a date column is misidentified as a category
                    if !normalized.isEmpty && parseDate(normalized) == nil {
                        foundCategories.insert(normalized)
                    } else {
                        foundCategories.insert(fallbackCategoryName)
                    }
                } else {
                    foundCategories.insert(fallbackCategoryName)
                }
            }
            print("📝 Found \(foundCategories.count) unique categories: \(foundCategories)")
            
            // Sync with DataManager to create categories and get IDs
            // We need a map of category name -> UserCategory ID
            var categoryMap: [String: UUID] = [:]
            let syncCategories = {
                print("🔄 Syncing categories with DataManager...")
                for categoryName in foundCategories {
                    let normalized = categoryName.lowercased()
                    
                    // Always treat as UserCategory now.
                    // Check if UserCategory already exists
                    if let existingCategory = dataManager.userCategories.first(where: { $0.name.lowercased() == normalized }) {
                        categoryMap[normalized] = existingCategory.id
                        print("   Mapped '\(categoryName)' to existing user category")
                    } else {
                        // Create new UserCategory
                        let newUserCategory = UserCategory.imported(name: categoryName)
                        dataManager.addUserCategory(newUserCategory)
                        categoryMap[normalized] = newUserCategory.id
                        print("   Created new user category for '\(categoryName)'")
                    }
                }
            }
            if Thread.isMainThread { syncCategories() }
            else { DispatchQueue.main.sync(execute: syncCategories) }
            
            // Second pass: parse and create expenses
            print("🔄 Second Pass: Parsing expenses...")
            for (index, row) in dataRows.enumerated() {
                do {
                    let parsedColumns = row
                    let expense = try parseExpenseFromRow(parsedColumns, header: header, format: format, categoryMap: categoryMap)
                    expensesToAdd.append(expense)
                    importedCount += 1
                } catch {
                    let parsedColumns = row
                    let rowPreview = parsedColumns.prefix(3).joined(separator: ", ")
                    let errorMessage = "Row \(index + 2) [\(rowPreview)...]: \(error.localizedDescription)"
                    errors.append(errorMessage)
                    skippedCount += 1
                    
                    // Only print first 5 errors for debugging
                    if skippedCount <= 5 {
                        print("❌ Import Error on row \(index + 2): \(error.localizedDescription)")
                    }
                }
            }
            
            // Add all expenses on main thread in a single batch
            let addExpenses = {
                print("🔄 Adding \(expensesToAdd.count) expenses to DataManager...")
                if !expensesToAdd.isEmpty, let importedCurrency,
                   self.isFinancialStoreEmpty(dataManager) {
                    dataManager.updateCurrency(importedCurrency)
                }
                dataManager.addExpensesBatch(expensesToAdd)
            }
            if Thread.isMainThread { addExpenses() }
            else { DispatchQueue.main.sync(execute: addExpenses) }
            
            print("✅ Import completed: \(importedCount) imported, \(skippedCount) skipped")
            
            if skippedCount > 5 {
                print("   (Showing only first 5 errors in console)")
            }
            
            return .success(importedCount: importedCount, skippedCount: skippedCount, errors: errors)
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }
    
    // MARK: - Preview Import

    private func isFinancialStoreEmpty(_ manager: DataManager) -> Bool {
        manager.expenses.isEmpty && manager.recurringExpenses.isEmpty &&
        manager.categoryBudgets.isEmpty && manager.spendingGoals.isEmpty &&
        manager.monthlySalaries.isEmpty && manager.deletedExpenses.isEmpty
    }

    private func currencyFromCSV(header: [String], rows: [[String]]) throws -> Currency? {
        guard let index = header.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "currency"
        }) else { return nil } // Legacy CSV amounts use the selected ledger currency.
        var selected: Currency?
        for (rowIndex, row) in rows.enumerated() {
            let code = index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() : ""
            guard let currency = Currency(rawValue: code) else {
                throw ImportError.invalidData("Row \(rowIndex + 2) has an unsupported or missing currency: '\(code)'. Use a supported currency code such as USD or UZS.")
            }
            if let selected, selected != currency {
                throw ImportError.invalidData("This CSV contains mixed currencies. Import one currency at a time; currency conversion is not supported.")
            }
            selected = currency
        }
        return selected
    }

    /// Parses without touching persisted state, for preview tools and round-trip verification.
    func expensesFromCSV(_ content: String, categoryMap: [String: UUID]) throws -> [Expense] {
        let document = try ExpenseCSVDocument.parse(content)
        let format = detectCSVFormat(header: document.headers)
        return try document.rows.map {
            try parseExpenseFromRow($0, header: document.headers, format: format, categoryMap: categoryMap)
        }
    }
    
    func previewCSVImport(fileURL: URL) -> (headers: [String], sampleRows: [[String]], totalRows: Int)? {
        // Start accessing the security-scoped resource
        let accessedResource = fileURL.startAccessingSecurityScopedResource()
        
        defer {
            if accessedResource { fileURL.stopAccessingSecurityScopedResource() }
        }
        
        // Try multiple encodings to handle different CSV formats
        let encodings: [String.Encoding] = [.utf8, .utf16, .ascii, .isoLatin1]
        var csvContent: String?
        
        for encoding in encodings {
            if let content = try? String(contentsOf: fileURL, encoding: encoding) {
                csvContent = content
                break
            }
        }
        
        guard let content = csvContent else {
            return nil
        }
        
        // Clean up the content - remove BOM and normalize line endings
        let cleanedContent = content
            .replacingOccurrences(of: "\u{FEFF}", with: "") // Remove BOM
            .replacingOccurrences(of: "\r\n", with: "\n") // Normalize line endings
            .replacingOccurrences(of: "\r", with: "\n")
        
        guard let document = try? ExpenseCSVDocument.parse(cleanedContent) else { return nil }
        return (headers: document.headers, sampleRows: Array(document.rows.prefix(5)), totalRows: document.rows.count)
    }
    
    // MARK: - Format Detection
    
    private enum CSVFormat {
        case custom
        case smartSpend
    }
    
    private func detectCSVFormat(header: [String]) -> CSVFormat {
        let normalizedHeader = header.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        
        // SmartSpend format detection
        if normalizedHeader.contains("date") && normalizedHeader.contains("title") && normalizedHeader.contains("amount") && normalizedHeader.contains("category") {
            return .smartSpend
        }
        
        return .custom
    }
    
    
    // MARK: - Helper Methods
    
    private func parseExpenseFromRow(_ columns: [String], header: [String], format: CSVFormat, categoryMap: [String: UUID]) throws -> Expense {
        switch format {
        case .smartSpend:
            return try parseSmartSpendRow(columns: columns, header: header, categoryMap: categoryMap)
        case .custom:
            return try parseCustomRow(columns: columns, header: header, categoryMap: categoryMap)
        }
    }
    
    
    private func parseSmartSpendRow(columns: [String], header: [String], categoryMap: [String: UUID]) throws -> Expense {
        guard let dateIndex = header.firstIndex(where: { $0.lowercased() == "date" }),
              let titleIndex = header.firstIndex(where: { $0.lowercased() == "title" }),
              let amountIndex = header.firstIndex(where: { $0.lowercased() == "amount" }),
              let categoryIndex = header.firstIndex(where: { $0.lowercased() == "category" }) else {
            throw ImportError.missingColumns
        }
        
        // Check if columns array has enough elements
        guard columns.count > max(dateIndex, titleIndex, amountIndex, categoryIndex) else {
            throw ImportError.invalidData("Row has insufficient columns (expected \(header.count), got \(columns.count))")
        }
        
        let title = columns[titleIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let amountString = columns[amountIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryString = columns[categoryIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let dateString = columns[dateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let amount = parseAmount(amountString) else {
            throw ImportError.invalidData("Invalid amount: '\(amountString)'")
        }
        
        guard let date = parseDate(dateString) else {
            throw ImportError.invalidData("Invalid date: '\(dateString)'")
        }
        
        // Parse category and find/assign categoryId
        let categoryId = parseCategoryWithMap(categoryString, categoryMap: categoryMap)
        
        // Title is allowed to be empty now - will be flagged as problem expense
        return Expense(title: title, amount: amount, categoryId: categoryId, date: date)
    }
    
    private func parseCustomRow(columns: [String], header: [String], categoryMap: [String: UUID]) throws -> Expense {
        // Try to intelligently map columns
        var title = ""
        var amount: Double = 0
        var date = Date()
        var categoryString = ""
        
        // First, try to match columns using header names
        var foundTitle = false
        var foundAmount = false
        
        for (index, columnName) in header.enumerated() {
            guard index < columns.count else { break }
            
            let value = columns[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerColName = columnName.lowercased()
            
            // Try to match column names
            if lowerColName.contains("title") || lowerColName.contains("name") || lowerColName.contains("description") {
                title = value
                foundTitle = true
            } else if lowerColName.contains("amount") || lowerColName.contains("price") || lowerColName.contains("cost") {
                if let parsedAmount = parseAmount(value) {
                    amount = parsedAmount
                    foundAmount = true
                }
            } else if lowerColName.contains("date") {
                if let parsedDate = parseDate(value) {
                    date = parsedDate
                }
            } else if lowerColName.contains("category") || lowerColName.contains("type") {
                categoryString = value
            }
        }
        
        // If we couldn't find columns by header name, try positional parsing
        // Common formats: [title, amount, category, date] or [title, amount, date, category]
        if !foundTitle || !foundAmount {
            if columns.count >= 4 {
                // Try to parse as [title, amount, category, date]
                let col0 = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let col1 = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let col2 = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let col3 = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Check if col1 looks like an amount
                if let parsedAmount = parseAmount(col1), parsedAmount > 0 {
                    title = col0
                    amount = parsedAmount
                    
                    // Try to determine if col2 is category or date
                    if parseDate(col2) != nil {
                        // col2 is date, col3 might be category
                        date = parseDate(col2) ?? Date()
                        categoryString = col3
                    } else {
                        // col2 is probably category, col3 should be date
                        categoryString = col2
                        date = parseDate(col3) ?? Date()
                    }
                }
            }
        }
        
        guard amount > 0 else {
            throw ImportError.invalidData("Amount must be greater than zero")
        }
        
        // Parse category and find/assign categoryId
        let categoryId = parseCategoryWithMap(categoryString, categoryMap: categoryMap)
        
        // Title is allowed to be empty now - will be flagged as problem expense
        return Expense(title: title, amount: amount, categoryId: categoryId, date: date)
    }
    
    enum ImportError: Error, LocalizedError {
        case missingColumns
        case invalidData(String)
        
        var errorDescription: String? {
            switch self {
            case .missingColumns:
                return "Required columns are missing from the CSV file"
            case .invalidData(let message):
                return message
            }
        }
    }
    
    private func parseAmount(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle empty values
        guard !trimmed.isEmpty else {
            return nil
        }
        
        // Remove currency symbols, commas, spaces, and keep only numbers, dots, and minus
        var cleaned = trimmed
        
        // Handle common currency symbols
        cleaned = cleaned.replacingOccurrences(of: "$", with: "")
        cleaned = cleaned.replacingOccurrences(of: "€", with: "")
        cleaned = cleaned.replacingOccurrences(of: "£", with: "")
        cleaned = cleaned.replacingOccurrences(of: "¥", with: "")
        cleaned = cleaned.replacingOccurrences(of: "₽", with: "")
        cleaned = cleaned.replacingOccurrences(of: "₹", with: "")
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle parentheses for negative numbers (accounting format)
        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            cleaned = "-" + cleaned.dropFirst().dropLast()
        }
        
        // Keep only numbers, dots, and minus
        cleaned = cleaned.replacingOccurrences(of: "[^0-9.-]", with: "", options: .regularExpression)
        
        // Handle empty after cleaning
        guard !cleaned.isEmpty else {
            return nil
        }
        
        // Try to parse as double
        guard let amount = Double(cleaned) else {
            return nil
        }
        
        // Take absolute value (amounts are always positive in expenses)
        let positiveAmount = abs(amount)
        
        // Validate amount is not zero
        guard positiveAmount.isFinite, positiveAmount > 0 else {
            return nil
        }
        
        return positiveAmount
    }
    
    private func parseDate(_ value: String) -> Date? {
        let cleanedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // If empty, use today's date as fallback
        if cleanedValue.isEmpty {
            return nil
        }
        
        // Try numeric timestamp first (Unix timestamp in seconds or milliseconds)
        if let timestamp = Double(cleanedValue) {
            // Very rough check to ensure it's not just a small number like "1" or "10"
            if timestamp > 1_000_000_000 {
                if timestamp > 1_000_000_000_000 {
                    // Milliseconds
                    return Date(timeIntervalSince1970: timestamp / 1000)
                } else {
                    // Seconds
                    return Date(timeIntervalSince1970: timestamp)
                }
            }
        }
        
        for formatter in DataImporter.cachedDateFormatters {
            if let date = formatter.date(from: cleanedValue) {
                return date
            }
        }

        for formatter in DataImporter.cachedLocaleDateFormatters {
            if let date = formatter.date(from: cleanedValue) {
                return date
            }
        }

        if let date = DataImporter.cachedISOFormatter.date(from: cleanedValue) {
            return date
        }
        
        return nil
    }
    
    private static let cachedDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "M/d/yyyy", "d/M/yyyy",
            "yyyy/MM/dd", "dd-MM-yyyy", "dd.MM.yyyy", "MM-dd-yyyy", "M-d-yyyy",
            "d-M-yyyy", "yyyy.MM.dd",
            "yyyy-MM-dd HH:mm:ss", "MM/dd/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss",
            "M/d/yyyy HH:mm:ss", "yyyy-MM-dd HH:mm", "MM/dd/yyyy HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = format
            return f
        }
    }()

    private static let cachedLocaleDateFormatters: [DateFormatter] = {
        let formats = [
            "MMM dd, yyyy", "MMMM dd, yyyy", "dd MMM yyyy", "dd MMMM yyyy",
            "MMM dd yyyy", "MMMM dd yyyy", "dd-MMM-yyyy", "dd.MMM.yyyy",
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = format
            return f
        }
    }()

    private static let cachedISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func createDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
    
    // Extract category string from CSV row without parsing it
    private func extractCategoryString(_ columns: [String], header: [String], format: CSVFormat) -> String? {
        switch format {
        case .smartSpend:
            if let categoryIndex = header.firstIndex(where: { $0.lowercased() == "category" }),
               categoryIndex < columns.count {
                return columns[categoryIndex]
            }
        case .custom:
            if let categoryIndex = header.firstIndex(where: { $0.lowercased().contains("category") || $0.lowercased().contains("type") }),
               categoryIndex < columns.count {
                return columns[categoryIndex]
            }
        }
        return nil
    }
    
    private func parseCategoryWithMap(_ categoryString: String, categoryMap: [String: UUID]) -> UUID {
        let normalized = categoryString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if normalized.isEmpty {
            return fallbackCategoryId(from: categoryMap)
        }
        
        // Validation: If the category string parses as a valid date, it's likely a mapping error
        if parseDate(categoryString) != nil {
            print("⚠️ Warning: Category value '\(categoryString)' looks like a date. Ignoring to prevent miscategorization.")
            return fallbackCategoryId(from: categoryMap)
        }
        
        // Look up the UserCategory ID from the map
        if let id = categoryMap[normalized] {
            return id
        }
        
        print("⚠️ Warning: Category '\(categoryString)' (normalized: '\(normalized)') not found in map. Falling back to \(fallbackCategoryName).")
        return fallbackCategoryId(from: categoryMap)
    }

    private func fallbackCategoryId(from categoryMap: [String: UUID]) -> UUID {
        if let fallbackId = categoryMap[fallbackCategoryName.lowercased()] {
            return fallbackId
        }

        assertionFailure("Import fallback category was not created before parsing expenses.")
        return UUID()
    }
}
