import Foundation
import Testing
@testable import SmartSpend

@Suite("Incremental expense sync safety")
struct ExpenseSyncTests {
    let ledger = "00000000-0000-0000-0000-000000000001"
    let category = "00000000-0000-0000-0000-000000000002"
    let expenseID = "00000000-0000-0000-0000-000000000003"
    func expense(_ title: String = "Bus") -> MCPExpenseRecord {
        .init(id: expenseID, title: title, amount: "2500", categoryId: category, date: "2026-10-20T00:00:00.000Z")
    }
    func snapshot(_ active: [MCPExpenseRecord], archived: [MCPExpenseRecord] = []) -> MCPExchangeSnapshot {
        .init(schemaVersion: 1, ledgerId: ledger, currency: "UZS", timeZone: "Asia/Tashkent",
              categories: [.init(id: category, name: "Travel", iconSystemName: "bus", colorName: "blue")],
              expenses: active, archivedExpenses: archived, appliedOperationIds: [])
    }
    func state(_ baseline: [String: ExpenseSyncRecord] = [:]) -> ExpenseSyncState {
        .init(ledgerId: ledger, currency: "UZS", endpoint: "https://example.com", clientId: UUID().uuidString.lowercased(), cursor: 0, baseline: baseline, outbox: [], enabled: true)
    }
    func response(_ change: ExpenseSyncChange, conflicts: [ExpenseSyncConflict] = []) -> ExpenseSyncResponse {
        .init(schemaVersion: 1, ledgerId: ledger, currency: "UZS", changes: [change], nextSequence: change.sequence, hasMore: false, conflicts: conflicts, acknowledgedOperationIds: [change.operationId])
    }
    @Test("Secure endpoint accepts ordinary domains and rejects redirects/embedded credentials")
    func endpointValidation() throws {
        #expect(try ExpenseSyncAPI.server("https://sync.example.com").host == "sync.example.com")
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com/secret", "https://example.com?key=secret"] {
            #expect(throws: ExpenseSyncError.self) { try ExpenseSyncAPI.server(url) }
        }
    }
    @Test("Google consent URL stays on Google's authorization endpoint")
    func googleURLValidation() throws {
        #expect(try ExpenseSyncAPI.googleAuthorizationURL("https://accounts.google.com/o/oauth2/v2/auth?state=test").host == "accounts.google.com")
        for text in ["https://accounts.google.com.evil.example/o/oauth2/v2/auth", "http://accounts.google.com/o/oauth2/v2/auth", "https://accounts.google.com/other", "https://user@accounts.google.com/o/oauth2/v2/auth"] {
            #expect(throws: ExpenseSyncError.self) { try ExpenseSyncAPI.googleAuthorizationURL(text) }
        }
    }
    @Test("Outbox IDs survive Codable restart and offline repeated diff")
    func stableRetries() throws {
        var original = state()
        try original.enqueue(snapshot([expense()]))
        let id = original.outbox[0].id
        var restarted = try JSONDecoder().decode(ExpenseSyncState.self, from: JSONEncoder().encode(original))
        try restarted.enqueue(snapshot([expense("Changed offline")]))
        #expect(restarted.outbox.count == 1)
        #expect(restarted.outbox[0].id == id)
        #expect(restarted.outbox[0].expense?.title == "Bus")
    }
    @Test("Only explicit Trash generates archive; missing record pauses")
    func deletionSafety() throws {
        var active = state([expenseID: .init(expense: expense(), archived: false, revision: 4)])
        #expect(throws: ExpenseSyncError.self) { try active.enqueue(snapshot([])) }
        try active.enqueue(snapshot([], archived: [expense()]))
        #expect(active.outbox.first?.kind == .archive)
        #expect(active.outbox.first?.baseRevision == 4)
    }
    @Test("Restore uses a flag-only operation and preserves a simultaneous local edit")
    func restoreThenUpdate() throws {
        let original = expense()
        let edited = expense("Restored and edited")
        var initial = state([expenseID: .init(expense: original, archived: true, revision: 4)])
        try initial.enqueue(snapshot([edited]))
        let operation = try #require(initial.outbox.first)
        #expect(operation.kind == .restore)
        #expect(operation.expense == nil)
        #expect(operation.baseRevision == 4)
        let change = ExpenseSyncChange(sequence: 5, operationId: operation.id, kind: "restore", expenseId: expenseID,
                                       expense: original, archived: false, revision: 5, source: "iphone")
        let (restored, document) = try initial.plan(response(change), local: snapshot([edited]))
        #expect(document.operations.isEmpty)
        #expect(restored.outbox.isEmpty)
        #expect(restored.baseline[expenseID]?.expense.title == "Bus")
        var next = restored
        try next.enqueue(snapshot([edited]))
        let update = try #require(next.outbox.first)
        #expect(update.kind == .update)
        #expect(update.baseRevision == 5)
        #expect(update.expense == edited)
    }
    @Test("Archived history versions materialize exact canonical fields atomically", arguments: [false, true])
    func archivedHistoryFields(wasArchived: Bool) throws {
        let old = expense("Current title")
        let canonical = expense("Previous history title")
        let initial = state([expenseID: .init(expense: old, archived: wasArchived, revision: 4)])
        let local = snapshot(wasArchived ? [] : [old], archived: wasArchived ? [old] : [])
        let change = ExpenseSyncChange(sequence: 5, operationId: UUID().uuidString.lowercased(), kind: "restore_version",
                                       expenseId: expenseID, expense: canonical, archived: true, revision: 5, source: "app")
        let (next, document) = try initial.plan(response(change), local: local)
        #expect(document.operations.map(\.kind) == (wasArchived ? [.restore, .archive] : [.update, .archive]))
        let applied = try MCPExpenseExchange.plan(document: document, ledgerId: ledger, currency: "UZS", categoryIds: [category],
                                                 expenses: local.expenses, archivedExpenses: local.archivedExpenses, appliedOperations: [:])
        #expect(applied.expenses.isEmpty)
        #expect(applied.archivedExpenses == [canonical])
        #expect(next.baseline[expenseID]?.expense == canonical)
        var after = next
        try after.enqueue(snapshot([], archived: [canonical]))
        #expect(after.outbox.isEmpty)
    }
    @Test("Remote changes apply once and never echo into outbox")
    func pullNoEcho() throws {
        let initial = state()
        let change = ExpenseSyncChange(sequence: 1, operationId: UUID().uuidString.lowercased(), kind: "create", expenseId: expenseID, expense: expense(), archived: false, revision: 1, source: "mcp")
        let (next, document) = try initial.plan(response(change), local: snapshot([]))
        #expect(document.operations.count == 1)
        var after = next
        try after.enqueue(snapshot([expense()]))
        #expect(after.outbox.isEmpty)
        // Crash after app commit but before sync cursor persistence: equal contents are safe.
        let (_, replay) = try initial.plan(response(change), local: snapshot([expense()]))
        #expect(replay.operations.isEmpty)
    }
    @Test("Concurrent local edit blocks entire pulled page before mutation")
    func concurrentGuard() throws {
        let initial = state([expenseID: .init(expense: expense(), archived: false, revision: 1)])
        let change = ExpenseSyncChange(sequence: 1, operationId: UUID().uuidString.lowercased(), kind: "update", expenseId: expenseID, expense: expense("Remote edit"), archived: false, revision: 2, source: "notion")
        #expect(throws: ExpenseSyncError.self) { try initial.plan(response(change), local: snapshot([expense("Local edit")])) }
        // A hard deletion during the suspended request must not compare nil to
        // an absent pending operation and accidentally recreate the expense.
        #expect(throws: ExpenseSyncError.self) { try initial.plan(response(change), local: snapshot([])) }
        #expect(initial.cursor == 0)
    }
    @Test("Server conflicts leave outbox and cursor untouched")
    func serverConflict() throws {
        var initial = state()
        try initial.enqueue(snapshot([expense()]))
        let operation = initial.outbox[0]
        let change = ExpenseSyncChange(sequence: 1, operationId: operation.id, kind: "create", expenseId: expenseID, expense: expense(), archived: false, revision: 1, source: "iphone")
        #expect(throws: ExpenseSyncError.self) {
            try initial.plan(response(change, conflicts: [.init(operationId: operation.id, expenseId: expenseID, reason: "stale revision")]), local: snapshot([expense()]))
        }
        #expect(initial.outbox.count == 1)
        #expect(initial.cursor == 0)
    }

    @Test("Fresh installation never connects or uploads without consent")
    @MainActor
    func optInTransport() async throws {
        let suite = "SmartSpendTests.ExpenseSync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExpenseSyncTest-\(UUID().uuidString).json")
        var requests = 0
        let controller = ExpenseSyncController(dataManager: manager, stateURL: url, transport: { _, _, _, _ in
            requests += 1
            throw ExpenseSyncError.response
        })
        controller.foreground(true)
        await controller.sync()
        #expect(!controller.enabled)
        #expect(!controller.connected)
        #expect(requests == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
