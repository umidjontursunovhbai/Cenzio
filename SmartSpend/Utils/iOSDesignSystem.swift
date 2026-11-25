import SwiftUI

enum iOSDesignSystem {
    // MARK: Color tokens
    // Light mode keeps its original values. Dark mode is true black with
    // Liquid Glass layers on top: surfaces get depth from glass, a hairline
    // rim and a faint top glow, never from gray fills.

    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .systemBackground
    })

    /// Opaque plate for surfaces that cannot be glass (and the pre-iOS 26 fallback).
    static let elevatedBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.075, blue: 0.08, alpha: 1)
            : UIColor.white
    })

    /// Rim of a glass layer.
    static let layerStroke = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.055)
    })
    /// Inner top highlight of a glass layer.
    static let layerHighlight = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.05) : UIColor.white.withAlphaComponent(0.82)
    })
    /// Shadows read as dirt on black, so they vanish in dark mode.
    static let cardShadow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.055)
    })
    static let controlShadow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.08)
    })

    /// Text or glyph drawn on an `accentColor` fill. The accent is near-black in
    /// light mode and near-white in dark mode, so this flips with it.
    static let onAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })

    /// Fill for a selected pill or segment sitting on glass.
    static let selectionFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.14) : UIColor.systemGray5
    })

    /// Quiet fill for rows, chips and wells inside a glass card.
    static let insetFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.06) : UIColor.secondarySystemFill
    })

    enum Size {
        static let minimumTapTarget: CGFloat = 44
        static let compactIcon: CGFloat = 28
        static let rowIcon: CGFloat = 46
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let screenMargin: CGFloat = 16
        static let large: CGFloat = 20
        static let sheetMargin: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let card: CGFloat = 18
        static let sheet: CGFloat = 24
    }
}

extension View {
    @ViewBuilder
    func iOSMinimumTapTarget() -> some View {
        frame(minWidth: iOSDesignSystem.Size.minimumTapTarget,
              minHeight: iOSDesignSystem.Size.minimumTapTarget)
    }

    /// Card-sized glass layer (sections, summary cards).
    func liquidGlassCard(cornerRadius: CGFloat = iOSDesignSystem.Radius.card) -> some View {
        modifier(LiquidGlassLayer(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                                  kind: .card, interactive: false))
    }

    /// Control-sized glass layer (buttons, capsules, the tab bar). Pass
    /// `interactive: true` for tappable controls so iOS 26 glass reacts to touch.
    func liquidGlassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(LiquidGlassLayer(shape: shape, kind: .control, interactive: interactive))
    }

    /// The screen background: black with a faint top glow in dark mode, so the
    /// glass above it has light to bend. Use instead of `appBackground.ignoresSafeArea()`.
    func appBackdrop() -> some View {
        background { AppBackdrop().ignoresSafeArea() }
    }

    @ViewBuilder
    func liquidGlassButtonStyle() -> some View {
        buttonStyle(.plain)
    }

}

struct ActionIconButton: View {
    enum Style {
        case primary
        case secondary
        case destructive(enabled: Bool)
    }

    let icon: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeroIcon(icon, size: 25)
                .foregroundStyle(iconColor)
                .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                .liquidGlassSurface(Circle(), interactive: true)
                .contentShape(Circle())
                .opacity(isDisabled ? 0.38 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var isDisabled: Bool {
        if case .destructive(let enabled) = style {
            return !enabled
        }
        return false
    }

    private var iconColor: Color {
        switch style {
        case .primary:
            return Color.accentColor
        case .secondary:
            return Color.accentColor
        case .destructive(let enabled):
            return enabled ? Color(.systemRed) : Color(.systemGray2)
        }
    }
}

struct AppScreenHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: () -> Actions

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 18) {
                actions()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 10) {
            HeroIcon("magnifying-glass", size: 21)
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    HeroIcon("x-mark", size: 18)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .liquidGlassSurface(Capsule())
        .padding(.horizontal, 24)
    }
}

/// Black backdrop with one soft light source at the top (dark mode only).
struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            iOSDesignSystem.appBackground
            if colorScheme == .dark {
                RadialGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.025), .clear],
                    center: UnitPoint(x: 0.5, y: -0.08),
                    startRadius: 0,
                    endRadius: 520
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// One glass recipe for the whole app.
/// - iOS 26, dark: native Liquid Glass with a hairline rim; no fills, no shadows.
/// - iOS 26, light: the original frosted look (unchanged).
/// - iOS 18: system material fallback.
private struct LiquidGlassLayer<S: Shape>: ViewModifier {
    enum Kind { case card, control }

    let shape: S
    let kind: Kind
    let interactive: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if colorScheme == .dark {
                content
                    .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 0.75).allowsHitTesting(false))
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(iOSDesignSystem.elevatedBackground.opacity(kind == .card ? 0.78 : 0.58), in: shape)
                    .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
                    .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                    .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                    .shadow(color: kind == .card ? iOSDesignSystem.cardShadow : iOSDesignSystem.controlShadow,
                            radius: kind == .card ? 14 : 12, x: 0, y: kind == .card ? 7 : 6)
                    .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
            }
        } else {
            content
                .background(kind == .card ? Material.ultraThinMaterial : Material.thinMaterial, in: shape)
                .background(iOSDesignSystem.elevatedBackground.opacity(colorScheme == .dark ? 0.55 : (kind == .card ? 0.88 : 0.9)), in: shape)
                .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                .shadow(color: kind == .card ? iOSDesignSystem.cardShadow : iOSDesignSystem.controlShadow,
                        radius: kind == .card ? 14 : 10, x: 0, y: kind == .card ? 7 : 5)
        }
    }
}
