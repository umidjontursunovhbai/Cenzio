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
    /// How far right a looping figure goes, as a share of the screen width.
    var reach: CGFloat = 0.55
    var lamp = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(NightTheme.sectionFont)
                .foregroundStyle(.secondary)
            if let figure, !typeSize.isAccessibilitySize {
                if loops {
                    StreetLoopView(figure: figure, height: 22, reach: reach, lamp: lamp)
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

// MARK: - Dashboard surfaces (night street)

extension NightTheme {
    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// Secondary text: silver at night, the system secondary label by day.
    static let secondaryLabel = dynamic(dark: UIColor(silver), light: .secondaryLabel)
    /// UI accent: white at night, ink by day.
    static let accent = dynamic(dark: UIColor(fg), light: UIColor(ink))
    /// White glass group fill and its edge.
    static let glassFill = dynamic(dark: UIColor(white: 1, alpha: 0.07), light: .secondarySystemGroupedBackground)
    static let glassLine = dynamic(dark: UIColor(white: 1, alpha: 0.10), light: UIColor(white: 0, alpha: 0.06))
    /// Hairline between rows and around the metric trio.
    static let hair = dynamic(dark: UIColor(fg).withAlphaComponent(0.14), light: .separator)
    /// Tile behind a row icon and empty meter tracks.
    static let iconFill = dynamic(dark: UIColor(white: 1, alpha: 0.09), light: UIColor(white: 0, alpha: 0.05))
    static let track = dynamic(dark: UIColor(white: 1, alpha: 0.08), light: UIColor(white: 0, alpha: 0.07))

    /// Distance from the top of a Big Shoulders text line to its cap line, so a figure can
    /// stand on the letters.
    static func capDrop(_ size: CGFloat, weight: UIFont.Weight = .heavy) -> CGFloat {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: displayFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        let font = UIFont(descriptor: descriptor, size: size)
        return max(0, font.ascender - font.capHeight)
    }
}

/// Page ground: one flat ink color at night (no lighter area at the top, owner 2026-11-26),
/// the grouped system background by day.
struct NightGround: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? NightTheme.ink : Color(.systemGroupedBackground))
            .ignoresSafeArea()
    }
}

extension View {
    /// A white glass group (dashboard sections): 22 pt corners, hairline edge.
    func nightGroup() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return frame(maxWidth: .infinity, alignment: .leading)
            .background(NightTheme.glassFill, in: shape)
            .overlay(shape.stroke(NightTheme.glassLine, lineWidth: 1))
    }

    /// A street figure just past the trailing end of this Big Shoulders text, centered on its
    /// line. Hidden at accessibility text sizes.
    func capFigure(_ figure: StreetFigure?, fontSize: CGFloat, relativeTo style: Font.TextStyle,
                   weight: UIFont.Weight = .heavy, height: CGFloat = 22, gap: CGFloat = 8,
                   paces: Bool = false) -> some View {
        modifier(CapFigureModifier(figure: figure, fontSize: fontSize, style: style, weight: weight, height: height, gap: gap, paces: paces))
    }
}

private struct CapFigureModifier: ViewModifier {
    let figure: StreetFigure?
    let weight: UIFont.Weight
    let height: CGFloat
    let gap: CGFloat
    let paces: Bool
    @ScaledMetric private var size: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    init(figure: StreetFigure?, fontSize: CGFloat, style: Font.TextStyle, weight: UIFont.Weight, height: CGFloat, gap: CGFloat, paces: Bool) {
        self.figure = figure
        self.paces = paces
        self.weight = weight
        self.height = height
        self.gap = gap
        _size = ScaledMetric(wrappedValue: fontSize, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            // Right of the text, centered on its line. Placed with an offset, not alignment
            // guides: SwiftUI ignores explicit guides on a view inside an `if` in the overlay.
            if let figure, !typeSize.isAccessibilitySize {
                let width = figure.box.width * height / figure.box.height
                StreetFigureView(figure: figure, height: height, paces: paces)
                    .offset(x: width + gap)
            }
        }
    }
}

/// Dashboard section heading: Big Shoulders 600, 21 pt, with an optional figure on its
/// letters and an optional trailing text action.
struct NightSectionHeader: View {
    let title: String
    var figure: StreetFigure?
    var actionTitle: String?
    var action: (() -> Void)?
    /// The figure walks back and forth forever in the space between the title and the
    /// action (like the Settings headers) instead of standing on the title.
    var loops = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(NightTheme.display(21, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .capFigure(loops ? nil : figure, fontSize: 21, relativeTo: .title3, weight: .semibold, height: 22, gap: 6)
                .accessibilityAddTraits(.isHeader)
            if loops, let figure, !typeSize.isAccessibilitySize {
                // lane starts 14 pt past the title and ends before the action
                StreetLoopView(figure: figure, height: 22, reach: 1)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 1 }
            } else {
                Spacer(minLength: 8)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
        }
        .textCase(nil)
    }
}
