import Foundation

struct VoiceDraftResponse: Decodable {
    let transactions: [VoiceTransactionDraft]
    let unresolvedFields: [String]
    let requiresReview: Bool
    let saved: Bool

    enum CodingKeys: String, CodingKey {
        case transactions, saved
        case unresolvedFields = "unresolved_fields"
        case requiresReview = "requires_review"
    }
}

struct VoiceTransactionDraft: Decodable, Identifiable {
    let id = UUID()
    let kind: String
    let amountDecimal: String?
    let currency: String?
    let title: String?
    let categoryID: String?
    let dateExpression: String?
    let accountReference: String?
    let counterparty: String?
    let ambiguousFields: [String]

    enum CodingKeys: String, CodingKey {
        case kind, currency, title, counterparty
        case amountDecimal = "amount_decimal"
        case categoryID = "category_id"
        case dateExpression = "date_expression"
        case accountReference = "account_reference"
        case ambiguousFields = "ambiguous_fields"
    }

    func canReviewAsExpense(currency ledgerCurrency: String) -> Bool {
        kind == "expense" && currency == ledgerCurrency && accountReference == nil && counterparty == nil
    }
}

struct VoiceExpensePrefill: Identifiable {
    let id: UUID
    let title: String
    let currency: String?
    let amount: Double?
    let categoryID: UUID?
    let date: Date
    let dateExpression: String?
    let requiresDateConfirmation: Bool

    init(draft: VoiceTransactionDraft, referenceDate: Date, calendar: Calendar = .current) {
        id = draft.id
        title = draft.title ?? ""
        currency = draft.currency
        // Any declared ambiguity requires the owner to enter the amount again.
        amount = draft.ambiguousFields.isEmpty ? VoiceDraftValidation.amount(draft.amountDecimal) : nil
        categoryID = draft.categoryID.flatMap(UUID.init(uuidString:))
        let resolved = VoiceDraftValidation.resolveDate(draft.dateExpression, reference: referenceDate, calendar: calendar)
        date = resolved ?? referenceDate
        dateExpression = draft.dateExpression
        requiresDateConfirmation = resolved == nil || !draft.ambiguousFields.isEmpty
    }
}

enum VoiceExpenseSaveError: LocalizedError {
    case invalidExpense, storageFailure
    var errorDescription: String? {
        switch self {
        case .invalidExpense: return "The expense changed or is incomplete. Check its amount, currency and category before saving."
        case .storageFailure: return "The expense could not be saved on this iPhone. Your draft is still here; please try again."
        }
    }
}

enum VoiceDraftValidation {
    static func amount(_ text: String?) -> Double? {
        guard let text,
              let matched = text.range(of: #"^(0|[1-9][0-9]{0,11})(\.[0-9]{1,6})?$"#, options: .regularExpression),
              matched.lowerBound == text.startIndex, matched.upperBound == text.endIndex,
              let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0, decimal < 1_000_000_000_000,
              text.filter({ $0.isNumber }).drop(while: { $0 == "0" }).count <= 15 else { return nil }
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        return value.isFinite ? value : nil
    }

    static func resolveDate(_ phrase: String?, reference: Date, calendar: Calendar = .current) -> Date? {
        guard let phrase else { return nil }
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offsets = ["today": 0, "сегодня": 0, "yesterday": -1, "вчера": -1,
                       "the day before yesterday": -2, "day before yesterday": -2, "позавчера": -2]
        if let offset = offsets[normalized] {
            return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference))
        }
        guard normalized.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        formatter.calendar = gregorian
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: normalized), formatter.string(from: date) == normalized else { return nil }
        return date
    }
}
