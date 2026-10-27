import CloudKit
import Foundation
import os

/// Automatic iCloud sync between a user's devices, built on CKSyncEngine with a custom zone
/// in the private database. One record per item (see `CloudSyncRecordKind`); local changes
/// are detected by diffing against per-record metadata after every save, so every mutation
/// path (UI, voice, MCP/Notion apply, intents) is covered without touching each call site.
@MainActor
final class CloudSyncController: ObservableObject {
    static let containerIdentifier = "iCloud.ai.humblebee.smartspend"
    static let shared = CloudSyncController()

    enum Status: Equatable {
        case checking
        case syncing
        case upToDate
        case noAccount
        case restricted
        case temporarilyUnavailable
        case failed(String)
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var lastSyncedAt: Date?
    /// A record arrived that was written while signed in to SmartSpend with another Apple ID.
    @Published private(set) var accountMismatch = false

    private let logger = Logger(subsystem: "ai.humblebee.smartspend", category: "CloudSync")
    private let defaults: UserDefaults
    private let directory: URL
    private let dataManager: DataManager
    private var engine: CKSyncEngine?
    private var delegateBridge: CloudSyncEngineDelegateBridge?
    private var metadata = CloudSyncMetadata()
    private var debounce: Task<Void, Never>?
    private var activity = 0
    private var lastError: String?
    /// Foreground fetches are throttled; pushes deliver changes in between.
    private var lastForegroundFetch: Date?
    private static let foregroundFetchInterval: TimeInterval = 60
    /// Local edits are batched so a burst of saves becomes one diff and one upload.
    private static let localChangeDelay: Duration = .seconds(5)
    private var accountObserver: NSObjectProtocol?

    private enum Keys {
        static let lastSyncedAt = "cloudSync.lastSyncedAt"
        static let zoneCreated = "cloudSync.zoneCreated"
    }

    /// Unit tests and UI tests run with the app as host; keep them off the network.
    private static var isDisabledForTesting: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] == "1"
    }

    private init(dataManager: DataManager = .shared, defaults: UserDefaults = .standard) {
        self.dataManager = dataManager
        self.defaults = defaults
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudSync", isDirectory: true)
        // Sync is always on; drop the switch an earlier build stored.
        defaults.removeObject(forKey: "cloudSync.enabled")
        lastSyncedAt = defaults.object(forKey: Keys.lastSyncedAt) as? Date
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode(CloudSyncMetadata.self, from: data) {
            metadata = decoded
        }
    }

    // MARK: - Lifecycle

    /// Called once at launch. Safe to call again.
    func start() {
        guard !Self.isDisabledForTesting else { return }
        dataManager.onLocalDataPersisted = { [weak self] in
            Task { @MainActor in self?.localDataDidChange() }
        }
        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.accountDidChange() }
            }
        }
        Task { await startEngineIfPossible() }
    }

    func sceneDidBecomeActive() {
        guard let engine else {
            // iCloud may have become available while the app was in the background.
            Task { await startEngineIfPossible() }
            return
        }
        captureLocalChanges()
        if let lastForegroundFetch, Date().timeIntervalSince(lastForegroundFetch) < Self.foregroundFetchInterval { return }
        lastForegroundFetch = Date()
        Task { try? await engine.fetchChanges() }
    }

    func didReceiveRemoteNotification() async {
        guard let engine else { return }
        lastForegroundFetch = Date()
        try? await engine.fetchChanges()
    }

    /// "Clear all data" is local: forget what this device knew so the clear is not sent as
    /// deletions to the user's other devices. Their data stays in iCloud.
    func localDataWasCleared() {
        debounce?.cancel()
        if let engine {
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        }
        metadata = CloudSyncMetadata()
        saveMetadata()
    }

    /// Account deletion: removes this app's whole zone from the user's iCloud, so every
    /// device sees it as deleted (see `.fetchedDatabaseChanges`). Throws when iCloud is
    /// reachable but the delete could not be sent, so nothing is half deleted.
    func deleteAllCloudData() async throws {
        debounce?.cancel()
        if engine == nil { await startEngineIfPossible() }
        guard let engine else { return } // No iCloud account: nothing is stored there.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: [.deleteZone(CloudSyncRecordMapper.zoneID)])
        try await engine.sendChanges()
        guard !engine.state.pendingDatabaseChanges.contains(.deleteZone(CloudSyncRecordMapper.zoneID)) else {
            throw CKError(.networkFailure)
        }
        defaults.set(false, forKey: Keys.zoneCreated)
        metadata = CloudSyncMetadata()
        saveMetadata()
    }

    // MARK: - Engine

    private func startEngineIfPossible() async {
        guard engine == nil else { return }
        guard await refreshAccountStatus() else { return }
        guard engine == nil else { return }

        let bridge = CloudSyncEngineDelegateBridge(controller: self)
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: bridge
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        delegateBridge = bridge

        if !defaults.bool(forKey: Keys.zoneCreated) {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncRecordMapper.zoneID))])
        }
        // First run uploads everything; later runs upload what changed while the app was closed.
        captureLocalChanges()
        lastForegroundFetch = Date()
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            markSynced()
        } catch {
            fail(error)
        }
    }

    /// The device's iCloud account changed (signed in/out in Settings).
    private func accountDidChange() async {
        if engine == nil {
            await startEngineIfPossible()
        } else if await refreshAccountStatus(), status != .syncing {
            status = lastError.map { .failed($0) } ?? .upToDate
        }
    }

    /// Updates `status` for an unusable account; true when iCloud is available.
    @discardableResult
    private func refreshAccountStatus() async -> Bool {
        do {
            switch try await CKContainer(identifier: Self.containerIdentifier).accountStatus() {
            case .available:
                return true
            case .noAccount: status = .noAccount
            case .restricted: status = .restricted
            case .temporarilyUnavailable, .couldNotDetermine: status = .temporarilyUnavailable
            @unknown default: status = .temporarilyUnavailable
            }
        } catch {
            fail(error)
        }
        return false
    }

    private func localDataDidChange() {
        guard engine != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.localChangeDelay)
            guard !Task.isCancelled else { return }
            self?.captureLocalChanges()
        }
    }

    /// Diffs local data against metadata and queues the differences on the engine.
    private func captureLocalChanges() {
        guard let engine else { return }
        debounce?.cancel()
        let changes = CloudSyncTracker.capture(dataManager.cloudSyncDataset.items(), metadata: &metadata, now: Date())
        guard !changes.isEmpty else { return }
        saveMetadata()
        engine.state.add(pendingRecordZoneChanges:
            changes.saves.map { .saveRecord(CloudSyncRecordMapper.recordID($0)) }
            + changes.deletes.map { .deleteRecord(CloudSyncRecordMapper.recordID($0)) })
    }

    private func queueAllForUpload(_ engine: CKSyncEngine) {
        metadata.resetServerState()
        saveMetadata()
        defaults.set(false, forKey: Keys.zoneCreated)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncRecordMapper.zoneID))])
        let names = dataManager.cloudSyncDataset.items().keys
        engine.state.add(pendingRecordZoneChanges: names.map { .saveRecord(CloudSyncRecordMapper.recordID($0)) })
        captureLocalChanges()
    }

    private var appleAccountHash: String? {
        CloudSyncRecordMapper.appleAccountHash(AppleAccountStore.shared.account?.userID)
    }

    // MARK: - Engine events (called through the delegate bridge)

    fileprivate func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) {
        guard engine === self.engine else { return }
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn, .switchAccounts:
                // Local data is kept and merged into this account's iCloud data.
                accountMismatch = false
                queueAllForUpload(engine)
            case .signOut:
                metadata.resetServerState()
                saveMetadata()
                status = .noAccount
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            if let deletion = changes.deletions.first(where: { $0.zoneID == CloudSyncRecordMapper.zoneID }) {
                if deletion.reason == .deleted {
                    // Only account deletion on another device deletes the zone from code.
                    localDataWasCleared()
                    dataManager.clearAllData()
                    AppleAccountStore.shared.forgetAccount()
                } else {
                    // Purged in iCloud settings or reset: this device still has the data,
                    // and sync is always on, so upload it again.
                    queueAllForUpload(engine)
                }
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetched(changes)

        case .sentDatabaseChanges(let sent):
            if sent.savedZones.contains(where: { $0.zoneID == CloudSyncRecordMapper.zoneID }) {
                defaults.set(true, forKey: Keys.zoneCreated)
            }
            for failure in sent.failedZoneSaves {
                logger.error("Zone save failed: \(failure.error.localizedDescription, privacy: .public)")
                lastError = Self.message(for: failure.error)
            }

        case .sentRecordZoneChanges(let sent):
            handleSent(sent, engine: engine)

        case .willFetchChanges, .willSendChanges:
            activity += 1
            status = .syncing

        case .didFetchChanges, .didSendChanges:
            activity = max(0, activity - 1)
            if activity == 0 {
                if let lastError { status = .failed(lastError) } else { markSynced() }
            }

        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error {
                if error.code == .zoneNotFound || error.code == .userDeletedZone {
                    queueAllForUpload(engine)
                } else {
                    lastError = Self.message(for: error)
                }
            }

        case .willFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    fileprivate func nextBatch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === self.engine else { return nil }
        captureLocalChanges()
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        let items = dataManager.cloudSyncDataset.items()
        let entries = metadata.entries
        // A value deleted after it was queued has nothing to send; its deletion is queued separately.
        let stale = pending.filter {
            if case .saveRecord(let id) = $0 { return items[id.recordName] == nil || entries[id.recordName] == nil }
            return false
        }
        if !stale.isEmpty { engine.state.remove(pendingRecordZoneChanges: stale) }
        let accountHash = appleAccountHash
        let sendable = pending.filter { !stale.contains($0) }
        // Records are built lazily: the engine only asks for as many as fit in one request.
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sendable) { id in
            guard let item = items[id.recordName], let entry = entries[id.recordName] else { return nil }
            return CloudSyncRecordMapper.record(for: item, entry: entry, appleAccountHash: accountHash)
        }
    }

    // MARK: - Applying server changes

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        // Record unsaved local edits first so they are compared, not overwritten.
        captureLocalChanges()
        let zone = CloudSyncRecordMapper.zoneID
        let saves = changes.modifications.compactMap { modification -> CloudSyncRemoteRecord? in
            guard modification.record.recordID.zoneID == zone else { return nil }
            return CloudSyncRecordMapper.remoteRecord(from: modification.record)
        }
        let deletions = changes.deletions.filter { $0.recordID.zoneID == zone }.map(\.recordID.recordName)
        apply(saves: saves, deletions: deletions)
    }

    private func apply(saves: [CloudSyncRemoteRecord], deletions: [String]) {
        guard !saves.isEmpty || !deletions.isEmpty else { return }
        if let local = appleAccountHash,
           saves.contains(where: { $0.appleAccountHash != nil && $0.appleAccountHash != local }) {
            accountMismatch = true
        }
        var dataset = dataManager.cloudSyncDataset
        let result = CloudSyncMerge.apply(saves: saves, deletions: deletions, to: &dataset, metadata: &metadata)
        if result.dataChanged { dataManager.applyCloudSyncDataset(dataset) }
        saveMetadata()
        if let engine {
            let settled = result.settled.flatMap { name -> [CKSyncEngine.PendingRecordZoneChange] in
                let id = CloudSyncRecordMapper.recordID(name)
                return [.saveRecord(id), .deleteRecord(id)]
            }
            if !settled.isEmpty { engine.state.remove(pendingRecordZoneChanges: settled) }
            let ids = result.resend.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CloudSyncRecordMapper.recordID($0)) }
                + result.redelete.map { .deleteRecord(CloudSyncRecordMapper.recordID($0)) }
            if !ids.isEmpty { engine.state.add(pendingRecordZoneChanges: ids) }
        }
        // Derived local changes (merged categories, a newer recurring cursor) upload now.
        captureLocalChanges()
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        for record in sent.savedRecords {
            let name = record.recordID.recordName
            guard metadata.entries[name] != nil else { continue }
            metadata.entries[name]?.systemFields = CloudSyncRecordMapper.encodeSystemFields(record)
        }
        for id in sent.deletedRecordIDs where metadata.entries[id.recordName]?.isTombstone == true {
            metadata.entries[id.recordName] = nil
        }
        for (id, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem, metadata.entries[id.recordName]?.isTombstone == true {
                metadata.entries[id.recordName] = nil
            } else {
                logger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        var conflicts: [CloudSyncRemoteRecord] = []
        var retry: [CKSyncEngine.PendingRecordZoneChange] = []
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, let remote = CloudSyncRecordMapper.remoteRecord(from: server) {
                    conflicts.append(remote)
                }
            case .zoneNotFound:
                defaults.set(false, forKey: Keys.zoneCreated)
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: CloudSyncRecordMapper.zoneID))])
                metadata.entries[id.recordName]?.systemFields = nil
                retry.append(.saveRecord(id))
            case .unknownItem:
                metadata.entries[id.recordName]?.systemFields = nil
                retry.append(.saveRecord(id))
            case .quotaExceeded:
                lastError = "icloud_sync_error_quota".localized
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited, .batchRequestFailed:
                break // retried by the engine
            default:
                logger.error("Save failed: \(failure.error.localizedDescription, privacy: .public)")
                lastError = Self.message(for: failure.error)
            }
        }
        saveMetadata()
        if !retry.isEmpty { engine.state.add(pendingRecordZoneChanges: retry) }
        // Last-modified-wins against the server copy; a local winner is resent on its change tag.
        if !conflicts.isEmpty { apply(saves: conflicts, deletions: []) }
    }

    // MARK: - Status

    private func markSynced() {
        lastError = nil
        let now = Date()
        lastSyncedAt = now
        defaults.set(now, forKey: Keys.lastSyncedAt)
        status = .upToDate
    }

    private func fail(_ error: Error) {
        if let ckError = error as? CKError, ckError.code == .notAuthenticated {
            status = .noAccount
            return
        }
        lastError = Self.message(for: error)
        status = .failed(lastError ?? error.localizedDescription)
    }

    static func message(for error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        switch ckError.code {
        case .notAuthenticated: return "icloud_sync_status_no_account".localized
        case .networkUnavailable, .networkFailure: return "icloud_sync_error_network".localized
        case .quotaExceeded: return "icloud_sync_error_quota".localized
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "icloud_sync_error_busy".localized
        case .permissionFailure, .badContainer, .missingEntitlement: return "icloud_sync_error_not_configured".localized
        default: return ckError.localizedDescription
        }
    }

    // MARK: - Persistence

    private var metadataURL: URL { directory.appendingPathComponent("metadata.json") }
    private var stateURL: URL { directory.appendingPathComponent("engine-state.json") }

    private func saveMetadata() {
        write(try? JSONEncoder().encode(metadata), to: metadataURL)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        write(try? JSONEncoder().encode(state), to: stateURL)
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("Could not save sync state: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// CKSyncEngine holds its delegate weakly and calls it off the main actor; this hops to the controller.
private final class CloudSyncEngineDelegateBridge: CKSyncEngineDelegate, @unchecked Sendable {
    private weak var controller: CloudSyncController?

    @MainActor init(controller: CloudSyncController) { self.controller = controller }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { [weak controller] in controller?.handle(event, engine: syncEngine) }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let controller else { return nil }
        return await controller.nextBatch(context, engine: syncEngine)
    }
}
