import CloudKit
import Foundation

/// Remote on/off switches read from the CloudKit public database, so a feature can be
/// hidden or shown without an app update. The owner flips them in CloudKit Console:
/// record type `AppConfig`, record name `features`, field `voiceEnabled` (1 = on, 0 = off).
@MainActor
final class FeatureFlags: ObservableObject {
    static let shared = FeatureFlags()

    static let recordType = "AppConfig"
    static let recordName = "features"
    nonisolated static let voiceField = "voiceEnabled"
    static let voiceCacheKey = "featureFlags.voiceEnabled"

    /// Last known value. Off until the switch has been read at least once.
    @Published private(set) var voiceEnabled: Bool

    private let defaults: UserDefaults
    private var isRefreshing = false
    private var isPinned = false

    init(defaults: UserDefaults = UserDefaults(suiteName: "group.ai.humblebee.smartspend") ?? .standard) {
        self.defaults = defaults
        #if DEBUG
        if ProcessInfo.processInfo.environment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] == "1" {
            voiceEnabled = true
            isPinned = true
            return
        }
        #endif
        voiceEnabled = defaults.bool(forKey: Self.voiceCacheKey)
    }

    /// Reads the switch from CloudKit. On any error the cached value stays as is.
    func refresh() {
        guard !isRefreshing, !isPinned else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            let database = CKContainer(identifier: CloudSyncController.containerIdentifier).publicCloudDatabase
            let id = CKRecord.ID(recordName: Self.recordName)
            guard let record = try? await database.record(for: id),
                  let value = Self.voiceValue(from: record) else { return }
            apply(voiceEnabled: value)
        }
    }

    func apply(voiceEnabled value: Bool) {
        defaults.set(value, forKey: Self.voiceCacheKey)
        if voiceEnabled != value { voiceEnabled = value }
    }

    nonisolated static func voiceValue(from record: CKRecord) -> Bool? {
        (record[voiceField] as? NSNumber)?.boolValue
    }
}
