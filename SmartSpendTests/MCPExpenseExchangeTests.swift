import Foundation
import Testing
@testable import SmartSpend

@Suite("MCP reviewed expense exchange")
struct MCPExpenseExchangeTests {
    private let ledger = "00000000-0000-0000-0000-000000000010"
    private let category = "00000000-0000-0000-0000-000000000002"
    private let expenseId = "00000000-0000-0000-0000-000000000001"

    private func record(title: String = "Кофе / ☕", amount: String = "12.5") -> MCPExpenseRecord {
        MCPExpenseRecord(id: expenseId, title: title, amount: amount, categoryId: category,
                         date: "2026-10-20T12:34:56.789Z")
    }

    private func operation(_ kind: MCPExpenseOperation.Kind, before: MCPExpenseRecord? = nil,
                           after: MCPExpenseRecord? = nil, id: String = UUID().uuidString.lowercased()) -> MCPExpenseOperation {
        MCPExpenseOperation(id: id, kind: kind, expenseId: expenseId,
                            baseFingerprint: before?.fingerprint, expense: after)
    }

    private func document(_ operations: [MCPExpenseOperation]) -> MCPExpenseOperationsDocument {
        MCPExpenseOperationsDocument(schemaVersion: 1, ledgerId: ledger, currency: "UZS", operations: operations)
    }

    private func plan(_ operations: [MCPExpenseOperation], active: [MCPExpenseRecord] = [],
                      archived: [MCPExpenseRecord] = [], applied: [String: String] = [:]) throws -> MCPExpenseExchangePlan {
        try MCPExpenseExchange.plan(document: document(operations), ledgerId: ledger, currency: "UZS",
                                    categoryIds: [category], expenses: active,
                                    archivedExpenses: archived, appliedOperations: applied)
    }

    @Test("Swift and Python share the same canonical UTF8 fingerprint")
    func fingerprintGolden() {
        #expect(record().fingerprint == "17411ead3adf7a874dc472b2316bd124c1a16454e141fd10c8c3480513fe28e7")
    }

    @Test("Sequential create update archive restore preserves the same expense ID")
    func sequentialRoundTrip() throws {
        let original = record()
        let updated = record(title: "Taxi", amount: "15800")
        let result = try plan([
            operation(.create, after: original),
            operation(.update, before: original, after: updated),
            operation(.archive, before: updated),
            operation(.restore, before: updated, after: updated)
        ])
        #expect(result.expenses == [updated])
        #expect(result.archivedExpenses.isEmpty)
        #expect(result.appliedOperations.count == 4)
    }

    @Test("Reimport skips identical operation IDs but rejects tampered payloads")
    func replayAndTampering() throws {
        let create = operation(.create, after: record())
        let first = try plan([create])
        let second = try plan([create], active: first.expenses, applied: first.appliedOperations)
        #expect(second.changes.isEmpty)
        #expect(second.skippedCount == 1)
        let tampered = operation(.create, after: record(amount: "50"), id: create.id)
        #expect(throws: MCPExpenseExchangeError.self) {
            try plan([tampered], active: first.expenses, applied: first.appliedOperations)
        }
    }

    @Test("A stale update or repeated record ID never replaces current financial data")
    func conflicts() throws {
        #expect(throws: MCPExpenseExchangeError.self) {
            try plan([operation(.update, before: record(), after: record(amount: "5"))],
                     active: [record(amount: "20")])
        }
        #expect(throws: MCPExpenseExchangeError.self) {
            try plan([operation(.create, after: record())], archived: [record()])
        }
        #expect(throws: MCPExpenseExchangeError.self) {
            try plan([], active: [record(), record()])
        }
    }

    @Test("Invalid money strings fail before any mutation", arguments: ["0", "-1", "NaN", "Infinity", "1e3", "15,800", "01", "1.00", "0.0000001", "1000000000000"])
    func moneyValidation(amount: String) throws {
        #expect(throws: MCPExpenseExchangeError.self) {
            try record(amount: amount).validated(categoryIds: [category])
        }
    }

    @Test("Other ledger or currency files cannot be imported")
    func ledgerBoundary() throws {
        #expect(throws: MCPExpenseExchangeError.self) {
            try MCPExpenseExchange.plan(document: document([]), ledgerId: UUID().uuidString.lowercased(),
                                        currency: "UZS", categoryIds: [], expenses: [], archivedExpenses: [], appliedOperations: [:])
        }
        #expect(throws: MCPExpenseExchangeError.self) {
            try MCPExpenseExchange.plan(document: document([]), ledgerId: ledger,
                                        currency: "USD", categoryIds: [], expenses: [], archivedExpenses: [], appliedOperations: [:])
        }
    }

    @Test("Confirmed app changes persist, replay is harmless, and Clear All rotates the ledger")
    @MainActor
    func persistence() throws {
        let suite = "SmartSpendTests.MCP.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        manager.updateCurrency(.uzs)
        manager.userCategories = [UserCategory(id: try #require(UUID(uuidString: category)), name: "Food")]
        manager.addExpensesBatch([])
        let snapshot = try JSONDecoder().decode(MCPExchangeSnapshot.self, from: manager.exportMCPSnapshot())
        let changes = MCPExpenseOperationsDocument(schemaVersion: 1, ledgerId: snapshot.ledgerId,
            currency: "UZS", operations: [operation(.create, after: record(amount: "15800"))])
        #expect(try manager.previewMCPChanges(changes).changes.count == 1)
        #expect(manager.expenses.isEmpty)
        #expect(try manager.applyMCPChanges(changes) == 1)

        let reopened = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(reopened.expenses.first?.amount == 15800)
        #expect(try reopened.applyMCPChanges(changes) == 0)
        let ack = try JSONDecoder().decode(MCPExchangeSnapshot.self, from: reopened.exportMCPSnapshot())
        #expect(ack.appliedOperationIds == changes.operations.map(\.id))
        reopened.clearAllData()
        reopened.userCategories = [UserCategory(id: try #require(UUID(uuidString: category)), name: "Food")]
        reopened.addExpensesBatch([])
        let cleared = try JSONDecoder().decode(MCPExchangeSnapshot.self, from: reopened.exportMCPSnapshot())
        #expect(cleared.ledgerId != snapshot.ledgerId)
        #expect(cleared.appliedOperationIds.isEmpty)
    }

    @Test("Interrupted confirmed batches recover their records and replay acknowledgments together")
    @MainActor
    func recoverCommit() throws {
        let suite = "SmartSpendTests.MCPRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var expense = Expense(title: "Recovered", amount: 35, categoryId: try #require(UUID(uuidString: category)))
        expense.id = try #require(UUID(uuidString: expenseId))
        let applied = [UUID().uuidString.lowercased(): "digest"]
        let commit = MCPExpenseCommit(ledgerId: ledger, expenses: [expense], archivedExpenses: [], appliedOperations: applied)
        defaults.set(try JSONEncoder().encode(commit), forKey: "mcpPendingCommit")
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(manager.expenses.first?.id == expense.id)
        #expect(defaults.dictionary(forKey: "mcpAppliedOperations") as? [String: String] == applied)
        #expect(defaults.data(forKey: "mcpPendingCommit") == nil)
    }

    @Test("A failed journal flush does not report success or replay over a newer local write")
    @MainActor
    func failedCommitCannotOverwriteLaterEdit() throws {
        let suite = "SmartSpendTests.MCPFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var flushCount = 0
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults),
                                  mcpStorageSync: { flushCount += 1; return flushCount == 1 })
        manager.updateCurrency(.uzs)
        manager.userCategories = [UserCategory(id: try #require(UUID(uuidString: category)), name: "Food")]
        manager.addExpensesBatch([])
        let snapshot = try JSONDecoder().decode(MCPExchangeSnapshot.self, from: manager.exportMCPSnapshot())
        let changes = MCPExpenseOperationsDocument(schemaVersion: 1, ledgerId: snapshot.ledgerId,
            currency: "UZS", operations: [operation(.create, after: record())])
        #expect(throws: MCPExpenseExchangeError.self) { try manager.applyMCPChanges(changes) }
        #expect(manager.expenses.isEmpty)
        manager.addExpensesBatch([Expense(title: "Later local edit", amount: 5,
                                          categoryId: try #require(UUID(uuidString: category)))])
        #expect(defaults.data(forKey: "mcpPendingCommit") == nil)
        let reopened = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(reopened.expenses.map(\.title) == ["Later local edit"])
    }

    @Test("The normal Deleted Expenses restore keeps identity and cannot duplicate a stale restore")
    @MainActor
    func normalRestoreIdentity() throws {
        let suite = "SmartSpendTests.MCPRestore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        let expense = Expense(title: "Stable ID", amount: 12.5, categoryId: UUID())
        manager.addExpensesBatch([expense])
        manager.moveToDeletedExpenses(expense)
        let archived = try #require(manager.deletedExpenses.first)
        manager.restoreExpense(archived)
        manager.restoreExpense(archived)
        #expect(manager.expenses.map(\.id) == [expense.id])
        #expect(manager.deletedExpenses.isEmpty)
    }
}
