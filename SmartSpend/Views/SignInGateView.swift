import AuthenticationServices
import CoreMotion
import SwiftUI

/// Launch-time welcome and onboarding. One black titanium card stays on screen the whole time:
/// on the welcome screen it stands still and plays its week chart, under it sit the wordmark and
/// one fixed line, and a soft light breathes on the right screen edge. There are no Start or
/// Next buttons: the user swipes the
/// card (or the copy under it) to the left to go forward and to the right to go
/// back, like paging. The card changes its face on each page (quick entry, voice, smart
/// categories, budget) and flips to a lock on the privacy page, which offers the optional
/// Sign in with Apple. The app works fully without signing in.
struct SignInGateView: View {
    @ObservedObject var store: AppleAccountStore = .shared
    @ObservedObject private var flags = FeatureFlags.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showsPages = false
    @State private var page = 0

    @State private var cardIn = false
    @State private var titleIn = false
    @State private var hintIn = false

    /// Horizontal drag of the card on the welcome screen.
    @State private var dragX: CGFloat = 0
    /// True once the swipe has committed and the card is flying off.
    @State private var leaving = false
    @State private var swipeCount = 0
    /// Width of the screen area, for the card scale.
    @State private var screenWidth: CGFloat = 0

    /// The pages in order. The voice page is shown only while the remote voice switch is on.
    private var steps: [OnboardingStep] {
        flags.voiceEnabled ? [.add, .voice, .smart, .budget, .privacy] : [.add, .smart, .budget, .privacy]
    }

    private var lastPage: Int { steps.count - 1 }

    /// The card keeps its 300 x 189 layout and is scaled as a whole to the screen width
    /// (24 pt margins), at most 1.25x.
    private var cardScale: CGFloat {
        guard screenWidth > 0 else { return 1 }
        return min((min(screenWidth, 480) - 2 * 24) / 300, 1.25)
    }

    /// The right-edge glow shows on the welcome and on every page that has a next page.
    private var showsEdge: Bool { !showsPages || page < lastPage }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                OnboardingCard(face: face, idle: !showsPages, chartLive: !showsPages && !leaving, scale: cardScale)
                    // drag offset and rotation live outside the card's own layout
                    .rotation3DEffect(.degrees(-Double(dragX) * 0.12), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                    .rotationEffect(.degrees(-Double(dragX) * 0.04))
                    .offset(x: dragX)
                    .contentShape(Rectangle())
                    .gesture(swipe)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cenzio")
                    .accessibilityAddTraits(showsPages ? [] : .isButton)
                    .accessibilityAction { if !showsPages { commitSwipe(forward: true) } }
                    .accessibilityActions {
                        if !showsPages {
                            Button("onboarding_start_action".localized) { commitSwipe(forward: true) }
                        } else {
                            if page < lastPage {
                                Button("onboarding_next".localized) { commitSwipe(forward: true) }
                            }
                            Button("onboarding_back".localized) { commitSwipe(forward: false) }
                        }
                    }
                    .opacity(cardIn ? 1 : 0)
                    .blur(radius: cardIn ? 0 : 10)
                    .offset(y: cardIn ? 0 : 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .anchorPreference(key: CardAreaKey.self, value: .bounds) { $0 }

                if showsPages {
                    OnboardingPages(store: store, page: page, steps: steps, swipe: swipe)
                        .transition(.opacity)
                } else {
                    welcomeBottom
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 480)

            if showsEdge {
                // invisible strip on the right screen edge, under the glow, so the swipe can start
                // there too; it starts below the top bar so it never covers Skip
                Color.clear
                    .frame(width: 32)
                    .contentShape(Rectangle())
                    .gesture(swipe)
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.top, 44)
                    .ignoresSafeArea(edges: .trailing)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        .overlayPreferenceValue(CardAreaKey.self) { anchor in
            // a soft light breathing on the right screen edge, where the swipe starts; shown on the
            // welcome and on every page that has a next page
            if let anchor, showsEdge {
                GeometryReader { proxy in
                    EdgeGlow()
                        .position(x: proxy.size.width - EdgeGlow.width / 2, y: proxy[anchor].midY)
                }
                .ignoresSafeArea(edges: .horizontal)
                .opacity(hintIn ? 1 : 0)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.impact(weight: .light), trigger: swipeCount)
        .task { await playWelcome() }
    }

    private var face: OnboardingCard.Face {
        guard showsPages else { return .home }
        switch steps[min(max(page, 0), lastPage)] {
        case .add: return .list(learned: false)
        case .voice: return .voice
        case .smart: return .list(learned: true)
        case .budget: return .ring
        case .privacy: return .back
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if showsPages && page < lastPage {
                Button("onboarding_skip".localized) {
                    withAnimation(.easeInOut(duration: 0.4)) { page = lastPage }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.skip")
            }
        }
        .frame(height: 44)
    }

    private var welcomeBottom: some View {
        VStack(spacing: 0) {
            // wordmark pressed into the screen like the card's name
            Text("Cenzio")
                .font(.system(size: 38, weight: .bold))
                .tracking(-1)
                .foregroundStyle(Color.white.opacity(0.85))
                .shadow(color: .black.opacity(0.9), radius: 0, x: 0, y: -1)
                .shadow(color: .white.opacity(0.18), radius: 0, x: 0, y: 1)
                .scaleEffect(titleIn ? 1 : 0.96)
                .opacity(titleIn ? 1 : 0)
                .offset(y: titleIn ? 0 : 10)
                .accessibilityAddTraits(.isHeader)

            Text("onboarding_welcome_line".localized)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .opacity(titleIn ? 1 : 0)

            Spacer(minLength: 24)

            SwipeDots(count: steps.count + 1, current: 0)
                .frame(height: 62, alignment: .bottom)
                .opacity(hintIn ? 1 : 0)
                .offset(y: hintIn ? 0 : 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingPages.height)
        .contentShape(Rectangle())
        .gesture(swipe)
    }

    private var canGoBack: Bool { showsPages }
    private var canGoForward: Bool { !showsPages || page < lastPage }

    /// One drag for the card, the page copy and the right-edge strip. Left goes forward, right
    /// goes back one page (from the first page back to the welcome). A blocked direction
    /// stretches only 30 pt.
    private var swipe: AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !leaving else { return }
                var x = value.translation.width
                if !canGoBack { x = min(30, x) }
                if !canGoForward { x = max(-30, x) }
                dragX = x
            }
            .onEnded { value in
                guard !leaving else { return }
                let width = value.translation.width
                let predicted = value.predictedEndTranslation.width
                if canGoForward && (width < -90 || predicted < -160) {
                    commitSwipe(forward: true)
                } else if canGoBack && (width > 90 || predicted > 160) {
                    commitSwipe(forward: false)
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { dragX = 0 }
                }
            })
    }

    /// Sends the card off in the swipe direction, moves to the next (or previous) page and
    /// brings the card back from the other side with the new face.
    private func commitSwipe(forward: Bool) {
        guard !leaving, forward ? canGoForward : canGoBack else { return }
        leaving = true
        let welcome = !showsPages
        // back from the first page returns to the welcome
        let toWelcome = !forward && showsPages && page == 0
        if welcome || toWelcome { swipeCount += 1 }
        let out: CGFloat = forward ? -500 : 500
        withAnimation(.easeIn(duration: 0.3)) {
            dragX = out
        } completion: {
            withTransaction(Transaction(animation: nil)) { dragX = -out }
            if welcome {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.85)) {
                    showsPages = true
                }
            } else if toWelcome {
                // the welcome title, line, dots and glow come back at once (no intro delays);
                // the week chart restarts because chartLive turns on again
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.85)) {
                    showsPages = false
                }
            } else {
                withAnimation(.easeInOut(duration: 0.3)) { page += forward ? 1 : -1 }
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { dragX = 0 }
            leaving = false
        }
    }

    private func playWelcome() async {
        guard !cardIn else { return }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) {
                cardIn = true; titleIn = true; hintIn = true
            }
            return
        }
        await pause(0.25)
        withAnimation(.easeOut(duration: 1.3)) { cardIn = true }
        await pause(1.0)
        withAnimation(.easeOut(duration: 0.6)) { titleIn = true }
        await pause(0.35)
        withAnimation(.easeOut(duration: 0.6)) { hintIn = true }
    }
}

/// Bounds of the card area, so the welcome edge glow sits level with the card centre.
private struct CardAreaKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A thin light on the right screen edge that breathes (opacity 0.15 -> 1, 3 pt inward)
/// over 2.6 s. Static at half opacity with reduce motion. Decorative only.
private struct EdgeGlow: View {
    static let width: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom))
            .frame(width: Self.width, height: 120)
            .opacity(reduceMotion ? 0.5 : (lit ? 1 : 0.15))
            .offset(x: reduceMotion || !lit ? 0 : -3)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

/// Page dots: the welcome is dot 0, then one per page; the current is wide.
private struct SwipeDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.white : Color.white.opacity(0.22))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityHidden(true)
    }
}

// MARK: - Pages

private enum OnboardingStep {
    case add, voice, smart, budget, privacy
}

/// Copy and buttons under the card. The card itself lives in `SignInGateView` so it stays on
/// screen from the welcome through the last page.
private struct OnboardingPages: View {
    @ObservedObject var store: AppleAccountStore
    let page: Int
    let steps: [OnboardingStep]
    /// The shared page swipe from `SignInGateView`; the copy follows `page`, no TabView paging.
    let swipe: AnyGesture<DragGesture.Value>

    private var pageCount: Int { steps.count }

    static let height: CGFloat = 150 + 12 + 54 + 12 + 44

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                PageCopy(step: steps[min(max(page, 0), pageCount - 1)])
                    .id(page)
                    .transition(.opacity)
            }
            .frame(height: 150, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(swipe)

            footer
                .padding(.top, 12)
        }
        .frame(height: Self.height, alignment: .top)
    }

    @ViewBuilder
    private var footer: some View {
        if page >= pageCount - 1 {
            VStack(spacing: 12) {
                if let message = store.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("signin.error")
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    store.handle(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("signin.apple")

                Button {
                    store.continueWithoutSignIn()
                } label: {
                    Text("apple_signin_skip".localized)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("signin.skip")
            }
            .transition(.opacity)
        } else {
            // only the dots, at the same spot as on the welcome (bottom of the area)
            SwipeDots(count: pageCount + 1, current: page + 1)
                .frame(maxWidth: .infinity)
                .frame(height: 54 + 12 + 44, alignment: .bottom)
            .transition(.opacity)
        }
    }
}

private struct PageCopy: View {
    let step: OnboardingStep

    private var keys: (String, String) {
        switch step {
        case .add: return ("onboarding_add_title", "onboarding_add_body")
        case .voice: return ("onboarding_voice_title", "onboarding_voice_body")
        case .smart: return ("onboarding_smart_title", "onboarding_smart_body")
        case .budget: return ("onboarding_budget_title", "onboarding_budget_body")
        case .privacy: return ("onboarding_private_title", "onboarding_private_body")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(keys.0.localized)
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(keys.1.localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Card

/// The black titanium card. On the welcome it stands still (only the phone tilt and the
/// swipe move it) while its week chart plays in a loop and a light streak sweeps across it
/// every 7 s. On the pages it sways a little, the streak follows the sway, and it flips to
/// its back on the privacy page.
private struct OnboardingCard: View {
    enum Face: Equatable {
        case home
        case list(learned: Bool)
        case voice
        case ring
        case back
    }

    let face: Face
    let idle: Bool
    /// True while the welcome shows and the swipe has not committed: the week chart loops.
    let chartLive: Bool
    /// Uniform scale of the whole card; the inner layout stays 300 x 189.
    var scale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sway = Tween(value: 0)
    // home face week chart
    @State private var daysLit = 0
    @State private var weekTotal = 0.0
    @State private var weekRing = 0.0
    @State private var avgOn = false
    @State private var ringPop = 0
    @State private var flip = Tween(value: 0)
    @State private var rowIn = false
    @State private var ringValue = 0.0
    @State private var transcript = ""
    @State private var voiceRows = 0
    @State private var listening = true
    @State private var start = Date()
    @State private var nudgeStart = Date.distantPast
    @State private var motion = CardMotion()

    private static let size = CGSize(width: 300, height: 189)
    private static let radius: CGFloat = 22
    private static let ink = Color(white: 0.95)
    private static let inkSoft = Color.white.opacity(0.6)

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let now = context.date
            let time = now.timeIntervalSince(start)
            let amp = reduceMotion ? 0 : sway.value(at: now)
            let tilt = reduceMotion ? CGPoint.zero : motion.tilt()
            let swayAngle = sin(time * 0.55) * 16 * amp + tilt.x + Self.nudge(now.timeIntervalSince(nudgeStart))
            let tiltAngle = (cos(time * 0.4) * 7 + 5) * amp + tilt.y
            let angle = flip.value(at: now) + swayAngle
            let showsBack = cos(angle * .pi / 180) < 0
            let sheenX = idle ? Self.sheenSweep(reduceMotion ? nil : time)
                              : -(swayAngle / 16) * Self.size.width * 0.7

            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 0.47, green: 0.55, blue: 0.67).opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: 140))
                    .frame(width: Self.size.width - 20, height: 22)
                    .blur(radius: 4)
                    .offset(y: Self.size.height / 2 + 34)

                cardBody(showsBack: showsBack, swayAngle: swayAngle, tiltAngle: tiltAngle, sheenX: sheenX)
                    .rotation3DEffect(.degrees(tiltAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(scale)
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { motion.start() } }
        .onDisappear { motion.stop() }
        .onChange(of: idle) { _, isIdle in
            sway = sway.retarget(to: isIdle ? 0 : 0.18, duration: 1.2)
        }
        .onChange(of: face) { _, newFace in
            flip = flip.retarget(to: newFace == .back ? 180 : 0, duration: reduceMotion ? 0 : 1.1)
            if !reduceMotion && newFace != .back {
                // a small turn on each page change, then back to rest
                nudgeStart = .now
            }
        }
        .task(id: faceKey) { await play() }
        .task(id: face == .home && chartLive) { await playWeek() }
    }

    /// Welcome streak: parked off the card, it crosses left to right in 1.4 s every 7 s,
    /// first at 3 s. Reduce motion (nil) leaves it resting in the middle.
    private static func sheenSweep(_ time: Double?) -> Double {
        guard let time else { return 0 }
        let travel = size.width * 1.3
        let phase = (time + 4).truncatingRemainder(dividingBy: 7)
        let k = min(1, phase / 1.4)
        let eased = k * k * (3 - 2 * k)
        return -travel + 2 * travel * eased
    }

    /// A smooth out-and-back turn of up to 14 degrees over 0.9 s.
    private static func nudge(_ elapsed: Double) -> Double {
        let k = elapsed / 0.9
        guard k > 0, k < 1 else { return 0 }
        return sin(k * .pi) * 14
    }

    private var faceKey: Int {
        switch face {
        case .home: return 0
        case .list: return 1
        case .ring: return 2
        case .back: return 3
        case .voice: return 4
        }
    }

    private func cardBody(showsBack: Bool, swayAngle: Double, tiltAngle: Double, sheenX: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return ZStack {
            TitaniumBase()

            BrushedLines()

            Group {
                if showsBack {
                    backFace
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                } else {
                    frontFace
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .foregroundStyle(Self.ink)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay {
            // soft hotspot that drifts with the tilt, like light on real metal
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 170)
                .frame(width: 340, height: 340)
                .offset(x: -swayAngle * 6, y: -tiltAngle * 6 - 60)
                .blendMode(.screen)
                .allowsHitTesting(false)

            LinearGradient(stops: [
                .init(color: .clear, location: 0.34),
                .init(color: .white.opacity(0.30), location: 0.47),
                .init(color: .white.opacity(0.08), location: 0.54),
                .init(color: .clear, location: 0.64),
            ], startPoint: UnitPoint(x: 0, y: 0.35), endPoint: UnitPoint(x: 1, y: 0.65))
            .frame(width: Self.size.width * 3)
            .offset(x: sheenX)
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        // chamfered edge: thin light rim, bright inner top line, dark inner bottom line
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .overlay(shape.strokeBorder(LinearGradient(stops: [
            .init(color: .white.opacity(0.5), location: 0),
            .init(color: .clear, location: 0.07),
        ], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
        .overlay(shape.strokeBorder(LinearGradient(stops: [
            .init(color: .clear, location: 0.94),
            .init(color: .black.opacity(0.6), location: 1),
        ], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .background(shape.fill(Color(white: 0.04)).offset(x: 0, y: 2.5))
        .shadow(color: .black.opacity(0.85), radius: 28, y: 22)
        .shadow(color: Color(red: 0.55, green: 0.6, blue: 0.7).opacity(0.10), radius: 40, y: 0)
    }

    // Faces

    @ViewBuilder
    private var frontFace: some View {
        Group {
            switch face {
            case .home: homeFace
            case .list(let learned): listFace(learned: learned)
            case .voice: voiceFace
            case .ring, .back: ringFace
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: faceKey)
    }

    // Home face week: bar heights (fraction of the chart) and amounts, Monday first.
    private static let weekHeights: [Double] = [0.38, 0.62, 0.30, 0.84, 0.52, 0.70, 0.44]
    private static let weekAmounts: [Double] = [52_000, 86_000, 41_000, 118_000, 72_000, 97_000, 61_000]
    private static let weekAverage = weekHeights.reduce(0, +) / Double(weekHeights.count)
    private static let barsHeight: CGFloat = 46
    private static let todayIndex = 6
    /// Very short weekday symbols starting Monday (M T W T F S S in English).
    private static let dayLetters: [String] = {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return ["M", "T", "W", "T", "F", "S", "S"] }
        return Array(symbols[1...]) + [symbols[0]]
    }()

    private var homeFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cenzio")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: -1)
                    CountingText(value: weekTotal)
                        .font(.system(size: 21, weight: .semibold))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .padding(.top, 5)
                    Text("onboarding_card_week".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(Self.inkSoft)
                }
                Spacer(minLength: 0)
                RingShape(progress: weekRing, lineWidth: 3.5)
                    .frame(width: 26, height: 26)
                    .keyframeAnimator(initialValue: 1.0, trigger: ringPop) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        CubicKeyframe(1.18, duration: 0.25)
                        CubicKeyframe(1.0, duration: 0.25)
                    }
            }
            Spacer(minLength: 0)
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { index in
                        bar(index)
                    }
                }
                AvgLine()
                    .trim(from: 0, to: avgOn ? 1 : 0)
                    .stroke(Self.inkSoft, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(height: 1)
                    .opacity(0.8)
                    .padding(.bottom, Self.barsHeight * Self.weekAverage)
            }
            .frame(height: Self.barsHeight, alignment: .bottom)
            HStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    let lit = index < daysLit
                    let today = index == Self.todayIndex
                    Text(Self.dayLetters[index])
                        .font(.system(size: 11, weight: lit && today ? .semibold : .regular))
                        .foregroundStyle(lit && today ? Self.ink : Self.inkSoft)
                        .opacity(lit ? 1 : 0.45)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 10)
    }

    private func bar(_ index: Int) -> some View {
        let lit = index < daysLit
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1,
                                           bottomTrailingRadius: 1, topTrailingRadius: 3)
        return Group {
            if index == Self.todayIndex {
                shape.fill(Color.white)
            } else {
                shape.fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.14)],
                                          startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.barsHeight * (lit ? Self.weekHeights[index] : 0.06))
    }

    private func listFace(learned: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("onboarding_today".localized)
                Spacer()
                Text("Cenzio")
            }
            .font(.system(size: 12))
            .foregroundStyle(Self.inkSoft)
            .padding(.bottom, 4)

            if rowIn {
                listRow("onboarding_sample_title".localized, amount: "25 000", chip: learned)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            listRow("onboarding_card_row_coffee".localized, amount: "18 000")
            listRow("onboarding_card_row_lunch".localized, amount: "45 000")
            listRow("onboarding_card_row_pharmacy".localized, amount: "31 500")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var voiceFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Self.ink)
                TimelineView(.animation(paused: reduceMotion || !listening)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<9, id: \.self) { i in
                            Capsule()
                                .fill(Self.ink)
                                .frame(width: 3, height: 6 + 16 * (sin(time * 7 + Double(i) * 0.8) + 1) / 2)
                        }
                    }
                    .frame(height: 22)
                }
                .opacity(listening ? 1 : 0.35)
                Spacer(minLength: 0)
            }
            .frame(height: 22)

            Text(transcript)
                .font(.system(size: 13))
                .foregroundStyle(Self.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 16, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if voiceRows > 0 {
                listRow("onboarding_card_row_coffee".localized, amount: "18 000")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if voiceRows > 1 {
                listRow("onboarding_card_row_taxi".localized, amount: "25 000")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if voiceRows > 2 {
                listRow("onboarding_card_row_lunch".localized, amount: "45 000")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func listRow(_ title: String, amount: String, chip: Bool? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            if let chip {
                Text(chip ? "onboarding_sample_category".localized : "?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(chip ? Color.white : Self.inkSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(chip ? Color.blue : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(Self.ink.opacity(chip ? 0 : 0.3)))
                    .contentTransition(.opacity)
                    .animation(.spring(response: 0.45, dampingFraction: 0.6), value: chip)
            }
            Spacer(minLength: 8)
            Text(amount).monospacedDigit()
        }
        .font(.system(size: 15))
        .frame(height: 33)
        .overlay(alignment: .top) {
            Rectangle().fill(Self.ink.opacity(0.1)).frame(height: 1)
        }
    }

    private var ringFace: some View {
        HStack(spacing: 20) {
            RingShape(progress: ringValue, lineWidth: 9)
                .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text("onboarding_card_left".localized)
                    .font(.system(size: 13))
                    .foregroundStyle(Self.inkSoft)
                Text("1 240 000")
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                Text("onboarding_card_of".localized(with: "2 000 000"))
                    .font(.system(size: 13))
                    .foregroundStyle(Self.inkSoft)
            }
        }
        .padding(22)
        .frame(maxHeight: .infinity)
    }

    private var backFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
            Spacer(minLength: 0)
            Text("onboarding_card_private".localized)
                .font(.system(size: 15))
                .foregroundStyle(Self.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // Choreography

    private func play() async {
        let fast = reduceMotion
        switch face {
        case .list:
            guard !rowIn else { return }
            await pause(fast ? 0 : 0.45)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { rowIn = true }
        case .ring:
            ringValue = 0
            await pause(fast ? 0 : 0.35)
            withAnimation(fast ? nil : .easeOut(duration: 1.4)) { ringValue = 0.62 }
        case .home:
            rowIn = false
        case .voice:
            await playVoice(fast: fast)
        case .back:
            break
        }
    }

    /// Home face week chart, looping while the welcome shows (about 9.4 s a cycle): bars rise
    /// one by one with a soft bounce, each day letter lights, the total counts up and the ring
    /// fills in steps; then the average line draws and the ring pops once. After a 6 s hold
    /// everything falls softly and the cycle starts again. Reduce motion shows the full week.
    private func playWeek() async {
        guard face == .home else { return }
        let fullRing = 0.62
        if reduceMotion {
            daysLit = 7
            weekTotal = Self.weekAmounts.reduce(0, +)
            weekRing = fullRing
            avgOn = true
            return
        }
        guard chartLive else { return }
        withTransaction(Transaction(animation: nil)) {
            daysLit = 0; weekTotal = 0; weekRing = 0; avgOn = false
        }
        while !Task.isCancelled {
            await pause(0.4)
            for day in 0..<7 {
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.68)) { daysLit = day + 1 }
                withAnimation(.easeOut(duration: 0.45)) { weekTotal += Self.weekAmounts[day] }
                withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 1.1)) {
                    weekRing = fullRing * Double(day + 1) / 7
                }
                await pause(day < 6 ? 0.33 : 0.48)
            }
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.9)) { avgOn = true }
            ringPop += 1
            // hold the full week, then fall softly (the fall starts 8.2 s into the cycle)
            await pause(8.2 - 0.4 - 6 * 0.33 - 0.48)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.6)) {
                daysLit = 0
                avgOn = false
            }
            withAnimation(.easeOut(duration: 0.6)) { weekTotal = 0 }
            withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 1.1)) { weekRing = 0 }
            await pause(9.4 - 8.2 - 0.4)
        }
    }

    /// Types the transcript out, then drops in the three expenses one by one.
    private func playVoice(fast: Bool) async {
        let full = "onboarding_voice_transcript".localized
        if fast {
            transcript = full; voiceRows = 3; listening = false
            return
        }
        transcript = ""; voiceRows = 0; listening = true
        await pause(0.35)
        let step = 1.2 / Double(max(full.count, 1))
        for count in 1...max(full.count, 1) {
            if Task.isCancelled { return }
            transcript = String(full.prefix(count))
            await pause(step)
        }
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.3)) { listening = false }
        for row in 1...3 {
            if Task.isCancelled { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { voiceRows = row }
            await pause(0.25)
        }
    }
}

/// Black titanium base: an elliptical gradient lit from the top-left
/// (#4a4a4f -> #232326 at 45% -> #111113), 120% of the width by 90% of the height.
/// Drawn in a Canvas so it always fills exactly the card and never sizes it.
private struct TitaniumBase: View {
    private static let gradient = Gradient(stops: [
        .init(color: Color(red: 0x4a / 255, green: 0x4a / 255, blue: 0x4f / 255), location: 0),
        .init(color: Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x26 / 255), location: 0.45),
        .init(color: Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255), location: 1),
    ])

    var body: some View {
        Canvas { context, size in
            let rx = size.width * 1.2, ry = size.height * 0.9
            guard rx > 0, ry > 0 else { return }
            // unit circle space: centre at 20% across, top edge; radius 1 = the ellipse
            context.translateBy(x: size.width * 0.2, y: 0)
            context.scaleBy(x: rx, y: ry)
            let rect = CGRect(x: -size.width * 0.2 / rx, y: 0, width: size.width / rx, height: size.height / ry)
            context.fill(Path(rect), with: .radialGradient(Self.gradient, center: .zero, startRadius: 0, endRadius: 1))
        }
        .allowsHitTesting(false)
    }
}

/// A horizontal line across the full width, drawn left to right when trimmed.
private struct AvgLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// A whole number with space-separated thousands ("118 000") that counts when animated.
private struct CountingText: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Self.format(value))
    }

    private static func format(_ value: Double) -> String {
        let digits = String(Int(max(0, value).rounded()))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

/// Fine horizontal hairlines that give the card a brushed-metal grain.
private struct BrushedLines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            var seed: UInt64 = 7
            while y < size.height {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let alpha = Double(seed >> 58) / 64 * 0.09
                let tone: Color = (seed >> 57) & 1 == 0 ? .white : .black
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(tone.opacity(alpha)))
                y += 1.2
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RingShape: View {
    let progress: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(red: 0.19, green: 0.82, blue: 0.35), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

/// A value that eases from one number to another over time. Read inside a `TimelineView`
/// so the card's sway and flip stay in step with the per-frame motion.
private struct Tween {
    var from: Double
    var to: Double
    var start: Date
    var duration: Double

    init(value: Double) {
        from = value; to = value; start = .distantPast; duration = 0
    }

    func value(at date: Date) -> Double {
        guard duration > 0 else { return to }
        let t = min(1, max(0, date.timeIntervalSince(start) / duration))
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return from + (to - from) * eased
    }

    func retarget(to target: Double, duration: Double) -> Tween {
        var next = self
        next.from = value(at: .now)
        next.to = target
        next.start = .now
        next.duration = duration
        return next
    }
}

/// Reads the phone's tilt so the card turns a little when the phone turns, like holding
/// a real card. No permission is needed for device motion.
@MainActor
private final class CardMotion {
    private let manager = CMMotionManager()
    private var base: CMAcceleration?
    private var smooth = CGPoint.zero

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        base = nil
    }

    /// Degrees to add: x turns the card left/right, y tips it forward/back.
    func tilt() -> CGPoint {
        guard let gravity = manager.deviceMotion?.gravity else { return smooth }
        if base == nil { base = gravity }
        guard let base else { return smooth }
        let x = max(-18, min(18, (gravity.x - base.x) * 40))
        let y = max(-14, min(14, (gravity.y - base.y) * -30))
        smooth.x += (x - smooth.x) * 0.12
        smooth.y += (y - smooth.y) * 0.12
        return smooth
    }
}

private func pause(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

#Preview {
    SignInGateView()
}
