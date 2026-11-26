import Foundation

struct User: Codable {
    var currency: Currency
    var language: Language
    /// Small JPEG (about 256 px) the user picked in Account. Lives with the rest of the
    /// data and syncs through the user's iCloud in the Settings record. Nil: initials.
    var photo: Data?

    init(currency: Currency = .usd, language: Language = .english, photo: Data? = nil) {
        self.currency = currency
        self.language = language
        self.photo = photo
    }
}
