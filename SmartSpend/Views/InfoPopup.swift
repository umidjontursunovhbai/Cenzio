import SwiftUI

// MARK: - Public API

extension View {
    /// Centered animated info card shown as an overlay inside the current view (never a new sheet/cover).
    ///
    /// Apply it on the `NavigationStack` (or the outermost view of a screen) so the dimmed backdrop
    /// also covers the navigation bar. The card has no close button: it is dismissed with the
    /// full-width "Got it" button, by tapping the backdrop, or with the VoiceOver escape gesture.
    ///
    /// Staggered content: wrap each body section in `InfoPopupSection(title:index:)`, or put
    /// `.infoPopupStaggered(index)` on any view, with increasing indexes (0, 1, 2...). Each one fades
    /// and slides in about 0.05s after the previous one once the card appears.
    ///
    /// Accessibility identifiers: `"\(prefix).card"`, `"\(prefix).gotIt"`, `"\(prefix).backdrop"`.
    func infoPopup<Content: View>(
        isPresented: Binding<Bool>,
        title: String,
        icon: String,            // HeroIcon name, e.g. "chart-pie" (see how HeroIcon is used in the codebase)
        tint: Color = .accentColor,
        accessibilityPrefix: String,   // ids: "\(prefix).card", "\(prefix).gotIt", "\(prefix).backdrop"
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(
            InfoPopupModifier(
                isPresented: isPresented,
                title: title,
                icon: icon,
                tint: tint,
                accessibilityPrefix: accessibilityPrefix,
                popupContent: content
            )
        )
    }

    /// Fades and slides this view in as part of an `infoPopup` body, `index * 0.05s` after the
    /// card starts appearing. Outside an info popup it has no effect.
    func infoPopupStaggered(_ index: Int) -> some View {
        modifier(InfoPopupStaggerModifier(index: index))
    }
}

/// A titled section of an `infoPopup` body that staggers in automatically.
struct InfoPopupSection<Content: View>: View {
    let title: String
    let index: Int
    @ViewBuilder let content: () -> Content

    init(_ title: String, index: Int, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.index = index
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .infoPopupStaggered(index)
    }
}

// MARK: - Timing

private enum InfoPopupTiming {
    static let cardIn = Animation.spring(response: 0.46, dampingFraction: 0.78)
    static let iconPop = Animation.spring(response: 0.5, dampingFraction: 0.48).delay(0.12)
    static let out = Animation.easeIn(duration: 0.2)
    static let fadeIn = Animation.easeOut(duration: 0.22)
    static let fadeOut = Animation.easeIn(duration: 0.16)
    /// Delay before the first staggered section starts, so it follows the card in.
    static let contentDelay: Double = 0.1
    static let staggerStep: Double = 0.05
}

// MARK: - Environment

private struct InfoPopupVisibleKey: EnvironmentKey {
    /// `true` outside a popup so staggered views render normally anywhere else.
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the enclosing info popup card is currently shown (drives staggered sections).
    var infoPopupIsVisible: Bool {
        get { self[InfoPopupVisibleKey.self] }
        set { self[InfoPopupVisibleKey.self] = newValue }
    }
}

// MARK: - Stagger

private struct InfoPopupStaggerModifier: ViewModifier {
    let index: Int
    @Environment(\.infoPopupIsVisible) private var isVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 16)
            .animation(animation, value: isVisible)
    }

    private var animation: Animation {
        guard isVisible else { return .easeIn(duration: 0.12) }
        if reduceMotion { return InfoPopupTiming.fadeIn }
        let delay = InfoPopupTiming.contentDelay + Double(max(index, 0)) * InfoPopupTiming.staggerStep
        return .spring(response: 0.5, dampingFraction: 0.84).delay(delay)
    }
}

// MARK: - Modifier

private struct InfoPopupModifier<PopupContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let icon: String
    let tint: Color
    let accessibilityPrefix: String
    let popupContent: () -> PopupContent

    /// Keeps the popup in the hierarchy until its exit animation finishes.
    @State private var isMounted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if isMounted {
                        InfoPopupContainer(
                            isPresented: $isPresented,
                            title: title,
                            icon: icon,
                            tint: tint,
                            accessibilityPrefix: accessibilityPrefix,
                            popupContent: popupContent,
                            onDismissed: { isMounted = false }
                        )
                        .zIndex(1)
                    }
                }
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented { isMounted = true }
            }
    }
}

// MARK: - Container

private struct InfoPopupContainer<PopupContent: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let icon: String
    let tint: Color
    let accessibilityPrefix: String
    let popupContent: () -> PopupContent
    let onDismissed: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false
    @State private var iconPopped = false
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            backdrop
            card
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
        }
        .onAppear(perform: animateIn)
        .onChange(of: isPresented) { _, presented in
            if presented {
                animateIn()
            } else {
                animateOut()
            }
        }
    }

    // MARK: Animation

    private func animateIn() {
        withAnimation(reduceMotion ? InfoPopupTiming.fadeIn : InfoPopupTiming.cardIn) {
            isVisible = true
        }
        if reduceMotion {
            iconPopped = true
        } else {
            withAnimation(InfoPopupTiming.iconPop) { iconPopped = true }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if isPresented { titleFocused = true }
        }
    }

    private func animateOut() {
        withAnimation(reduceMotion ? InfoPopupTiming.fadeOut : InfoPopupTiming.out) {
            isVisible = false
            iconPopped = false
        } completion: {
            if !isPresented { onDismissed() }
        }
    }

    private func close() {
        isPresented = false
    }

    // MARK: Backdrop

    private var backdrop: some View {
        Color.black
            .opacity(isVisible ? (colorScheme == .dark ? 0.6 : 0.42) : 0)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityLabel("close".localized)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("\(accessibilityPrefix).backdrop")
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Divider().opacity(0.6)

            ViewThatFits(in: .vertical) {
                bodyContent
                ScrollView { bodyContent }
                    .scrollIndicators(.visible)
                    .scrollBounceBehavior(.basedOnSize)
            }

            Divider().opacity(0.6)

            Button(action: close) {
                Text("got_it".localized)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(InfoPopupPressStyle())
            .padding(16)
            .accessibilityIdentifier("\(accessibilityPrefix).gotIt")
        }
        .frame(maxWidth: 420)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.2), radius: 32, x: 0, y: 16)
        .scaleEffect(isVisible || reduceMotion ? 1 : 0.85)
        .offset(y: isVisible || reduceMotion ? 0 : 28)
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .accessibilityIdentifier("\(accessibilityPrefix).card")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            iconTile
        }
    }

    private var iconTile: some View {
        HeroIcon(icon, size: 24)
            .foregroundStyle(tint)
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.12))
            )
            .scaleEffect(iconPopped || reduceMotion ? 1 : 0.3)
            .rotationEffect(.degrees(iconPopped || reduceMotion ? 0 : -28))
            .opacity(iconPopped ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            popupContent()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.infoPopupIsVisible, isVisible)
    }
}

/// Slight shrink + dim while the "Got it" button is pressed.
private struct InfoPopupPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
