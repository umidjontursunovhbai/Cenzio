//
//  AppLanguage.swift
//  SmartSpend
//

import Foundation

/// The language picked inside the app (Settings > Language), or nil to follow the iPhone.
/// `.localized` reads strings from this language's `.lproj` bundle, so a change shows at once
/// once the root view redraws (see `AppRootView`, which keys the view tree on `storageKey`).
enum AppLanguage {
    static let storageKey = "appLanguage"
    static let defaults = UserDefaults(suiteName: "group.ai.humblebee.smartspend") ?? .standard

    /// The language the user picked in the app; nil means "same as iPhone".
    static var override: Language? {
        get { defaults.string(forKey: storageKey).flatMap(Language.init(rawValue:)) }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: storageKey)
                // System text (alerts, permission prompts) follows from the next launch.
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: storageKey)
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
            cachedBundle = nil
        }
    }

    /// The language the app's text is shown in right now.
    static var current: Language {
        if let override { return override }
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Language(rawValue: String(code.prefix(2))) ?? .english
    }

    /// The bundle `.localized` reads from.
    static var bundle: Bundle {
        if let cachedBundle { return cachedBundle }
        var resolved = Bundle.main
        if let override,
           let path = Bundle.main.path(forResource: override.rawValue, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        }
        cachedBundle = resolved
        return resolved
    }

    nonisolated(unsafe) private static var cachedBundle: Bundle?
}
