import AuthenticationServices
import SwiftUI
import UIKit

/// Launch-time welcome screen. Sign in with Apple is optional; the app works fully without it.
struct SignInGateView: View {
    @ObservedObject var store: AppleAccountStore = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 16)

                points
                    .padding(.top, 36)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 24)

                Spacer(minLength: 32)

                footer
                    .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 480)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.85)) {
                appeared = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            AppIconImage()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .accessibilityHidden(true)

            Text("apple_signin_title".localized)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text("apple_signin_subtitle".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 18) {
            point("lock.shield.fill", "apple_signin_point_private")
            point("sparkles", "apple_signin_point_smart")
            point("chart.pie.fill", "apple_signin_point_insights")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func point(_ symbol: String, _ key: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            Text(key.localized)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 14) {
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
            .signInWithAppleButtonStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("signin.apple")

            Button {
                store.continueWithoutSignIn()
            } label: {
                Text("apple_signin_skip".localized)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("signin.skip")

            Text("apple_signin_privacy_note".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// The app's own icon, falling back to a symbol tile if it can't be loaded.
private struct AppIconImage: View {
    private static let icon: UIImage? = {
        if let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }
        return UIImage(named: "AppIcon")
    }()

    var body: some View {
        if let icon = Self.icon {
            Image(uiImage: icon).resizable().scaledToFit()
        } else {
            ZStack {
                Color.accentColor
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

#Preview {
    SignInGateView()
}
