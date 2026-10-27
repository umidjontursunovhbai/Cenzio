import Foundation
import Testing
@testable import SmartSpend

@Suite("Voice expense review safety")
struct VoiceExpenseTests {
    @Test("Speech failures give actionable safe feedback instead of hiding the cause")
    @MainActor
    func speechFeedback() {
        let missing = SpeechRecognitionFeedback.message(for: NSError(domain: "kLSRErrorDomain", code: 102))
        let noSpeech = SpeechRecognitionFeedback.message(for: NSError(domain: "kAFAssistantErrorDomain", code: 1110))
        let stopped = SpeechRecognitionFeedback.message(for: NSError(domain: "kAFAssistantErrorDomain", code: 1101))
        #expect(missing != noSpeech)
        #expect(stopped != missing)
        #expect(noSpeech == SpeechRecognitionFeedback.noSpeech)
        let safe = SpeechRecognitionFeedback.message(for: NSError(domain: "unknown", code: 999, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TRANSCRIPT"]))
        #expect(!safe.contains("PRIVATE_TRANSCRIPT"))
    }

    private func draft(_ changes: [String: Any] = [:]) throws -> VoiceTransactionDraft {
        var object: [String: Any] = [
            "kind": "expense", "amount_decimal": "15800", "currency": "UZS", "title": "Taxi",
            "category_id": "11111111-1111-4111-8111-111111111111", "date_expression": "вчера",
            "account_reference": NSNull(), "counterparty": NSNull(), "ambiguous_fields": []
        ]
        object.merge(changes) { _, new in new }
        return try JSONDecoder().decode(VoiceTransactionDraft.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Malformed or ambiguous monetary representations are never coerced", arguments: ["-15", "0", "NaN", "Infinity", "1e4", "15,800", "01", "15800\n", "1000000000000", "1.1234567"])
    func rejectMoney(_ value: String) {
        #expect(VoiceDraftValidation.amount(value) == nil)
    }

    @Test("Positive decimal amounts keep their exact value")
    func money() {
        #expect(VoiceDraftValidation.amount("15800") == 15800)
        #expect(VoiceDraftValidation.amount("12.5") == 12.5)
        #expect(VoiceDraftValidation.amount(nil) == nil)
    }

    @Test("Relative dates use the user's reference day and timezone")
    func dates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tashkent"))
        let reference = try #require(ISO8601DateFormatter().date(from: "2026-10-20T00:30:00Z"))
        for phrase in ["Yesterday", "вчера"] {
            let date = try #require(VoiceDraftValidation.resolveDate(phrase, reference: reference, calendar: calendar))
            #expect(calendar.component(.day, from: date) == 19)
        }
        #expect(VoiceDraftValidation.resolveDate("2026-02-30", reference: reference, calendar: calendar) == nil)
        #expect(VoiceDraftValidation.resolveDate("last Friday", reference: reference, calendar: calendar) == nil)
        #expect(VoiceDraftValidation.resolveDate(nil, reference: reference, calendar: calendar) == nil)
        let exact = try #require(VoiceDraftValidation.resolveDate("2026-10-17", reference: reference, calendar: calendar))
        #expect(calendar.component(.day, from: exact) == 17)
        let resolvedDraft = try draft(["date_expression": "2026-10-17"])
        let preview = VoiceExpensePrefill(draft: resolvedDraft, referenceDate: reference, calendar: calendar)
        #expect(calendar.component(.day, from: preview.date) == 17)
        #expect(!preview.requiresDateConfirmation)
    }

    @Test("Missing amounts and unknown dates need explicit input, never guessed values")
    func missing() throws {
        let item = try draft(["amount_decimal": NSNull(), "date_expression": "last Friday", "category_id": NSNull()])
        let fill = VoiceExpensePrefill(draft: item, referenceDate: Date())
        #expect(fill.amount == nil && fill.categoryID == nil && fill.requiresDateConfirmation)
        let ambiguous = try draft(["ambiguous_fields": ["amount"]])
        #expect(VoiceExpensePrefill(draft: ambiguous, referenceDate: Date()).amount == nil)
    }

    @Test("Loans, card references, counterparties and foreign currency are not relabeled as expenses")
    func unsupported() throws {
        #expect(try draft().canReviewAsExpense(currency: "UZS"))
        let scenarios: [[String: Any]] = [["kind": "loan_received"], ["kind": "income"], ["currency": "USD"], ["account_reference": "Visa"], ["counterparty": "Alice"]]
        for changes in scenarios {
            #expect(try !draft(changes).canReviewAsExpense(currency: "UZS"))
        }
    }

    @Test("A reviewed draft is durable and repeated Save does not duplicate it")
    @MainActor
    func persistence() throws {
        let suite = "SmartSpendTests.Voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        let category = UserCategory(name: "Transport")
        manager.userCategories = [category]
        manager.updateCurrency(.uzs)
        let expense = Expense(title: "Taxi", amount: 15800, categoryId: category.id)
        try manager.addReviewedVoiceExpense(expense, currency: "UZS")
        try manager.addReviewedVoiceExpense(expense, currency: "UZS")
        #expect(manager.expenses == [expense])
        let reopened = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(reopened.expenses == [expense])
        #expect(throws: VoiceExpenseSaveError.self) { try manager.addReviewedVoiceExpense(expense, currency: "USD") }
    }

    @Test("A failed local flush leaves the draft unsaved and original records intact")
    @MainActor
    func storageFailure() throws {
        let suite = "SmartSpendTests.VoiceFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults), mcpStorageSync: { false })
        let category = UserCategory(name: "Food")
        manager.userCategories = [category]
        manager.updateCurrency(.uzs)
        manager.addExpensesBatch([])
        let expense = Expense(title: "Lunch", amount: 35000, categoryId: category.id)
        #expect(throws: VoiceExpenseSaveError.self) { try manager.addReviewedVoiceExpense(expense, currency: "UZS") }
        #expect(manager.expenses.isEmpty)
        let reopened = DataManager(defaults: defaults, activityManager: GamificationManager(defaults: defaults))
        #expect(reopened.expenses.isEmpty)
    }
}
