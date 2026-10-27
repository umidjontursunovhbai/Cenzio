import CloudKit
import Foundation
import Testing
@testable import SmartSpend

/// Exercises the pure iCloud sync layer: record mapping, change tracking and merge rules.
/// `FakeCloud` stands in for CKSyncEngine + the private database (change tags, conflicts,
/// incremental fetches) so multi-device scenarios run without CloudKit.
@Suite("iCloud sync")
struct CloudSyncTests {

    // MARK: - Fixtures

    private static func emptyDataset() -> CloudSyncDataset {
        CloudSyncDataset(expenses: [], deletedExpenses: [], userCategories: [], categoryBudgets: [],
                         spendingGoals: [], monthlySalaries: [], recurringExpenses: [], user: User())
    }

    private static func expense(_ title: String, _ amount: Double, category: UUID, id: UUID = UUID()) -> Expense {
        var value = Expense(title: title, amount: amount, categoryId: category,
                            date: Date(timeIntervalSince1970: 1_790_000_000))
        value.id = id
        return value
    }

    private static func remote(_ item: CloudSyncItem, modifiedAt: Date, restoredAt: Date? = nil) -> CloudSyncRemoteRecord {
        CloudSyncRemoteRecord(recordName: item.recordName, kind: item.kind, payload: item.payload,
                              modifiedAt: modifiedAt, restoredAt: restoredAt, isArchived: item.isArchived,
                              systemFields: nil, appleAccountHash: nil)
    }

    // MARK: - Record mapping

    @Test("Every record kind round-trips through CKRecord into an equal model")
    func recordRoundTrip() throws {
        let category = UserCategory(name: "Food", iconSystemName: "shopping-cart", colorName: "systemGreen")
        var source = Self.emptyDataset()
        source.userCategories = [category]
        source.expenses = [Self.expense("Lunch", 12.5, category: category.id)]
        source.deletedExpenses = [ArchivedExpense(from: Self.expense("Old", 3, category: category.id))]
        source.categoryBudgets = [CategoryBudget(categoryId: category.id, amount: 300, isEnabled: true)]
        source.spendingGoals = [SpendingGoal(title: "Save", targetAmount: 500,
                                             deadline: Date(timeIntervalSince1970: 1_800_000_000), categoryId: category.id)]
        source.monthlySalaries = [MonthlySalary(year: 2026, month: 10, amount: 4_000, currency: .eur)]
        source.recurringExpenses = [RecurringExpense(title: "Rent", amount: 900, categoryId: category.id,
                                                     recurrenceType: .monthly, startDate: Date(timeIntervalSince1970: 1_780_000_000))]
        source.user = User(currency: .eur, language: .russian)

        let items = source.items()
        #expect(Set(items.values.map(\.kind)) == Set(CloudSyncRecordKind.allCases))

        var restored = Self.emptyDataset()
        for item in items.values {
            let entry = CloudSyncEntry(hash: item.hash, modifiedAt: Date(timeIntervalSince1970: 1_790_000_100),
                                       restoredAt: nil, archived: item.isArchived)
            let record = CloudSyncRecordMapper.record(for: item, entry: entry, appleAccountHash: "abc")
            #expect(record.recordID.zoneID == CloudSyncRecordMapper.zoneID)
            #expect(record.recordType == item.kind.rawValue)
            let remote = try #require(CloudSyncRecordMapper.remoteRecord(from: record))
            #expect(remote.recordName == item.recordName)
            #expect(remote.modifiedAt == entry.modifiedAt)
            #expect(remote.isArchived == item.isArchived)
            #expect(remote.appleAccountHash == "abc")
            #expect(remote.hash == item.hash)
            try restored.upsert(kind: remote.kind, payload: remote.payload)
        }
        let restoredItems = restored.items()
        #expect(restoredItems.mapValues(\.hash) == items.mapValues(\.hash))
        #expect(restored.deletedExpenses.map(\.id) == source.deletedExpenses.map(\.id))
        #expect(restored.expenses == source.expenses)
    }

    @Test("Expense records are named by the bare expense UUID, other kinds are prefixed")
    func recordNames() throws {
        let id = UUID()
        let expenseName = CloudSyncRecordKind.expense.recordName(key: CloudSyncCoding.uuidKey(id))
        #expect(expenseName == id.uuidString.lowercased())
        #expect(CloudSyncRecordKind.parse(recordName: expenseName)?.kind == .expense)
        let salary = CloudSyncRecordKind.salary.recordName(key: CloudSyncCoding.salaryKey(year: 2026, month: 3))
        #expect(salary == "MonthlySalary.2026-03")
        #expect(CloudSyncRecordKind.parse(recordName: salary)?.key == "2026-03")
        #expect(CloudSyncRecordKind.parse(recordName: "garbage") == nil)
    }

    @Test("System fields survive encoding so the next save carries the change tag")
    func systemFieldsRoundTrip() throws {
        let record = CKRecord(recordType: "Expense", recordID: CloudSyncRecordMapper.recordID("x"))
        let data = CloudSyncRecordMapper.encodeSystemFields(record)
        let decoded = try #require(CloudSyncRecordMapper.decodeSystemFields(data))
        #expect(decoded.recordID == record.recordID)
        #expect(decoded.recordType == "Expense")
    }

    // MARK: - Change tracking

    @Test("Pre-existing data is captured at distantPast, later edits at now, removals as tombstones")
    func tracker() {
        var dataset = Self.emptyDataset()
        let category = UserCategory(name: "Food")
        dataset.userCategories = [category]
        var metadata = CloudSyncMetadata()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let first = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: t1)
        #expect(first.saves.count == 2) // category + settings
        #expect(metadata.entries.values.allSatisfy { $0.modifiedAt == .distantPast })

        #expect(CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: t1).isEmpty)

        dataset.userCategories[0].name = "Groceries"
        let t2 = Date(timeIntervalSince1970: 2_000)
        let edit = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: t2)
        let name = CloudSyncRecordKind.category.recordName(key: CloudSyncCoding.uuidKey(category.id))
        #expect(edit.saves == [name])
        #expect(metadata.entries[name]?.modifiedAt == t2)

        dataset.userCategories = []
        let removal = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: t2)
        #expect(removal.deletes == [name])
        #expect(metadata.entries[name]?.isTombstone == true)
    }

    @Test("Restoring from Deleted stamps restoredAt")
    func restoreStamp() {
        let expense = Self.expense("Taxi", 9, category: UUID())
        var dataset = Self.emptyDataset()
        dataset.deletedExpenses = [ArchivedExpense(from: expense)]
        var metadata = CloudSyncMetadata()
        _ = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: Date(timeIntervalSince1970: 1))
        dataset.deletedExpenses = []
        dataset.expenses = [expense]
        let now = Date(timeIntervalSince1970: 50)
        _ = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: now)
        let entry = metadata.entries[CloudSyncCoding.uuidKey(expense.id)]
        #expect(entry?.restoredAt == now)
        #expect(entry?.archived == false)
    }

    // MARK: - Merge rules

    @Test("Last modified wins per record; a tie goes to the server copy")
    func lastModifiedWins() throws {
        let category = UserCategory(name: "Food")
        var dataset = Self.emptyDataset()
        dataset.userCategories = [category]
        var metadata = CloudSyncMetadata(hasCapturedOnce: true)
        _ = CloudSyncTracker.capture(dataset.items(), metadata: &metadata, now: Date(timeIntervalSince1970: 100))
        let name = CloudSyncRecordKind.category.recordName(key: CloudSyncCoding.uuidKey(category.id))

        var renamed = category
        renamed.name = "Dining"
        var other = Self.emptyDataset()
        other.userCategories = [renamed]
        let remoteItem = try #require(other.items()[name])

        // Older remote edit loses and the local copy is resent.
        var older = dataset, olderMeta = metadata
        let lost = CloudSyncMerge.apply(saves: [Self.remote(remoteItem, modifiedAt: Date(timeIntervalSince1970: 50))],
                                        deletions: [], to: &older, metadata: &olderMeta)
        #expect(older.userCategories.first?.name == "Food")
        #expect(lost.resend == [name])
        #expect(!lost.dataChanged)

        // Newer remote edit wins.
        var newer = dataset, newerMeta = metadata
        let won = CloudSyncMerge.apply(saves: [Self.remote(remoteItem, modifiedAt: Date(timeIntervalSince1970: 200))],
                                       deletions: [], to: &newer, metadata: &newerMeta)
        #expect(newer.userCategories.first?.name == "Dining")
        #expect(won.dataChanged)
        // Applying a remote value never echoes it back.
        #expect(CloudSyncTracker.capture(newer.items(), metadata: &newerMeta, now: Date(timeIntervalSince1970: 300)).isEmpty)

        // Same timestamp: server wins.
        var tie = dataset, tieMeta = metadata
        _ = CloudSyncMerge.apply(saves: [Self.remote(remoteItem, modifiedAt: Date(timeIntervalSince1970: 100))],
                                 deletions: [], to: &tie, metadata: &tieMeta)
        #expect(tie.userCategories.first?.name == "Dining")
    }

    @Test("Deleted beats a concurrent edit unless the expense was restored after the archive")
    func archiveWins() throws {
        let expense = Self.expense("Coffee", 4, category: UUID())
        let name = CloudSyncCoding.uuidKey(expense.id)
        var archivedSide = Self.emptyDataset()
        archivedSide.deletedExpenses = [ArchivedExpense(from: expense)]
        let archivedItem = try #require(archivedSide.items()[name])

        // Local edit at t=300 (no restore) vs remote archive at t=200: archive wins.
        var local = Self.emptyDataset()
        local.expenses = [expense]
        var meta = CloudSyncMetadata(hasCapturedOnce: true)
        _ = CloudSyncTracker.capture(local.items(), metadata: &meta, now: Date(timeIntervalSince1970: 300))
        _ = CloudSyncMerge.apply(saves: [Self.remote(archivedItem, modifiedAt: Date(timeIntervalSince1970: 200))],
                                 deletions: [], to: &local, metadata: &meta)
        #expect(local.expenses.isEmpty)
        #expect(local.deletedExpenses.map(\.id) == [expense.id])

        // A remote active copy that is not a restore cannot resurrect a local archive.
        var activeSide = Self.emptyDataset()
        activeSide.expenses = [expense]
        let activeItem = try #require(activeSide.items()[name])
        let result = CloudSyncMerge.apply(saves: [Self.remote(activeItem, modifiedAt: Date(timeIntervalSince1970: 900))],
                                          deletions: [], to: &local, metadata: &meta)
        #expect(local.expenses.isEmpty)
        #expect(result.resend == [name])

        // An explicit restore newer than the archive does bring it back.
        _ = CloudSyncMerge.apply(saves: [Self.remote(activeItem, modifiedAt: Date(timeIntervalSince1970: 1_000),
                                                     restoredAt: Date(timeIntervalSince1970: 1_000))],
                                 deletions: [], to: &local, metadata: &meta)
        #expect(local.expenses.map(\.id) == [expense.id])
        #expect(local.deletedExpenses.isEmpty)
    }

    @Test("Server deletions: an active expense moves to Deleted locally, other kinds are removed")
    func remoteDeletions() {
        let category = UserCategory(name: "Food")
        let expense = Self.expense("Bread", 2, category: category.id)
        var dataset = Self.emptyDataset()
        dataset.userCategories = [category]
        dataset.expenses = [expense]
        var meta = CloudSyncMetadata()
        _ = CloudSyncTracker.capture(dataset.items(), metadata: &meta, now: Date())

        let categoryName = CloudSyncRecordKind.category.recordName(key: CloudSyncCoding.uuidKey(category.id))
        let result = CloudSyncMerge.apply(saves: [], deletions: [CloudSyncCoding.uuidKey(expense.id), categoryName],
                                          to: &dataset, metadata: &meta)
        #expect(result.dataChanged)
        #expect(dataset.expenses.isEmpty)
        #expect(dataset.deletedExpenses.map(\.id) == [expense.id])
        #expect(dataset.userCategories.isEmpty)
        #expect(meta.entries[categoryName] == nil)
        // The local Deleted copy is not uploaded, and the category removal is not echoed.
        #expect(CloudSyncTracker.capture(dataset.items(), metadata: &meta, now: Date()).isEmpty)
    }

    // MARK: - Multi-device scenarios

    @Test("Moving an expense to Deleted on one device moves it on the other")
    func deletedPropagates() {
        let cloud = FakeCloud()
        let category = UserCategory(name: "Food")
        let expense = Self.expense("Pizza", 15, category: category.id)
        var a = FakeDevice(name: "A")
        a.data.userCategories = [category]
        a.data.expenses = [expense]
        var b = FakeDevice(name: "B")
        a.sync(cloud); b.sync(cloud)
        #expect(b.data.expenses.map(\.id) == [expense.id])

        a.clock += 10
        a.data.expenses = []
        a.data.deletedExpenses = [ArchivedExpense(from: expense)]
        a.sync(cloud); b.sync(cloud)
        #expect(b.data.expenses.isEmpty)
        #expect(b.data.deletedExpenses.map(\.id) == [expense.id])

        // Permanent delete on B removes it from A's Deleted list.
        b.clock += 10
        b.data.deletedExpenses = []
        b.sync(cloud); a.sync(cloud)
        #expect(a.data.deletedExpenses.isEmpty)
        #expect(cloud.records[CloudSyncCoding.uuidKey(expense.id)] == nil)
    }

    @Test("First sync: existing device uploads, fresh device downloads, settings are not reset")
    func firstSyncDownload() {
        let cloud = FakeCloud()
        let category = UserCategory(name: "Food")
        var a = FakeDevice(name: "A")
        a.data.user = User(currency: .eur, language: .russian)
        a.data.userCategories = [category]
        a.data.expenses = (0..<5).map { Self.expense("E\($0)", Double($0), category: category.id) }
        a.data.monthlySalaries = [MonthlySalary(year: 2026, month: 10, amount: 3_000, currency: .eur)]
        a.sync(cloud)
        #expect(cloud.records.count == 8)

        var b = FakeDevice(name: "B") // fresh install, default settings
        b.sync(cloud)
        #expect(b.data.expenses.count == 5)
        #expect(b.data.user.currency == .eur)
        #expect(b.data.user.language == .russian)
        #expect(b.data.monthlySalaries.count == 1)
        // B uploads nothing back: its data already matches iCloud.
        #expect(b.uploads == 0)
    }

    @Test("First sync of two devices with data merges by id without duplicates or loss")
    func firstSyncMerge() {
        let cloud = FakeCloud()
        let shared = Self.expense("Shared", 10, category: UUID())
        let foodA = UserCategory(name: "Food")
        let foodB = UserCategory(name: "food ")
        var a = FakeDevice(name: "A")
        a.data.userCategories = [foodA]
        a.data.expenses = [Self.expense("A1", 1, category: foodA.id), shared]
        a.data.monthlySalaries = [MonthlySalary(year: 2026, month: 9, amount: 1_000, currency: .usd)]
        var b = FakeDevice(name: "B")
        b.data.userCategories = [foodB]
        b.data.expenses = [Self.expense("B1", 2, category: foodB.id), shared]
        b.data.categoryBudgets = [CategoryBudget(categoryId: foodB.id, amount: 50, isEnabled: true)]
        b.data.monthlySalaries = [MonthlySalary(year: 2026, month: 9, amount: 1_200, currency: .usd)]

        a.sync(cloud); b.sync(cloud); a.sync(cloud); b.sync(cloud)

        for device in [a, b] {
            #expect(Set(device.data.expenses.map(\.title)) == ["A1", "B1", "Shared"])
            #expect(device.data.expenses.count == 3)
            #expect(device.data.userCategories.map(\.id) == [foodA.id]) // same-named categories merged
            #expect(device.data.expenses.allSatisfy { $0.categoryId == foodA.id || $0.id == shared.id })
            #expect(device.data.categoryBudgets.map(\.categoryId) == [foodA.id])
            #expect(device.data.monthlySalaries.count == 1) // one salary per month
        }
        #expect(a.data.items().mapValues(\.hash) == b.data.items().mapValues(\.hash))
    }

    @Test("Concurrent edits to different records both survive; same record converges")
    func concurrentEdits() {
        let cloud = FakeCloud()
        let category = UserCategory(name: "Food")
        let x = Self.expense("X", 1, category: category.id)
        let y = Self.expense("Y", 2, category: category.id)
        var a = FakeDevice(name: "A")
        a.data.userCategories = [category]
        a.data.expenses = [x, y]
        var b = FakeDevice(name: "B")
        a.sync(cloud); b.sync(cloud)

        a.clock += 10; a.data.expenses[0].amount = 11       // A edits X
        b.clock += 20; b.data.expenses[1].amount = 22       // B edits Y
        b.data.expenses[0].title = "X from B"               // and X, later than A
        a.sync(cloud); b.sync(cloud); a.sync(cloud)

        for device in [a, b] {
            let byID = Dictionary(uniqueKeysWithValues: device.data.expenses.map { ($0.id, $0) })
            #expect(byID[y.id]?.amount == 22)
            #expect(byID[x.id]?.title == "X from B") // B's version of X is newer
        }
        #expect(a.data.items().mapValues(\.hash) == b.data.items().mapValues(\.hash))
    }

    // MARK: - Recurring

    @Test("Recurring charges get the same id on every device and the cursor never moves back")
    func recurringDeterminism() throws {
        let bill = RecurringExpense(title: "Gym", amount: 30, categoryId: UUID(), recurrenceType: .monthly,
                                    startDate: Date(timeIntervalSince1970: 1_780_000_000))
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_785_000_000)).addingTimeInterval(3_600)
        #expect(bill.occurrenceExpenseID(for: day) == bill.occurrenceExpenseID(for: day.addingTimeInterval(60)))
        #expect(bill.occurrenceExpenseID(for: day) != bill.occurrenceExpenseID(for: day.addingTimeInterval(86_400 * 31)))

        var advanced = bill
        advanced.lastProcessedDate = day
        var dataset = Self.emptyDataset()
        dataset.recurringExpenses = [advanced]
        var stale = Self.emptyDataset()
        stale.recurringExpenses = [bill]
        let staleItem = try #require(stale.items().values.first { $0.kind == .recurring })
        try dataset.upsert(kind: .recurring, payload: staleItem.payload)
        #expect(dataset.recurringExpenses.first?.lastProcessedDate == day)
    }
}

// MARK: - Fake CloudKit

/// Server with change tags, conflict errors and an ordered change log for incremental fetches.
private final class FakeCloud {
    struct Stored { var record: CloudSyncRemoteRecord; var tag: Int }
    var records: [String: Stored] = [:]
    var log: [(name: String, deleted: Bool)] = []
    private var nextTag = 1

    static func tag(_ fields: Data?) -> Int? { fields.flatMap { Int(String(decoding: $0, as: UTF8.self)) } }

    /// Mirrors CKModifyRecords: a save with a missing/stale tag on an existing record fails
    /// with serverRecordChanged and returns the server copy.
    enum SaveResult { case saved(Data), conflict(CloudSyncRemoteRecord) }

    func save(_ record: CloudSyncRemoteRecord, tag: Int?) -> SaveResult {
        if let existing = records[record.recordName], existing.tag != tag { return .conflict(stamped(existing)) }
        let newTag = nextTag
        nextTag += 1
        records[record.recordName] = Stored(record: record, tag: newTag)
        log.append((record.recordName, false))
        return .saved(Data(String(newTag).utf8))
    }

    func delete(_ name: String) {
        guard records.removeValue(forKey: name) != nil else { return }
        log.append((name, true))
    }

    func stamped(_ stored: Stored) -> CloudSyncRemoteRecord {
        let r = stored.record
        return CloudSyncRemoteRecord(recordName: r.recordName, kind: r.kind, payload: r.payload, modifiedAt: r.modifiedAt,
                                     restoredAt: r.restoredAt, isArchived: r.isArchived,
                                     systemFields: Data(String(stored.tag).utf8), appleAccountHash: nil)
    }
}

/// One device: local data + sync metadata, driven the way CloudSyncController drives CKSyncEngine.
private struct FakeDevice {
    let name: String
    var data = CloudSyncDataset(expenses: [], deletedExpenses: [], userCategories: [], categoryBudgets: [],
                                spendingGoals: [], monthlySalaries: [], recurringExpenses: [], user: User())
    var metadata = CloudSyncMetadata()
    var pending = CloudSyncChanges()
    var cursor = 0
    var clock = Date(timeIntervalSince1970: 10_000)
    var uploads = 0

    init(name: String) { self.name = name }

    mutating func capture() {
        let changes = CloudSyncTracker.capture(data.items(), metadata: &metadata, now: clock)
        pending.saves.formUnion(changes.saves)
        pending.deletes.formUnion(changes.deletes)
        pending.saves.subtract(changes.deletes)
    }

    mutating func apply(_ saves: [CloudSyncRemoteRecord], _ deletions: [String]) {
        capture()
        let result = CloudSyncMerge.apply(saves: saves, deletions: deletions, to: &data, metadata: &metadata)
        pending.saves.subtract(result.settled)
        pending.deletes.subtract(result.settled)
        pending.saves.formUnion(result.resend)
        pending.deletes.formUnion(result.redelete)
        capture()
    }

    mutating func fetch(_ cloud: FakeCloud) {
        let changes = cloud.log[cursor...]
        cursor = cloud.log.count
        var latest: [String: Bool] = [:]
        for change in changes { latest[change.name] = change.deleted }
        let saves = latest.filter { !$0.value }.keys.compactMap { cloud.records[$0].map(cloud.stamped) }
        let deletions = latest.filter { $0.value }.map(\.key)
        apply(saves, deletions)
    }

    mutating func send(_ cloud: FakeCloud) {
        for _ in 0..<3 where !pending.isEmpty {
            let saves = pending.saves, deletes = pending.deletes
            pending = CloudSyncChanges()
            let items = data.items()
            var conflicts: [CloudSyncRemoteRecord] = []
            for name in saves.sorted() {
                guard let item = items[name], let entry = metadata.entries[name] else { continue }
                let record = CloudSyncRemoteRecord(recordName: name, kind: item.kind, payload: item.payload,
                                                   modifiedAt: entry.modifiedAt, restoredAt: entry.restoredAt,
                                                   isArchived: item.isArchived, systemFields: nil, appleAccountHash: nil)
                switch cloud.save(record, tag: FakeCloud.tag(entry.systemFields)) {
                case .saved(let fields):
                    metadata.entries[name]?.systemFields = fields
                    uploads += 1
                case .conflict(let server):
                    conflicts.append(server)
                }
            }
            for name in deletes {
                cloud.delete(name)
                if metadata.entries[name]?.isTombstone == true { metadata.entries[name] = nil }
            }
            if !conflicts.isEmpty { apply(conflicts, []) }
        }
    }

    /// A sync pass: capture local edits, fetch, then send (as on launch / Sync Now).
    mutating func sync(_ cloud: FakeCloud) {
        capture()
        fetch(cloud)
        send(cloud)
        // Our own saves show up in the next fetch; skip them like CKSyncEngine does for unchanged tags.
        cursor = cloud.log.count
    }
}
