import Foundation
import Testing
@testable import SmartSpend

@Suite("Inline GPT expense handoff")
@MainActor
struct VoiceAIIntegrationTests {
    @Test("Voice capture uses English even after a previous Russian preference")
    func englishOnly() throws {
        let suite = "SmartSpendTests.EnglishOnly.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru-RU", forKey: "voice.recognitionLocale")
        _ = InlineVoiceExpenseController(defaults: defaults)
        #expect(InlineVoiceExpenseController.recognitionLocale == "en-US")
    }
    private func response(title: String = "AI-selected item", category: String? = nil, kind: String = "expense") -> VoiceDraftResponse {
        VoiceDraftResponse(transactions: [VoiceTransactionDraft(kind: kind, amountDecimal: "6000", currency: "UZS", title: title, categoryID: category, dateExpression: "yesterday", accountReference: nil, counterparty: nil, ambiguousFields: [])], unresolvedFields: [], requiresReview: true, saved: false)
    }

    @Test("No model call is made before consent; then exact transcript goes to AI")
    func consentAndHandoff() async throws {
        let suite = "SmartSpendTests.AI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var received: String?
        let expected = VoiceDraftResponse(transactions: [VoiceTransactionDraft(kind: "expense", amountDecimal: "6000", currency: DataManager.shared.user.currency.rawValue, title: "AI-selected item", categoryID: nil, dateExpression: "yesterday", accountReference: nil, counterparty: nil, ambiguousFields: [])], unresolvedFields: [], requiresReview: true, saved: false)
        let controller = InlineVoiceExpenseController(defaults: defaults) { text, _, _, _, _ in
            received = text
            return expected
        }
        controller.prepareRecognizedText("I bought 2 kilo potato yesterday for 6000")
        #expect(controller.needsAIConsent)
        #expect(received == nil)
        controller.allowAI()
        for _ in 0..<100 where controller.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(received == "I bought 2 kilo potato yesterday for 6000")
        // Deliberately unlike any keyword-derived title: proves output comes from AI.
        #expect(controller.prefill?.title == "AI-selected item")
        #expect(controller.prefill?.amount == 6000)
    }

    @Test("AI failure preserves text and never silently uses local parsing")
    func noFallback() async throws {
        let suite = "SmartSpendTests.AIFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "voice.gpt6luna.textConsent.v1")
        let controller = InlineVoiceExpenseController(defaults: defaults) { _, _, _, _, _ in throw VoiceServiceError.provider }
        controller.prepareRecognizedText("for bus i spend 2500 today")
        for _ in 0..<100 where controller.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.prefill == nil)
        #expect(controller.canRetry)
        #expect(controller.transcript == "for bus i spend 2500 today")
    }

    @Test("Review opens directly and dismissal never brings back a ready popup")
    func directReviewFlow() async throws {
        let suite = "SmartSpendTests.DirectReview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "voice.gpt6luna.textConsent.v1")
        func draft() -> VoiceTransactionDraft {
            VoiceTransactionDraft(kind: "expense", amountDecimal: "2500", currency: DataManager.shared.user.currency.rawValue, title: "Bus", categoryID: nil, dateExpression: "2026-10-20", accountReference: nil, counterparty: nil, ambiguousFields: [])
        }
        let controller = InlineVoiceExpenseController(defaults: defaults) { _, _, _, _, _ in
            VoiceDraftResponse(transactions: [draft(), draft()], unresolvedFields: [], requiresReview: true, saved: false)
        }
        controller.prepareRecognizedText("Two bus expenses")
        for _ in 0..<100 where controller.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.prefill != nil)
        #expect(!controller.isVisible)
        controller.didSave()
        #expect(controller.prefill == nil)
        #expect(!controller.isVisible)
        controller.reviewDidDismiss()
        #expect(controller.prefill != nil)
        #expect(controller.remainingCount == 1)
        #expect(!controller.isVisible)
        // Dismissing without saving cancels the remaining review instead of showing a popup.
        controller.prefill = nil
        controller.reviewDidDismiss()
        #expect(!controller.isVisible)
        #expect(controller.remainingCount == 0)
        #expect(controller.prefill == nil)
    }

    @Test("Only existing model-selected categories and supported expenses reach review")
    func validation() throws {
        let groceries = UserCategory(name: "Groceries")
        let accepted = try VoiceAIReviewBatch.prefills(response: response(title: "2kg potato", category: groceries.id.uuidString), categories: [groceries], currency: "UZS", reference: Date())
        #expect(accepted.first?.categoryID == groceries.id)
        #expect(throws: VoiceServiceError.self) {
            try VoiceAIReviewBatch.prefills(response: response(category: UUID().uuidString), categories: [groceries], currency: "UZS", reference: Date())
        }
        #expect(try VoiceAIReviewBatch.prefills(response: response(kind: "income"), categories: [], currency: "UZS", reference: Date()).isEmpty)
    }

    @Test("Development credential import is bound to the configured server")
    func provisioning() throws {
        #if DEBUG
        let token = String(repeating: "a", count: 43)
        let valid = try JSONSerialization.data(withJSONObject: ["server": VoiceConnectionStore.defaultServer, "token": token])
        #expect(try VoiceDevelopmentProvisioning.decode(valid).token == token)
        let evil = try JSONSerialization.data(withJSONObject: ["server": "https://another.ts.net", "token": token])
        #expect(throws: VoiceServiceError.self) { try VoiceDevelopmentProvisioning.decode(evil) }
        #endif
    }
}
