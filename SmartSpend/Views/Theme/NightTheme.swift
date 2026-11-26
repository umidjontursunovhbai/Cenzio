import SwiftUI
import UIKit

/// Night Tashkent tokens for the whole app (see DESIGN.md). UI accent is white in dark
/// mode and ink in light mode; warm colors live only inside the drawn city and figures.
enum NightTheme {
    static let ink = Color(red: 5 / 255, green: 7 / 255, blue: 13 / 255)
    static let fg = Color(red: 238 / 255, green: 241 / 255, blue: 246 / 255)
    static let silver = Color(red: 201 / 255, green: 211 / 255, blue: 224 / 255)
    static let body = Color(red: 195 / 255, green: 203 / 255, blue: 218 / 255)
    /// A lit window. City only: windows, lamps, headlight beams.
    static let window = Color(red: 1, green: 200 / 255, blue: 120 / 255)
    /// The taxi body only.
    static let taxi = Color(red: 242 / 255, green: 194 / 255, blue: 48 / 255)

    /// Figures and primary fills: white in dark mode, ink in light mode.
    static func figure(_ scheme: ColorScheme) -> Color { scheme == .dark ? fg : ink }

    static let displayFamily = "Big Shoulders Display"

    /// Big Shoulders Display that follows Dynamic Type.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(displayFamily, size: size, relativeTo: style).weight(weight)
    }

    /// Section headers: 600, 17 pt, sentence case.
    static let sectionFont = display(17, weight: .semibold, relativeTo: .headline)

    /// Large navigation titles in Big Shoulders 800, set once at launch on the appearance
    /// proxy so the native collapse animation keeps working.
    @MainActor
    static func applyNavigationTitleFont() {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: displayFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.heavy],
        ])
        let base = UIFont(descriptor: descriptor, size: 38)
        guard base.familyName == displayFamily else { return }
        let font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: base)
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: font]
    }
}

/// Primary action: a 52 pt capsule, white with ink text in dark mode, ink with white text
/// in light mode.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(dark ? NightTheme.ink : .white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(dark ? NightTheme.fg : NightTheme.ink, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Figures on kerbs

/// Puts a street figure on the top edge of a view (a button, a card), its feet on the edge.
/// Hidden at accessibility text sizes so it never collides with big text.
private struct KerbFigureModifier: ViewModifier {
    let figure: StreetFigure
    let alignment: HorizontalAlignment
    let inset: CGFloat
    let height: CGFloat
    var turned = false

    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.overlay(alignment: Alignment(horizontal: alignment, vertical: .top)) {
            if !typeSize.isAccessibilitySize {
                StreetFigureView(figure: figure, height: height, turned: turned)
                    .padding(alignment == .leading ? .leading : .trailing, inset)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
    }
}

extension View {
    /// A street figure standing on this view's top edge, `inset` points from the given side.
    func kerbFigure(_ figure: StreetFigure, alignment: HorizontalAlignment = .trailing,
                    inset: CGFloat = 28, height: CGFloat = 26, turned: Bool = false) -> some View {
        modifier(KerbFigureModifier(figure: figure, alignment: alignment, inset: inset, height: height, turned: turned))
    }
}

/// A sentence-case section heading in Big Shoulders with a figure standing at its
/// trailing end, feet on the text baseline.
struct StreetSectionHeader: View {
    let title: String
    var figure: StreetFigure?
    /// The figure keeps moving in a lane that fills the rest of the header (Settings).
    var loops = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(NightTheme.sectionFont)
                .foregroundStyle(.secondary)
            if let figure, !typeSize.isAccessibilitySize {
                if loops {
                    StreetLoopView(figure: figure, height: 22)
                        .frame(maxWidth: .infinity)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 1 }
                } else {
                    StreetFigureView(figure: figure, height: 22)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 1 }
                }
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
