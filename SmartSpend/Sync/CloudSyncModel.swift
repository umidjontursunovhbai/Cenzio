import CloudKit
import CryptoKit
import Foundation

// Pure parts of iCloud sync: record identity, local change tracking, merge rules and
// CKRecord mapping. Nothing here talks to the network, so it is unit tested directly.

/// One CKRecord type per synced collection. Learned patterns stay local (rebuilt from expenses).
enum CloudSyncRecordKind: String, CaseIterable, Codable, Sendable {
    /// Active and archived (Deleted) expenses share one record per expense UUID with an
    /// `archived` state, like the Notion sync. Moving to Deleted is an update, never a gap.
    case expense = "Expense"
    case category = "Category"
    /// Keyed by category: the app keeps one budget per category.
    case budget = "CategoryBudget"
    case goal = "SpendingGoal"
    /// Keyed by year-month: the app keeps one salary per month.
    case salary = "MonthlySalary"
    case recurring = "RecurringExpense"
    case settings = "Settings"

    /// Expense records are named by the bare lowercased expense UUID (the same id the
    /// Notion sync uses); other kinds carry a prefix so names never collide.
    func recordName(key: String) -> String {
        self == .expense ? key : "\(rawValue).\(key)"
    }

    static func parse(recordName: String) -> (kind: CloudSyncRecordKind, key: String)? {
        if let dot = recordName.firstIndex(of: "."),
           let kind = CloudSyncRecordKind(rawValue: String(recordName[..<dot])) {
            return (kind, String(recordName[recordName.index(after: dot)...]))
        }
        return UUID(uuidString: recordName) == nil ? nil : (.expense, recordName)
    }
}

/// Payload of an `Expense` record: exactly one of the two is set.
struct CloudSyncExpenseEntry: Codable {
    var active: Expense?
    var archived: ArchivedExpense?
}

/// One syncable local value, encoded the way it is stored in the record payload.
struct CloudSyncItem {
    let kind: CloudSyncRecordKind
    let recordName: String
    let payload: Data
    /// True for an expense that sits in Deleted.
    let isArchived: Bool

    var hash: String { CloudSyncCoding.hash(payload) }
}

enum CloudSyncCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func uuidKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    static func salaryKey(year: Int, month: Int) -> String { String(format: "%04d-%02d", year, month) }
}

// MARK: - Local dataset

/// The synced subset of DataManager state.
struct CloudSyncDataset {
    var expenses: [Expense]
    var deletedExpenses: [ArchivedExpense]
    var userCategories: [UserCategory]
    var categoryBudgets: [CategoryBudget]
    var spendingGoals: [SpendingGoal]
    var monthlySalaries: [MonthlySalary]
    var recurringExpenses: [RecurringExpense]
    var user: User

    static let settingsKey = "user"

    /// Every syncable value keyed by record name. If an id is both active and archived
    /// (should not happen), the archived copy wins, matching the merge rule below.
    func items() -> [String: CloudSyncItem] {
        var result: [String: CloudSyncItem] = [:]
        func put(_ kind: CloudSyncRecordKind, _ key: String, _ value: some Encodable, archived: Bool = false) {
            guard let payload = try? CloudSyncCoding.encode(value) else { return }
            let name = kind.recordName(key: key)
            result[name] = CloudSyncItem(kind: kind, recordName: name, payload: payload, isArchived: archived)
        }
        for expense in expenses {
            put(.expense, CloudSyncCoding.uuidKey(expense.id), CloudSyncExpenseEntry(active: expense))
        }
        for archived in deletedExpenses {
            put(.expense, CloudSyncCoding.uuidKey(archived.id), CloudSyncExpenseEntry(archived: archived), archived: true)
        }
        for category in userCategories { put(.category, CloudSyncCoding.uuidKey(category.id), category) }
        for budget in categoryBudgets { put(.budget, CloudSyncCoding.uuidKey(budget.categoryId), budget) }
        for goal in spendingGoals { put(.goal, CloudSyncCoding.uuidKey(goal.id), goal) }
        for salary in monthlySalaries.sorted(by: { $0.dateSet < $1.dateSet }) {
            put(.salary, CloudSyncCoding.salaryKey(year: salary.year, month: salary.month), salary)
        }
        for recurring in recurringExpenses { put(.recurring, CloudSyncCoding.uuidKey(recurring.id), recurring) }
        put(.settings, Self.settingsKey, user)
        return result
    }

    func item(named recordName: String) -> CloudSyncItem? {
        // Linear, but only used for single records while applying a batch.
        guard let (kind, key) = CloudSyncRecordKind.parse(recordName: recordName) else { return nil }
        func make(_ value: some Encodable, archived: Bool = false) -> CloudSyncItem? {
            guard let payload = try? CloudSyncCoding.encode(value) else { return nil }
            return CloudSyncItem(kind: kind, recordName: recordName, payload: payload, isArchived: archived)
        }
        switch kind {
        case .expense:
            if let archived = deletedExpenses.last(where: { CloudSyncCoding.uuidKey($0.id) == key }) {
                return make(CloudSyncExpenseEntry(archived: archived), archived: true)
            }
            return expenses.last(where: { CloudSyncCoding.uuidKey($0.id) == key }).flatMap { make(CloudSyncExpenseEntry(active: $0)) }
        case .category: return userCategories.last(where: { CloudSyncCoding.uuidKey($0.id) == key }).flatMap { make($0) }
        case .budget: return categoryBudgets.last(where: { CloudSyncCoding.uuidKey($0.categoryId) == key }).flatMap { make($0) }
        case .goal: return spendingGoals.last(where: { CloudSyncCoding.uuidKey($0.id) == key }).flatMap { make($0) }
        case .salary:
            return monthlySalaries.sorted(by: { $0.dateSet < $1.dateSet })
                .last(where: { CloudSyncCoding.salaryKey(year: $0.year, month: $0.month) == key }).flatMap { make($0) }
        case .recurring: return recurringExpenses.last(where: { CloudSyncCoding.uuidKey($0.id) == key }).flatMap { make($0) }
        case .settings: return make(user)
        }
    }

    /// Writes a remote value, replacing the local value with the same identity in place.
    mutating func upsert(kind: CloudSyncRecordKind, payload: Data) throws {
        switch kind {
        case .expense:
            let entry = try CloudSyncCoding.decode(CloudSyncExpenseEntry.self, from: payload)
            if let active = entry.active {
                deletedExpenses.removeAll { $0.id == active.id }
                Self.replaceOrAppend(&expenses, active) { $0.id == active.id }
            } else if let archived = entry.archived {
                expenses.removeAll { $0.id == archived.id }
                Self.replaceOrAppend(&deletedExpenses, archived) { $0.id == archived.id }
            } else {
                throw CocoaError(.coderReadCorrupt)
            }
        case .category:
            let value = try CloudSyncCoding.decode(UserCategory.self, from: payload)
            Self.replaceOrAppend(&userCategories, value) { $0.id == value.id }
        case .budget:
            let value = try CloudSyncCoding.decode(CategoryBudget.self, from: payload)
            Self.replaceOrAppend(&categoryBudgets, value) { $0.categoryId == value.categoryId }
        case .goal:
            let value = try CloudSyncCoding.decode(SpendingGoal.self, from: payload)
            Self.replaceOrAppend(&spendingGoals, value) { $0.id == value.id }
        case .salary:
            let value = try CloudSyncCoding.decode(MonthlySalary.self, from: payload)
            Self.replaceOrAppend(&monthlySalaries, value) { $0.year == value.year && $0.month == value.month }
        case .recurring:
            var value = try CloudSyncCoding.decode(RecurringExpense.self, from: payload)
            // Never move the occurrence cursor backwards: an older cursor would make this
            // device record charges again (their ids are deterministic, but stay safe).
            if let local = recurringExpenses.first(where: { $0.id == value.id }) {
                value.lastProcessedDate = [local.lastProcessedDate, value.lastProcessedDate].compactMap { $0 }.max()
            }
            Self.replaceOrAppend(&recurringExpenses, value) { $0.id == value.id }
        case .settings:
            user = try CloudSyncCoding.decode(User.self, from: payload)
        }
    }

    mutating func remove(recordName: String) {
        guard let (kind, key) = CloudSyncRecordKind.parse(recordName: recordName) else { return }
        switch kind {
        case .expense:
            expenses.removeAll { CloudSyncCoding.uuidKey($0.id) == key }
            deletedExpenses.removeAll { CloudSyncCoding.uuidKey($0.id) == key }
        case .category: userCategories.removeAll { CloudSyncCoding.uuidKey($0.id) == key }
        case .budget: categoryBudgets.removeAll { CloudSyncCoding.uuidKey($0.categoryId) == key }
        case .goal: spendingGoals.removeAll { CloudSyncCoding.uuidKey($0.id) == key }
        case .salary: monthlySalaries.removeAll { CloudSyncCoding.salaryKey(year: $0.year, month: $0.month) == key }
        case .recurring: recurringExpenses.removeAll { CloudSyncCoding.uuidKey($0.id) == key }
        case .settings: break
        }
    }

    /// Points everything that used `old` at `new` (first-sync merge of same-named categories).
    mutating func remapCategory(from old: UUID, to new: UUID) {
        expenses = expenses.map { var value = $0; if value.categoryId == old { value.categoryId = new }; return value }
        spendingGoals = spendingGoals.map { var value = $0; if value.categoryId == old { value.categoryId = new }; return value }
        recurringExpenses = recurringExpenses.map { var value = $0; if value.categoryId == old { value.categoryId = new }; return value }
        deletedExpenses = deletedExpenses.map { $0.categoryId == old ? Self.remapped($0, to: new) : $0 }
        categoryBudgets = categoryBudgets.map { $0.categoryId == old ? Self.remapped($0, to: new) : $0 }
        // Two budgets for the merged category: keep the last one.
        var seen = Set<UUID>()
        categoryBudgets = categoryBudgets.reversed().filter { seen.insert($0.categoryId).inserted }.reversed()
        userCategories.removeAll { $0.id == old }
    }

    /// `categoryId` is a `let` on some models; rewrite it through their Codable form.
    private static func remapped<T: Codable>(_ value: T, to category: UUID) -> T {
        guard let data = try? JSONEncoder().encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return value }
        object["categoryId"] = category.uuidString
        guard let updated = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder().decode(T.self, from: updated) else { return value }
        return decoded
    }

    private static func replaceOrAppend<T>(_ array: inout [T], _ value: T, where matches: (T) -> Bool) {
        if let index = array.firstIndex(where: matches) {
            array[index] = value
            var position = array.index(after: index)
            while position < array.endIndex {
                if matches(array[position]) { array.remove(at: position) } else { position = array.index(after: position) }
            }
        } else {
            array.append(value)
        }
    }
}

// MARK: - Sync metadata

/// What this device last knew about one record. `modifiedAt` lives here, not in the models.
struct CloudSyncEntry: Codable, Equatable {
    /// Hash of the payload this metadata describes; nil marks a local deletion not yet confirmed.
    var hash: String?
    var modifiedAt: Date
    /// When an archived expense was last explicitly restored. Only a restore newer than an
    /// archive may bring an expense back, so a stale edit never resurrects a Deleted one.
    var restoredAt: Date?
    var archived: Bool
    /// Encoded CKRecord system fields (change tag) of the last known server version.
    var systemFields: Data?

    var isTombstone: Bool { hash == nil }
}

struct CloudSyncMetadata: Codable, Equatable {
    var entries: [String: CloudSyncEntry] = [:]
    /// False until the first capture. Data that existed before sync was turned on is given
    /// `distantPast`, so on a first-sync overlap the iCloud copy wins over a stale local one
    /// (a fresh device never overrides real settings with its defaults).
    var hasCapturedOnce = false

    /// After an account change or zone reset: nothing is known on the server any more.
    mutating func resetServerState() {
        entries = entries.filter { !$0.value.isTombstone }.mapValues { var entry = $0; entry.systemFields = nil; return entry }
    }
}

struct CloudSyncChanges: Equatable {
    var saves: Set<String> = []
    var deletes: Set<String> = []
    var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

enum CloudSyncTracker {
    /// Diffs local values against metadata. New or changed values get `modifiedAt = now`
    /// and become pending saves; vanished ones become tombstones and pending deletions.
    /// Values written by a remote apply already match their metadata, so they never echo.
    static func capture(_ items: [String: CloudSyncItem], metadata: inout CloudSyncMetadata, now: Date) -> CloudSyncChanges {
        var changes = CloudSyncChanges()
        let baseline = metadata.hasCapturedOnce ? now : .distantPast
        for (name, item) in items {
            let hash = item.hash
            if var entry = metadata.entries[name] {
                guard entry.hash != hash else { continue }
                if item.kind == .expense, entry.archived || entry.isTombstone, !item.isArchived {
                    entry.restoredAt = now
                }
                entry.hash = hash
                entry.archived = item.isArchived
                entry.modifiedAt = max(now, entry.modifiedAt)
                metadata.entries[name] = entry
            } else {
                metadata.entries[name] = CloudSyncEntry(hash: hash, modifiedAt: baseline, archived: item.isArchived)
            }
            changes.saves.insert(name)
        }
        for (name, entry) in metadata.entries where items[name] == nil && !entry.isTombstone {
            var tombstone = entry
            tombstone.hash = nil
            tombstone.modifiedAt = max(now, entry.modifiedAt)
            metadata.entries[name] = tombstone
            changes.deletes.insert(name)
        }
        metadata.hasCapturedOnce = true
        return changes
    }
}

// MARK: - Merge

struct CloudSyncRemoteRecord {
    let recordName: String
    let kind: CloudSyncRecordKind
    let payload: Data
    let modifiedAt: Date
    let restoredAt: Date?
    let isArchived: Bool
    let systemFields: Data?
    let appleAccountHash: String?

    var hash: String { CloudSyncCoding.hash(payload) }
}

struct CloudSyncApplyResult: Equatable {
    var dataChanged = false
    /// Local wins over the server version: send it again (on top of the new change tag).
    var resend: Set<String> = []
    /// A local deletion wins over a remote edit: delete again.
    var redelete: Set<String> = []
    /// Now equal to the server (or deliberately local-only): drop any pending send for them.
    var settled: Set<String> = []
}

enum CloudSyncMerge {
    enum Decision: Equatable { case applyRemote, keepLocal, same }

    /// Per-record last-modified-wins, with one exception for expenses: Deleted beats a
    /// concurrent edit unless the active side was explicitly restored after the archive.
    /// Equal times go to the server copy so every device converges on the same value.
    static func decide(remote: CloudSyncRemoteRecord, local entry: CloudSyncEntry?, localItem: CloudSyncItem?) -> Decision {
        if let localItem, localItem.hash == remote.hash { return .same }
        guard let entry else { return .applyRemote }
        if remote.kind == .expense {
            let localGone = entry.isTombstone || entry.archived
            if remote.isArchived, !localGone {
                return (entry.restoredAt ?? .distantPast) > remote.modifiedAt ? .keepLocal : .applyRemote
            }
            if !remote.isArchived, localGone {
                return (remote.restoredAt ?? .distantPast) > entry.modifiedAt ? .applyRemote : .keepLocal
            }
            if entry.isTombstone { return .keepLocal }  // permanently deleted beats an archived edit
        }
        return remote.modifiedAt >= entry.modifiedAt ? .applyRemote : .keepLocal
    }

    /// Applies fetched server changes to the dataset and metadata in one pass.
    static func apply(saves: [CloudSyncRemoteRecord], deletions: [String],
                      to dataset: inout CloudSyncDataset, metadata: inout CloudSyncMetadata) -> CloudSyncApplyResult {
        var result = CloudSyncApplyResult()
        for remote in saves {
            let entry = metadata.entries[remote.recordName]
            if remote.kind == .category, entry == nil { mergeSameNamedCategory(remote, &dataset, &metadata, &result) }
            switch decide(remote: remote, local: entry, localItem: dataset.item(named: remote.recordName)) {
            case .same:
                var known = entry ?? CloudSyncEntry(hash: remote.hash, modifiedAt: remote.modifiedAt, archived: remote.isArchived)
                known.modifiedAt = max(known.modifiedAt, remote.modifiedAt)
                known.restoredAt = [known.restoredAt, remote.restoredAt].compactMap { $0 }.max()
                known.systemFields = remote.systemFields
                metadata.entries[remote.recordName] = known
                result.settled.insert(remote.recordName)
            case .applyRemote:
                guard (try? dataset.upsert(kind: remote.kind, payload: remote.payload)) != nil else { continue }
                metadata.entries[remote.recordName] = CloudSyncEntry(
                    hash: remote.hash, modifiedAt: remote.modifiedAt, restoredAt: remote.restoredAt,
                    archived: remote.isArchived, systemFields: remote.systemFields)
                result.dataChanged = true
                result.settled.insert(remote.recordName)
            case .keepLocal:
                guard var known = entry else { continue }
                known.systemFields = remote.systemFields
                metadata.entries[remote.recordName] = known
                if known.isTombstone { result.redelete.insert(remote.recordName) } else { result.resend.insert(remote.recordName) }
            }
        }
        for name in deletions {
            if applyDeletion(name, &dataset, &metadata) { result.dataChanged = true }
            result.settled.insert(name)
        }
        return result
    }

    /// A server deletion is final for everything except an active expense: that one moves to
    /// Deleted on this device instead of vanishing (recoverable, and the Notion sync never sees
    /// an expense disappear outside Trash). The local archive copy is not uploaded.
    private static func applyDeletion(_ name: String, _ dataset: inout CloudSyncDataset, _ metadata: inout CloudSyncMetadata) -> Bool {
        let local = dataset.item(named: name)
        if let local, local.kind == .expense, !local.isArchived,
           let key = CloudSyncRecordKind.parse(recordName: name)?.key,
           let expense = dataset.expenses.first(where: { CloudSyncCoding.uuidKey($0.id) == key }) {
            let archived = ArchivedExpense(from: expense)
            dataset.expenses.removeAll { $0.id == expense.id }
            dataset.deletedExpenses.append(archived)
            let payload = (try? CloudSyncCoding.encode(CloudSyncExpenseEntry(archived: archived))) ?? Data()
            metadata.entries[name] = CloudSyncEntry(hash: CloudSyncCoding.hash(payload),
                                                    modifiedAt: metadata.entries[name]?.modifiedAt ?? .distantPast,
                                                    archived: true)
            return true
        }
        metadata.entries[name] = nil
        guard local != nil else { return false }
        dataset.remove(recordName: name)
        return true
    }

    /// First sync of two devices that each created a "Food" category: adopt the iCloud one
    /// and move local references to it, instead of showing two "Food" categories.
    private static func mergeSameNamedCategory(_ remote: CloudSyncRemoteRecord, _ dataset: inout CloudSyncDataset,
                                               _ metadata: inout CloudSyncMetadata, _ result: inout CloudSyncApplyResult) {
        guard let incoming = try? CloudSyncCoding.decode(UserCategory.self, from: remote.payload),
              !dataset.userCategories.contains(where: { $0.id == incoming.id }) else { return }
        let name = incoming.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let local = dataset.userCategories.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
        }) else { return }
        let localName = CloudSyncRecordKind.category.recordName(key: CloudSyncCoding.uuidKey(local.id))
        // Only a category this device never got onto the server; synced ones are distinct on purpose.
        guard metadata.entries[localName]?.systemFields == nil else { return }
        dataset.remapCategory(from: local.id, to: incoming.id)
        result.dataChanged = true
    }
}

// MARK: - CKRecord mapping

enum CloudSyncRecordMapper {
    static let zoneID = CKRecordZone.ID(zoneName: "SmartSpend", ownerName: CKCurrentUserDefaultName)
    static let schemaVersion = 1

    enum Field {
        static let payload = "payload"
        static let modifiedAt = "modifiedAt"
        static let restoredAt = "restoredAt"
        static let archived = "archived"
        static let schemaVersion = "schemaVersion"
        static let appleAccountHash = "appleAccountHash"
    }

    static func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    static func record(for item: CloudSyncItem, entry: CloudSyncEntry, appleAccountHash: String?) -> CKRecord {
        let record = entry.systemFields.flatMap(decodeSystemFields)
            ?? CKRecord(recordType: item.kind.rawValue, recordID: recordID(item.recordName))
        record[Field.payload] = item.payload as NSData
        record[Field.modifiedAt] = entry.modifiedAt as NSDate
        record[Field.restoredAt] = entry.restoredAt.map { $0 as NSDate }
        record[Field.archived] = NSNumber(value: item.isArchived)
        record[Field.schemaVersion] = NSNumber(value: schemaVersion)
        record[Field.appleAccountHash] = appleAccountHash.map { $0 as NSString }
        return record
    }

    static func remoteRecord(from record: CKRecord) -> CloudSyncRemoteRecord? {
        guard let kind = CloudSyncRecordKind(rawValue: record.recordType),
              let payload = record[Field.payload] as? Data,
              (record[Field.schemaVersion] as? Int ?? 1) <= schemaVersion else { return nil }
        return CloudSyncRemoteRecord(
            recordName: record.recordID.recordName,
            kind: kind,
            payload: payload,
            modifiedAt: record[Field.modifiedAt] as? Date ?? record.modificationDate ?? .distantPast,
            restoredAt: record[Field.restoredAt] as? Date,
            isArchived: (record[Field.archived] as? Bool) ?? false,
            systemFields: encodeSystemFields(record),
            appleAccountHash: record[Field.appleAccountHash] as? String
        )
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func appleAccountHash(_ userID: String?) -> String? {
        userID.map { CloudSyncCoding.hash(Data("smartspend-apple:\($0)".utf8)) }
    }
}
