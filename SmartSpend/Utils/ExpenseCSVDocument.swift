import Foundation

/// Reads CSV records before interpreting rows, so quoted newlines stay in one field.
enum ExpenseCSVDocument {
    struct Document {
        let headers: [String]
        let rows: [[String]]
    }

    static func parse(_ content: String) throws -> Document {
        let text = content.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let firstHeader = text.components(separatedBy: "\n").first {
            $0.contains(",") || $0.contains(";")
        } ?? ""
        let separator: Character = firstHeader.contains(";") && !firstHeader.contains(",") ? ";" : ","
        let records = try records(in: text, separator: separator)
            .filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard !records.isEmpty else { throw CSVError.empty }

        let sectionNames: Set<String> = ["EXPENSES", "RECURRING EXPENSES", "BUDGETS", "SPENDING GOALS", "MONTHLY SALARIES"]
        var start = 0
        if records[0].count == 1, sectionNames.contains(records[0][0].uppercased()) {
            guard let expenseSection = records.firstIndex(where: { $0.count == 1 && $0[0].uppercased() == "EXPENSES" }),
                  expenseSection + 1 < records.count else { throw CSVError.noExpenses }
            start = expenseSection + 1
        }
        let headers = records[start].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard headers.contains(where: { let value = $0.lowercased(); return value.contains("amount") || value.contains("price") || value.contains("cost") }) else {
            throw CSVError.invalidHeader
        }
        let remaining = records.dropFirst(start + 1)
        let rows = Array(remaining.prefix { !($0.count == 1 && sectionNames.contains($0[0].uppercased())) })
        return Document(headers: headers, rows: rows)
    }

    static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func records(in text: String, separator: Character) throws -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else if quoted {
                    quoted = false
                } else if field.isEmpty {
                    quoted = true
                } else {
                    throw CSVError.invalidQuotes
                }
            } else if character == separator && !quoted {
                row.append(field)
                field = ""
            } else if character == "\n" && !quoted {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index += 1
        }
        guard !quoted else { throw CSVError.invalidQuotes }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    enum CSVError: LocalizedError {
        case empty, noExpenses, invalidHeader, invalidQuotes
        var errorDescription: String? {
            switch self {
            case .empty: return "CSV file is empty."
            case .noExpenses: return "This export does not contain an Expenses section."
            case .invalidHeader: return "The CSV must include an amount, price, or cost column."
            case .invalidQuotes: return "The CSV contains invalid or unclosed quotation marks."
            }
        }
    }
}
