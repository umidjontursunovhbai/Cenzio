import SwiftUI
import UIKit

/// Light, dark or follow the system, chosen in Settings.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance.mode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "appearance_system".localized
        case .light: return "appearance_light".localized
        case .dark: return "appearance_dark".localized
        }
    }

    private var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Set on the window rather than with `preferredColorScheme`, so sheets follow too and
    /// "System" really returns to the system setting.
    func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
