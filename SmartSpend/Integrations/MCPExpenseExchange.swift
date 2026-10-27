import Foundation
import CryptoKit

/// A deliberately explicit, user-reviewed bridge. This is not background sync.
struct MCPExpenseRecord: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let amount: String
    let categoryId: String
    let date: String

    var fingerprint: String {
        var bytes = Data()
        for field in [id, title, amount, categoryId, date] {
            let encoded = Data(field.utf8)
            var length = UInt32(encoded.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(encoded)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validated(categoryIds: Set<String>) throws -> MCPExpenseRecord {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              UUID(uuidString: categoryId)?.uuidString.lowercased() == categoryId,
              categoryIds.contains(categoryId),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.unicodeScalars.count <= 300, !title.contains("\0"),
              let number = Decimal(string: amount, locale: MCPExpenseExchange.locale),
              number > 0, number < 1_000_000_000_000,
              amount.range(of: #"^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              amount.replacingOccurrences(of: ".", with: "").drop(while: { $0 == "0" }).count <= 15,
              MCPExpenseExchange.canonicalAmount(number) == amount,
              let parsedDate = MCPExpenseExchange.dateFormatter.date(from: date),
              MCPExpenseExchange.dateFormatter.string(from: parsedDate) == date,
              ("1900-01-01T00:00:00.000Z"..."2200-12-31T23:59:59.999Z").contains(date) else {
            throw MCPExpenseExchangeError.invalidRecord
        }
        return self
    }
}

struct MCPExchangeCategory: Codable {
    let id: String
    let name: String
    let iconSystemName: String
    let colorName: String
}

struct MCPExchangeSnapshot: Codable {
    let schemaVersion: Int
    let ledgerId: String
    let currency: String
    let timeZone: String
    let categories: [MCPExchangeCategory]
    let expenses: [MCPExpenseRecord]
    let archivedExpenses: [MCPExpenseRecord]
    let appliedOperationIds: [String]
}

struct MCPExpenseOperation: Codable, Identifiable {
    enum Kind: String, Codable { case create, update, archive, restore }
    let id: String
    let kind: Kind
    let expenseId: String
    let baseFingerprint: String?
    let expense: MCPExpenseRecord?

    var payloadDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All stored values are JSON primitives, so encoding cannot fail.
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MCPExpenseOperationsDocument: Codable {
    let schemaVersion: Int
    let ledgerId: String
    let currency: String
    let operations: [MCPExpenseOperation]
}

struct MCPExpenseExchangePlan {
    let expenses: [MCPExpenseRecord]
    let archivedExpenses: [MCPExpenseRecord]
    let appliedOperations: [String: String]
    let changes: [MCPExpenseOperation]
    let skippedCount: Int
}

struct MCPExpenseCommit: Codable {
    let ledgerId: String
    let expenses: [Expense]
    let archivedExpenses: [ArchivedExpense]
    let appliedOperations: [String: String]
}

enum MCPExpenseExchange {
    static let locale = Locale(identifier: "en_US_POSIX")
    static let maximumFileBytes = 5 * 1_024 * 1_024

    static var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func canonicalAmount(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, locale)
    }

    static func decodeOperations(_ data: Data) throws -> MCPExpenseOperationsDocument {
        guard data.count <= maximumFileBytes else { throw MCPExpenseExchangeError.fileTooLarge }
        return try JSONDecoder().decode(MCPExpenseOperationsDocument.self, from: data)
    }

    /// Validate the full batch against current state before publishing any changes.
    static func plan(
        document: MCPExpenseOperationsDocument,
        ledgerId: String,
        currency: String,
        categoryIds: Set<String>,
        expenses: [MCPExpenseRecord],
        archivedExpenses: [MCPExpenseRecord],
        appliedOperations: [String: String]
    ) throws -> MCPExpenseExchangePlan {
        guard document.schemaVersion == 1,
              document.ledgerId == ledgerId,
              document.currency == currency,
              document.operations.count <= 1_000 else {
            throw MCPExpenseExchangeError.wrongLedger
        }
        guard Set(expenses.map(\.id)).count == expenses.count,
              Set(archivedExpenses.map(\.id)).count == archivedExpenses.count,
              Set(expenses.map(\.id)).isDisjoint(with: Set(archivedExpenses.map(\.id))) else {
            throw MCPExpenseExchangeError.duplicateId
        }
        var active = Dictionary(uniqueKeysWithValues: expenses.map { ($0.id, $0) })
        var archived = Dictionary(uniqueKeysWithValues: archivedExpenses.map { ($0.id, $0) })
        var applied = appliedOperations
        var changes: [MCPExpenseOperation] = []
        var seen = Set<String>()
        var skipped = 0

        for operation in document.operations {
            guard UUID(uuidString: operation.id)?.uuidString.lowercased() == operation.id,
                  UUID(uuidString: operation.expenseId)?.uuidString.lowercased() == operation.expenseId,
                  seen.insert(operation.id).inserted else {
                throw MCPExpenseExchangeError.duplicateId
            }
            if let previousDigest = applied[operation.id] {
                guard previousDigest == operation.payloadDigest else { throw MCPExpenseExchangeError.reusedOperation }
                skipped += 1
                continue
            }
            let incoming = try operation.expense?.validated(categoryIds: categoryIds)
            guard incoming == nil || incoming?.id == operation.expenseId else {
                throw MCPExpenseExchangeError.invalidRecord
            }

            switch operation.kind {
            case .create:
                guard operation.baseFingerprint == nil,
                      active[operation.expenseId] == nil, archived[operation.expenseId] == nil,
                      let incoming else { throw MCPExpenseExchangeError.conflict }
                active[operation.expenseId] = incoming
            case .update:
                guard let current = active[operation.expenseId],
                      operation.baseFingerprint == current.fingerprint,
                      let incoming else { throw MCPExpenseExchangeError.conflict }
                active[operation.expenseId] = incoming
            case .archive:
                guard let current = active[operation.expenseId],
                      operation.baseFingerprint == current.fingerprint,
                      incoming == nil || incoming == current else { throw MCPExpenseExchangeError.conflict }
                archived[operation.expenseId] = current
                active.removeValue(forKey: operation.expenseId)
            case .restore:
                guard let current = archived[operation.expenseId],
                      active[operation.expenseId] == nil,
                      operation.baseFingerprint == current.fingerprint,
                      let incoming else { throw MCPExpenseExchangeError.conflict }
                active[operation.expenseId] = incoming
                archived.removeValue(forKey: operation.expenseId)
            }
            applied[operation.id] = operation.payloadDigest
            changes.append(operation)
        }
        return MCPExpenseExchangePlan(
            expenses: active.values.sorted { $0.id < $1.id },
            archivedExpenses: archived.values.sorted { $0.id < $1.id },
            appliedOperations: applied,
            changes: changes,
            skippedCount: skipped
        )
    }
}

enum MCPExpenseExchangeError: LocalizedError {
    case invalidRecord, wrongLedger, duplicateId, conflict, reusedOperation, fileTooLarge, storageFailure, missingCategory

    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "An AI change has an invalid amount, date, title or category. No changes were applied."
        case .wrongLedger: return "This file belongs to another ledger, currency or unsupported format. Export a fresh snapshot from this app."
        case .duplicateId: return "Duplicate or invalid record IDs were found. No changes were applied."
        case .conflict: return "An expense changed after the AI snapshot, or an ID is already in use. Export a fresh snapshot and review the conflict."
        case .reusedOperation: return "A previously applied operation ID was reused with different contents. No changes were applied."
        case .fileTooLarge: return "Choose an AI changes file smaller than 5 MB."
        case .storageFailure: return "Cenzio could not safely save the AI changes. Try again."
        case .missingCategory: return "Every expense needs a valid category before MCP export. For a deleted expense, restore it and choose a current category first. Category names must be nonblank and at most 100 characters."
        }
    }
}
