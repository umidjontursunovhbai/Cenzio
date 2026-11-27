import Foundation

/// A language the app's own text can be shown in.
enum Language: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case russian = "ru"
    case uzbek = "uz"

    var id: String { rawValue }

    /// The language's name in that language, e.g. "Русский".
    var name: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        case .uzbek: return "O‘zbekcha"
        }
    }

    var locale: Locale {
        return Locale(identifier: rawValue)
    }

    var englishName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .uzbek: return "Uzbek"
        }
    }
}
