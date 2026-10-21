import Foundation
import Testing
@testable import SmartSpend

@Suite("Consumer integration safety")
struct IntegrationConnectionTests {
    @MainActor @Test("Clear all local data invalidates in-flight bootstrap and enrollment", arguments: [true, false])
    func clearDuringConnection(bootstrap: Bool) async throws {
        let suite = "SmartSpend.integration-reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sync-reset-\(UUID().uuidString).json")
        let gate = IntegrationResponseGate()
        let controller = ExpenseSyncController(dataManager: manager, stateURL: file, transport: { _, _, _, _ in
            await gate.pause()
        })
        let connecting = Task {
            if bootstrap {
                await controller.connect(server: "https://example.com", token: String(repeating: "x", count: 40), bootstrap: true)
            } else {
                do {
                    try await controller.prepareConnection()
                    Issue.record("An enrollment invalidated by Clear all data unexpectedly completed")
                } catch is CancellationError { }
                catch { Issue.record("Expected cancellation after the local reset") }
            }
        }
        await gate.waitUntilPaused()
        controller.clearLocalConnection()
        await gate.finish()
        await connecting.value
        #expect(!controller.connected)
        #expect(controller.state == nil)
        #expect(!controller.isBusy)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await gate.requests == 1)
    }

    @Test("Notion preview dates use the ledger time zone, not the UTC day")
    func notionPreviewDate() {
        #expect(ExistingNotionPreviewDate.label("2026-10-20T19:00:00.000Z", timeZone: "Asia/Tashkent", locale: Locale(identifier: "en_US")) == "Oct 21, 2026")
        #expect(ExistingNotionPreviewDate.label("2026-10-20T19:00:00Z", timeZone: "Asia/Tashkent", locale: Locale(identifier: "en_US")) == "Oct 21, 2026")
    }

    @Test("Existing Notion mapping offers only compatible dynamic columns")
    func notionMappingColumns() throws {
        let json = #"{"id":"test","title":"Expenses","schema":{"Purchase":{"type":"title"},"Paid":{"type":"number"},"When":{"type":"date"},"Kind":{"type":"select","options":["Food","Travel"]},"Formula":{"type":"formula"}}}"#
        let source = try JSONDecoder().decode(ExistingNotionSource.self, from: Data(json.utf8))
        #expect(source.fields(of: ["title"]) == ["Purchase"])
        #expect(source.fields(of: ["number"]) == ["Paid"])
        #expect(source.fields(of: ["select", "rich_text"]) == ["Kind"])
        #expect(source.schema["Kind"]?.options == ["Food", "Travel"])
    }

    @Test("Authenticated requests cannot move to another port or embedded user")
    func requestOrigin() async throws {
        let credential = ExpenseSyncCredential(server: URL(string: "https://example.com:10000")!, token: "unit-test")
        for path in ["https://example.com:444/v1/sync/context", "https://user@example.com:10000/v1/sync/context"] {
            do {
                _ = try await ExpenseSyncAPI.request(credential, path: path)
                Issue.record("An unsafe request origin was accepted")
            } catch {
                #expect(error as? ExpenseSyncError == .invalidServer)
            }
        }
    }

    @Test("Old credentials remain readable without granting installation renewal")
    func legacyCredential() throws {
        let credential = try JSONDecoder().decode(ExpenseSyncCredential.self,
            from: Data(#"{"server":"https://example.com","token":"test"}"#.utf8))
        #expect(credential.deviceEnrolled == nil)
        #expect(credential.expiresAt == nil)
    }

    @Test("Notion consent opens only the provider authorization endpoint")
    func notionAuthorization() throws {
        let valid = "https://api.notion.com/v1/oauth/authorize?client_id=test&state=test"
        #expect(try ExpenseSyncAPI.authorizationURL(valid, provider: .notion).host == "api.notion.com")
        for text in ["http://api.notion.com/v1/oauth/authorize", "https://api.notion.com.evil.example/v1/oauth/authorize",
                     "https://user@api.notion.com/v1/oauth/authorize", "https://api.notion.com/v1/search",
                     "https://api.notion.com:444/v1/oauth/authorize"] {
            #expect(throws: ExpenseSyncError.self) { try ExpenseSyncAPI.authorizationURL(text, provider: .notion) }
        }
    }

    @Test("Unconfigured providers are not treated as available")
    func capabilities() throws {
        let values = try JSONDecoder().decode(ExpenseSyncCapabilities.self,
            from: Data(#"{"deviceEnrollment":false,"google":true,"notion":false}"#.utf8))
        #expect(!values.deviceEnrollment)
        #expect(values.supports(.google))
        #expect(!values.supports(.notion))
    }

    @Test("Provider status supports Notion page selection without claiming connection")
    func pageSelectionStatus() throws {
        let status = try JSONDecoder().decode(ExpenseSyncProviderStatus.self,
            from: Data(#"{"connected":false,"pending":false,"needsSelection":true,"configured":true}"#.utf8))
        #expect(!status.connected)
        #expect(status.needsSelection == true)
        #expect(status.spreadsheetURL == nil)
    }
}

private actor IntegrationResponseGate {
    private var response: CheckedContinuation<Data, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var requests = 0
    func pause() async -> Data {
        requests += 1
        return await withCheckedContinuation { continuation in
            response = continuation
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilPaused() async {
        if response != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() {
        response?.resume(returning: Data("{}".utf8))
        response = nil
    }
}
