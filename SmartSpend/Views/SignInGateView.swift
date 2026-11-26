import AuthenticationServices
import SwiftUI

/// Launch-time welcome and onboarding, "Night Tashkent": a night city skyline fills the top of
/// every page, and every expense is a lit window. The same city stays on screen; its sky,
/// weather and street scene change on each swipe. The copy sits under the waterline. The user
/// swipes left and right between pages; dots show where they are. The last page offers the
/// optional Sign in with Apple. The app works fully without signing in.
struct SignInGateView: View {
    @ObservedObject var store: AppleAccountStore = .shared
    @ObservedObject private var flags = FeatureFlags.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0
    @State private var dragX: CGFloat = 0

    /// The pages in order. The voice page shows only while the remote voice switch is on.
    private var steps: [CityPage] {
        flags.voiceEnabled ? [.welcome, .add, .voice, .smart, .budget, .privacy]
                           : [.welcome, .add, .smart, .budget, .privacy]
    }

    private var lastPage: Int { steps.count - 1 }
    private var current: CityPage { steps[min(max(page, 0), lastPage)] }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fullHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            // the city keeps the mockup's 390 x 500 shape, but never takes more than 60% of the screen
            let cityHeight = min(width * 500 / 390, fullHeight * 0.6)

            VStack(spacing: 0) {
                city
                    .frame(width: width, height: cityHeight)

                copyTrack(width: width)
                    .padding(.top, 20)
                    .frame(maxHeight: .infinity, alignment: .top)

                SwipeDots(count: steps.count, current: page)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            }
            .ignoresSafeArea(edges: .top)
            .contentShape(Rectangle())
            .gesture(swipe(width: width))
        }
        .background(OnboardingPalette.ink.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: page)
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if page < lastPage {
                Button("onboarding_next".localized) { go(to: page + 1) }
            }
            if page > 0 {
                Button("onboarding_back".localized) { go(to: page - 1) }
            }
        }
        .onChange(of: flags.voiceEnabled) { old, _ in
            // keep the same page when the voice page comes or goes
            let before = old ? [CityPage.welcome, .add, .voice, .smart, .budget, .privacy]
                             : [CityPage.welcome, .add, .smart, .budget, .privacy]
            let name = before[min(max(page, 0), before.count - 1)]
            page = steps.firstIndex(of: name) ?? steps.firstIndex(of: .smart) ?? 0
        }
    }

    // MARK: City

    @ViewBuilder
    private var city: some View {
        if reduceMotion {
            // Reduce Motion: one still frame per page, crossfaded
            ZStack {
                NightCityView(page: current, reduceMotion: true)
                    .id(current)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.35), value: current)
        } else {
            NightCityView(page: current)
        }
    }

    // MARK: Copy

    @ViewBuilder
    private func copyTrack(width: CGFloat) -> some View {
        if reduceMotion {
            ZStack(alignment: .topLeading) {
                PageCopy(step: current, store: store)
                    .id(current)
                    .transition(.opacity)
            }
            .frame(width: width)
            .animation(.easeInOut(duration: 0.3), value: current)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(steps, id: \.self) { step in
                    PageCopy(step: step, store: store)
                        .frame(width: width)
                        .accessibilityHidden(step != current)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(page) * width + dragX)
            .frame(width: width, alignment: .leading)
            .clipped()
        }
    }

    // MARK: Swipe

    /// Left goes forward, right goes back. Past the first or last page the copy stretches at 30%.
    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !reduceMotion else { return }
                let dx = value.translation.width
                let edge = (page == 0 && dx > 0) || (page == lastPage && dx < 0)
                dragX = edge ? dx * 0.3 : dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                if (dx < -50 || predicted < -160) && page < lastPage {
                    go(to: page + 1)
                } else if (dx > 50 || predicted > 160) && page > 0 {
                    go(to: page - 1)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { dragX = 0 }
                }
            }
    }

    private func go(to target: Int) {
        let next = min(max(target, 0), lastPage)
        if reduceMotion {
            dragX = 0
            page = next
            return
        }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55)) {
            page = next
            dragX = 0
        }
    }
}

/// Page dots; the current one is wide.
private struct SwipeDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? OnboardingPalette.fg : OnboardingPalette.dotOff)
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .animation(.easeOut(duration: 0.35), value: current)
        .accessibilityHidden(true)
    }
}

/// Title and body under the city; the last page adds the sign-in buttons at the bottom.
private struct PageCopy: View {
    let step: CityPage
    @ObservedObject var store: AppleAccountStore

    private var keys: (String, String) {
        switch step {
        case .welcome: return ("Cenzio", "onboarding_welcome_line")
        case .add: return ("onboarding_add_title", "onboarding_add_body")
        case .voice: return ("onboarding_voice_title", "onboarding_voice_body")
        case .smart: return ("onboarding_smart_title", "onboarding_smart_body")
        case .budget: return ("onboarding_budget_title", "onboarding_budget_body")
        case .privacy: return ("onboarding_private_title", "onboarding_private_body")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: step == .welcome ? 10 : 14) {
                Text(step == .welcome ? keys.0 : keys.0.localized)
                    .font(OnboardingPalette.display(step == .welcome ? 76 : 42))
                    .tracking(step == .welcome ? 0.8 : 0)
                    .foregroundStyle(OnboardingPalette.fg)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(keys.1.localized)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(OnboardingPalette.body)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            if step == .privacy {
                signIn
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var signIn: some View {
        VStack(spacing: 6) {
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
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("signin.apple")
        }
    }
}

#Preview {
    SignInGateView()
}
