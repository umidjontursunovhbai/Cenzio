import Foundation
import Security
import Combine

struct ExpenseSyncCredential: Codable {
    let server: URL
    let token: String
}

struct ExpenseSyncRecord: Codable, Equatable {
    let expense: MCPExpenseRecord
    let archived: Bool
    let revision: Int
    var signature: String { expense.fingerprint + (archived ? ":archived" : ":active") }
}

struct ExpenseSyncOperation: Codable, Identifiable {
    let id: String
    let kind: MCPExpenseOperation.Kind
    let expenseId: String
    let baseRevision: Int
    let expense: MCPExpenseRecord?
}

struct ExpenseSyncChange: Codable {
    let sequence: Int
    let operationId: String
    let kind: String
    let expenseId: String
    let expense: MCPExpenseRecord
    let archived: Bool
    let revision: Int
    let source: String
    var record: ExpenseSyncRecord { .init(expense: expense, archived: archived, revision: revision) }
}

struct ExpenseSyncConflict: Codable, Identifiable {
    let operationId: String
    let expenseId: String
    let reason: String
    var id: String { operationId }
}

struct ExpenseSyncResponse: Codable {
    let schemaVersion: Int
    let ledgerId: String
    let currency: String
    let changes: [ExpenseSyncChange]
    let nextSequence: Int
    let hasMore: Bool
    let conflicts: [ExpenseSyncConflict]
    let acknowledgedOperationIds: [String]
}

struct ExpenseSyncRemoteSnapshot: Decodable {
    let ledgerId: String
    let currency: String
    let revision: Int
    let nextSequence: Int
    let records: [ExpenseSyncRecord]
}

private struct ExpenseSyncContext: Decodable {
    let ledgerId: String
    let currency: String
    let revision: Int
    let categories: [MCPExchangeCategory]
}

struct ExpenseSyncGoogleStatus: Decodable {
    let connected: Bool
    let pending: Bool
    let spreadsheetId: String?

    var spreadsheetURL: URL? {
        guard connected, let spreadsheetId,
              spreadsheetId.range(of: #"^[A-Za-z0-9_-]{10,150}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://docs.google.com/spreadsheets/d/\(spreadsheetId)")
    }
}

struct ExpenseSyncHistoryItem: Decodable, Identifiable {
    let sequence: Int
    let operationId: String
    let kind: String
    let expenseId: String
    let before: ExpenseSyncRecord?
    let after: ExpenseSyncRecord
    let source: String
    let createdAt: String
    var id: Int { sequence }
}

struct ExpenseSyncHistoryPage: Decodable {
    let items: [ExpenseSyncHistoryItem]
    let nextSequence: Int
    let hasMore: Bool
}

enum ExpenseSyncError: LocalizedError, Equatable {
    case invalidServer, unauthorized, response, wrongLedger, unsafeRemoval, conflict, storage, initialMismatch
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address without a path, password or query."
        case .unauthorized: return "Sync access was revoked or expired. Reconnect with a dedicated sync credential."
        case .response: return "The sync response could not be validated. No remote changes were applied."
        case .wrongLedger: return "Ledger, currency or categories changed. Sync is paused to protect your expenses."
        case .unsafeRemoval: return "An expense disappeared outside Trash. Sync is paused; restore it locally or reconnect after reviewing both ledgers."
        case .conflict: return "An expense changed in two places. Sync is paused; review its history and keep the correct version."
        case .storage: return "Sync state could not be saved safely. Sync is paused."
        case .initialMismatch: return "This server contains a different ledger or different expenses. No data was replaced. Use manual reviewed exchange first."
        }
    }
}

private final class ExpenseSyncNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ExpenseSyncAPI {
    static func server(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else { throw ExpenseSyncError.invalidServer }
        return url
    }

    static func googleAuthorizationURL(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              parts.host == "accounts.google.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              ["/o/oauth2/v2/auth", "/o/oauth2/auth"].contains(parts.path),
              let url = parts.url else { throw ExpenseSyncError.response }
        return url
    }

    static func request(_ credential: ExpenseSyncCredential, path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        _ = try server(credential.server.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        let session = URLSession(configuration: configuration, delegate: ExpenseSyncNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: path, relativeTo: credential.server.appendingPathComponent("/"))?.absoluteURL,
              url.host == credential.server.host, url.scheme == "https" else { throw ExpenseSyncError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ExpenseSyncError.response }
        if response.statusCode == 401 || response.statusCode == 403 { throw ExpenseSyncError.unauthorized }
        guard (200...299).contains(response.statusCode), data.count <= 10 * 1_024 * 1_024 else { throw ExpenseSyncError.response }
        return data
    }
}

/// Durable state and outbox belong to one ledger and endpoint. Tokens are never saved here.
struct ExpenseSyncState: Codable {
    let ledgerId: String
    let currency: String
    let endpoint: String
    let clientId: String
    var cursor: Int
    var baseline: [String: ExpenseSyncRecord]
    var outbox: [ExpenseSyncOperation]
    var enabled: Bool

    static func localRecords(_ snapshot: MCPExchangeSnapshot) throws -> [String: ExpenseSyncRecord] {
        let records = snapshot.expenses.map { ExpenseSyncRecord(expense: $0, archived: false, revision: 0) }
            + snapshot.archivedExpenses.map { ExpenseSyncRecord(expense: $0, archived: true, revision: 0) }
        guard Set(records.map { $0.expense.id }).count == records.count else { throw ExpenseSyncError.response }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.expense.id, $0) })
    }

    mutating func enqueue(_ snapshot: MCPExchangeSnapshot) throws {
        guard snapshot.ledgerId == ledgerId, snapshot.currency == currency else { throw ExpenseSyncError.wrongLedger }
        let local = try Self.localRecords(snapshot)
        guard baseline.keys.allSatisfy({ local[$0] != nil }) else { throw ExpenseSyncError.unsafeRemoval }
        let pending = Set(outbox.map(\.expenseId))
        for (id, record) in local.sorted(by: { $0.key < $1.key }) where !pending.contains(id) {
            let before = baseline[id]
            guard before?.signature != record.signature else { continue }
            // A new already-archived record requires create then archive on a later pass.
            let kind: MCPExpenseOperation.Kind = before == nil ? .create :
                (before!.archived != record.archived ? (record.archived ? .archive : .restore) : .update)
            guard !(kind == .update && record.archived) else { throw ExpenseSyncError.conflict }
            outbox.append(.init(id: UUID().uuidString.lowercased(), kind: kind, expenseId: id,
                                baseRevision: before?.revision ?? 0,
                                expense: kind == .archive || kind == .restore ? nil : record.expense))
        }
    }

    /// Full page validation and local conflict detection happen before any app mutation.
    func plan(_ response: ExpenseSyncResponse, local: MCPExchangeSnapshot) throws -> (ExpenseSyncState, MCPExpenseOperationsDocument) {
        guard response.schemaVersion == 1, response.ledgerId == ledgerId, response.currency == currency,
              local.ledgerId == ledgerId, local.currency == currency,
              response.nextSequence >= cursor, response.changes.count <= 1_000 else { throw ExpenseSyncError.wrongLedger }
        guard response.conflicts.isEmpty else { throw ExpenseSyncError.conflict }
        var next = self
        var current = try Self.localRecords(local)
        var operations: [MCPExpenseOperation] = []
        var last = cursor
        let categories = Set(local.categories.map(\.id))
        for change in response.changes {
            guard change.sequence > last, change.sequence <= response.nextSequence,
                  change.expenseId == change.expense.id, change.revision > 0,
                  UUID(uuidString: change.operationId)?.uuidString.lowercased() == change.operationId else { throw ExpenseSyncError.response }
            _ = try change.expense.validated(categoryIds: categories)
            last = change.sequence
            let old = current[change.expenseId]
            let known = next.baseline[change.expenseId]
            let pending = outbox.first { $0.id == change.operationId }
            let expectedPending = pending.map { operation -> String in
                (operation.expense ?? known?.expense ?? change.expense).fingerprint + (operation.kind == .archive ? ":archived" : ":active")
            }
            // A locally created expense can be moved to Trash before its first
            // create was acknowledged. Keep that newer local archive intent.
            if pending?.kind == .create, old?.archived == true,
               old?.expense.fingerprint == change.expense.fingerprint, !change.archived {
                next.baseline[change.expenseId] = change.record
                continue
            }
            // Restore changes only the archived flag on the server. A user may
            // have edited the restored expense locally already: acknowledge the
            // restore without replacing those fields, then enqueue their update
            // against the returned revision on the next pass.
            if pending?.kind == .restore, old?.archived == false, !change.archived,
               change.expense.fingerprint == known?.expense.fingerprint {
                next.baseline[change.expenseId] = change.record
                continue
            }
            let matchesBaseline = known.map { old?.signature == $0.signature } ?? (old == nil)
            let matchesPending = expectedPending.map { old?.signature == $0 } ?? false
            guard old?.signature == change.record.signature || matchesBaseline || matchesPending else { throw ExpenseSyncError.conflict }
            if old?.signature != change.record.signature {
                // Translate authoritative state into the existing atomic, validated app journal.
                if change.archived {
                    // Canonical archived records may carry older/different fields
                    // restored from history. Build an active copy with exactly
                    // those fields before archiving; never archive stale fields.
                    if let old {
                        if old.archived {
                            operations.append(.init(id: UUID().uuidString.lowercased(), kind: .restore,
                                                    expenseId: change.expenseId, baseFingerprint: old.expense.fingerprint,
                                                    expense: change.expense))
                        } else if old.expense != change.expense {
                            operations.append(.init(id: UUID().uuidString.lowercased(), kind: .update,
                                                    expenseId: change.expenseId, baseFingerprint: old.expense.fingerprint,
                                                    expense: change.expense))
                        }
                    } else {
                        operations.append(.init(id: UUID().uuidString.lowercased(), kind: .create,
                                                expenseId: change.expenseId, baseFingerprint: nil, expense: change.expense))
                    }
                    operations.append(.init(id: UUID().uuidString.lowercased(), kind: .archive,
                                            expenseId: change.expenseId, baseFingerprint: change.expense.fingerprint, expense: nil))
                } else {
                    let kind: MCPExpenseOperation.Kind = old == nil ? .create : (old!.archived ? .restore : .update)
                    operations.append(.init(id: UUID().uuidString.lowercased(), kind: kind, expenseId: change.expenseId,
                                            baseFingerprint: old?.expense.fingerprint, expense: change.expense))
                }
                current[change.expenseId] = change.record
            }
            next.baseline[change.expenseId] = change.record
        }
        // Acknowledgements can precede their paginated change. Keep each outbox entry
        // until its authoritative revision was seen, preventing duplicate/new writes.
        let acknowledged = Set(response.acknowledgedOperationIds)
        next.outbox.removeAll { operation in
            acknowledged.contains(operation.id) && response.changes.contains { $0.operationId == operation.id }
        }
        next.cursor = response.nextSequence
        return (next, .init(schemaVersion: 1, ledgerId: ledgerId, currency: currency, operations: operations))
    }
}

@MainActor
final class ExpenseSyncController: ObservableObject {
    static let shared = ExpenseSyncController()
    @Published private(set) var state: ExpenseSyncState?
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false
    @Published private(set) var conflicts: [ExpenseSyncConflict] = []
    @Published private(set) var lastSynced: Date?
    private var credential: ExpenseSyncCredential?
    private var loop: Task<Void, Never>?
    private var observedLocalRecords: Data?
    private let dataManager: DataManager
    private let file: URL
    private let transport: (ExpenseSyncCredential, String, String, Data?) async throws -> Data
    private var keychain: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.tursunov.SmartSpend.expense-sync", kSecAttrAccount as String: "sync-only"]
    }
    var connected: Bool { credential != nil }
    var enabled: Bool { state?.enabled == true }

    init(dataManager: DataManager = .shared, stateURL: URL? = nil,
         transport: @escaping (ExpenseSyncCredential, String, String, Data?) async throws -> Data = { try await ExpenseSyncAPI.request($0, path: $1, method: $2, body: $3) }) {
        self.dataManager = dataManager
        self.transport = transport
        file = stateURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExpenseSync/state.json")
        if let data = try? Data(contentsOf: file) { state = try? JSONDecoder().decode(ExpenseSyncState.self, from: data) }
        if stateURL == nil {
            var query = keychain
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                credential = try? JSONDecoder().decode(ExpenseSyncCredential.self, from: data)
            }
        }
    }

    private func snapshot() throws -> MCPExchangeSnapshot { try JSONDecoder().decode(MCPExchangeSnapshot.self, from: dataManager.exportMCPSnapshot()) }
    private func persist(_ updated: ExpenseSyncState) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = updated
    }

    /// Explicit consent is presented by ExpenseSyncView before this can run.
    func connect(server: String, token: String, bootstrap: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let credential = ExpenseSyncCredential(server: try ExpenseSyncAPI.server(server), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            guard credential.token.count >= 32, credential.token.count <= 512,
                  !credential.token.contains(where: \.isWhitespace) else { throw ExpenseSyncError.unauthorized }
            let local = try snapshot()
            if bootstrap { _ = try await transport(credential, "v1/sync/bootstrap", "POST", JSONEncoder().encode(local)) }
            let remote = try JSONDecoder().decode(ExpenseSyncRemoteSnapshot.self, from: await transport(credential, "v1/sync/snapshot", "GET", nil))
            let records = try ExpenseSyncState.localRecords(local)
            guard remote.ledgerId == local.ledgerId, remote.currency == local.currency,
                  Set(remote.records.map { $0.expense.id }).count == remote.records.count,
                  remote.records.count == records.count,
                  remote.records.allSatisfy({ records[$0.expense.id]?.signature == $0.signature }) else { throw ExpenseSyncError.initialMismatch }
            let updated = ExpenseSyncState(ledgerId: local.ledgerId, currency: local.currency, endpoint: credential.server.absoluteString,
                                          clientId: UUID().uuidString.lowercased(), cursor: remote.nextSequence,
                                          baseline: Dictionary(uniqueKeysWithValues: remote.records.map { ($0.expense.id, $0) }), outbox: [], enabled: true)
            let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            var result = SecItemUpdate(keychain as CFDictionary, attributes as CFDictionary)
            if result == errSecItemNotFound { result = SecItemAdd(keychain.merging(attributes) { _, new in new } as CFDictionary, nil) }
            guard result == errSecSuccess else { throw ExpenseSyncError.storage }
            try persist(updated)
            self.credential = credential
            message = nil
            conflicts = []
            foreground(true)
        } catch { message = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) {
        guard var updated = state else { return }
        updated.enabled = enabled
        do { try persist(updated); message = nil; foreground(enabled) } catch { message = error.localizedDescription }
    }

    func disconnect() {
        setEnabled(false)
        SecItemDelete(keychain as CFDictionary)
        credential = nil
        message = "Disconnected on this iPhone. Server copies and the server-issued credential are not deleted; revoke access on your server if needed."
    }

    func foreground(_ active: Bool) {
        loop?.cancel()
        loop = nil
        guard active, enabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
    }

    func localDidChange() {
        guard enabled else { return }
        struct LocalRecords: Encodable { let expenses: [Expense]; let archived: [ArchivedExpense] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let current = try? encoder.encode(LocalRecords(expenses: dataManager.expenses, archived: dataManager.deletedExpenses)),
              current != observedLocalRecords else { return }
        observedLocalRecords = current
        Task { await sync() }
    }

    func sync() async {
        guard !isBusy, var state, state.enabled, let credential else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard state.endpoint == credential.server.absoluteString else { throw ExpenseSyncError.wrongLedger }
            let local = try snapshot()
            let context = try JSONDecoder().decode(ExpenseSyncContext.self, from: await transport(credential, "v1/sync/context", "GET", nil))
            guard context.ledgerId == local.ledgerId, context.currency == local.currency else { throw ExpenseSyncError.wrongLedger }
            let knownCategories = Set(context.categories.map(\.id))
            let additions = local.categories.filter { !knownCategories.contains($0.id) }
            if !additions.isEmpty {
                struct Categories: Encodable {
                    let ledgerId: String
                    let currency: String
                    let expectedRevision: Int
                    let categories: [MCPExchangeCategory]
                }
                let update = Categories(ledgerId: local.ledgerId, currency: local.currency,
                                        expectedRevision: context.revision, categories: context.categories + additions)
                _ = try await transport(credential, "v1/sync/categories", "POST", JSONEncoder().encode(update))
            }
            try state.enqueue(local)
            try persist(state) // Stable operation IDs are durable before network submission.
            struct Exchange: Encodable {
                let schemaVersion = 1
                let ledgerId: String
                let currency: String
                let clientId: String
                let afterSequence: Int
                let operations: [ExpenseSyncOperation]
            }
            for _ in 0..<20 {
                let request = Exchange(ledgerId: state.ledgerId, currency: state.currency, clientId: state.clientId,
                                       afterSequence: state.cursor, operations: Array(state.outbox.prefix(100)))
                let response = try JSONDecoder().decode(ExpenseSyncResponse.self, from: await transport(credential, "v1/sync/exchange", "POST", JSONEncoder().encode(request)))
                conflicts = response.conflicts
                // Re-read after suspension so edits made during the request are never overwritten.
                let (next, document) = try state.plan(response, local: snapshot())
                _ = try dataManager.applyMCPChanges(document)
                // If killed between app commit and cursor persistence, equal-content replay
                // is harmless. A stale cursor never causes a missing local write.
                try persist(next)
                state = next
                if !response.hasMore { break }
                guard response.nextSequence > request.afterSequence else { throw ExpenseSyncError.response }
            }
            message = nil
            lastSynced = Date()
        } catch is CancellationError { }
        catch {
            message = error.localizedDescription
            if let error = error as? ExpenseSyncError,
               [ExpenseSyncError.unauthorized, .wrongLedger, .unsafeRemoval, .conflict, .storage].contains(error) {
                state.enabled = false
                try? persist(state)
                loop?.cancel()
            }
        }
    }

    func history(expenseId: String, after: Int = 0) async throws -> ExpenseSyncHistoryPage {
        guard let credential, UUID(uuidString: expenseId) != nil else { throw ExpenseSyncError.unauthorized }
        return try JSONDecoder().decode(ExpenseSyncHistoryPage.self, from: await transport(credential, "v1/sync/history/\(expenseId)?afterSequence=\(after)&limit=50", "GET", nil))
    }

    func connectGoogle() async throws -> URL {
        guard let credential else { throw ExpenseSyncError.unauthorized }
        let body = try JSONSerialization.data(withJSONObject: ["consent": true, "connectorId": "google-default"])
        struct Authorization: Decodable { let authorizationUrl: String }
        let result = try JSONDecoder().decode(Authorization.self, from: await transport(credential, "v1/connectors/google/start", "POST", body))
        // OAuth state is passed only to the system browser; never logged or saved.
        return try ExpenseSyncAPI.googleAuthorizationURL(result.authorizationUrl)
    }

    func googleStatus() async throws -> ExpenseSyncGoogleStatus {
        guard let credential else { throw ExpenseSyncError.unauthorized }
        return try JSONDecoder().decode(ExpenseSyncGoogleStatus.self,
                                       from: await transport(credential, "v1/connectors/google/status", "GET", nil))
    }

    func restore(_ item: ExpenseSyncHistoryItem) async throws {
        guard !isBusy, let credential, let state,
              let current = state.baseline[item.expenseId] else { throw ExpenseSyncError.conflict }
        // Do not restore over an unsent local edit.
        guard try ExpenseSyncState.localRecords(snapshot())[item.expenseId]?.signature == current.signature,
              !state.outbox.contains(where: { $0.expenseId == item.expenseId }) else { throw ExpenseSyncError.conflict }
        let body = try JSONSerialization.data(withJSONObject: ["expenseId": item.expenseId, "historySequence": item.sequence,
                                                              "expectedRevision": current.revision, "operationId": UUID().uuidString.lowercased()])
        struct RestoreResponse: Decodable { let acknowledged: Bool? }
        let response = try JSONDecoder().decode(RestoreResponse.self, from: await transport(credential, "v1/sync/restore", "POST", body))
        guard response.acknowledged == true else { throw ExpenseSyncError.conflict }
        // Pull even when previously paused; explicit restore is a user action.
        setEnabled(true)
        await sync()
    }
}
