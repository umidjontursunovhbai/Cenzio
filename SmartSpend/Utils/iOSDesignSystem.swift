import SwiftUI

enum iOSDesignSystem {
    static let appBackground = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.075, green: 0.078, blue: 0.088, alpha: 1)
        } else {
            return UIColor.systemBackground
        }
    })

    static let elevatedBackground = Color(UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.13, green: 0.135, blue: 0.15, alpha: 1)
        } else {
            return UIColor.white
        }
    })

    static let layerStroke = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.055)
    })
    static let layerHighlight = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.06) : UIColor.white.withAlphaComponent(0.82)
    })
    static let cardShadow = Color.black.opacity(0.055)
    static let controlShadow = Color.black.opacity(0.08)

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

    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = iOSDesignSystem.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(iOSDesignSystem.elevatedBackground.opacity(0.78), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                .shadow(color: iOSDesignSystem.cardShadow, radius: 14, x: 0, y: 7)
                .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(iOSDesignSystem.elevatedBackground.opacity(0.88), in: shape)
                .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                .shadow(color: iOSDesignSystem.cardShadow, radius: 14, x: 0, y: 7)
                .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
    }

    @ViewBuilder
    func liquidGlassSurface<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(iOSDesignSystem.elevatedBackground.opacity(0.58), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                .shadow(color: iOSDesignSystem.controlShadow, radius: 12, x: 0, y: 6)
                .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        } else {
            self
                .background(.thinMaterial, in: shape)
                .background(iOSDesignSystem.elevatedBackground.opacity(0.9), in: shape)
                .overlay(shape.stroke(iOSDesignSystem.layerHighlight, lineWidth: 0.8))
                .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
                .shadow(color: iOSDesignSystem.controlShadow, radius: 10, x: 0, y: 5)
                .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
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
                .liquidGlassSurface(Circle())
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
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color(.separator).opacity(0.22), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }
}
