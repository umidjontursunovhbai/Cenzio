import AuthenticationServices
import SwiftUI

/// Optional account sign-in. It intentionally does not enroll or upload the local ledger.
struct AccountView: View {
    @ObservedObject private var session = AccountSessionStore.shared
    @State private var confirmingDeletion = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.account == nil ? "Your SmartSpend account" : "You're signed in")
                        .font(.title2.bold())
                    Text("Sign-in is optional. Your expenses stay on this iPhone; signing in doesn't turn on sync.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let account = session.account {
                    profile(account)
                } else {
                    signInOptions
                }

                if session.loading {
                    ProgressView("Checking sign-in options…")
                        .font(.footnote)
                }
                if let message = session.message {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        if session.account == nil {
                            Button("Try again") { Task { await session.refresh() } }
                                .font(.footnote.weight(.semibold))
                                .disabled(session.loading || session.busy)
                        }
                    }
                    .accessibilityIdentifier("account.message")
                }
                if session.busy {
                    ProgressView("Please wait…").frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(session.busy)
            }
        }
        .interactiveDismissDisabled(session.busy)
        .task { await session.refresh() }
        .refreshable { await session.refresh() }
        .confirmationDialog("Delete your SmartSpend account?", isPresented: $confirmingDeletion,
                            titleVisibility: .visible) {
            Button("Delete account", role: .destructive) { Task { await session.deleteAccount() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your sign-in profile and account sessions. Expenses on this iPhone, connected spreadsheets, Notion pages and separately connected sync data are not deleted.")
        }
    }

    private var signInOptions: some View {
        VStack(spacing: 16) {
            providerOption(.apple) {
                AccountAppleSignInButton(enabled: session.available(.apple) && !session.busy && !session.loading) {
                    Task { await session.signIn(.apple) }
                }
                .frame(height: 50)
                .accessibilityLabel("Continue with Apple")
            }
            providerOption(.google) {
                Button {
                    Task { await session.signIn(.google) }
                } label: {
                    HStack(spacing: 12) {
                        Image("GoogleSignInBrand").renderingMode(.original)
                            .resizable().scaledToFit().frame(width: 20, height: 20)
                        Text("Continue with Google")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Color(red: 31/255, green: 31/255, blue: 31/255))
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 116/255, green: 119/255, blue: 117/255), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!session.available(.google) || session.busy || session.loading)
                .accessibilityIdentifier("account.signIn.google")
            }
            providerOption(.telegram) {
                Button {
                    Task { await session.signIn(.telegram) }
                } label: {
                    Text("Continue with Telegram")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(Color(red: 0, green: 136/255, blue: 204/255), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!session.available(.telegram) || session.busy || session.loading)
                .accessibilityIdentifier("account.signIn.telegram")
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func providerOption<Content: View>(_ provider: AccountProvider,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            content()
            if !session.loading && session.message == nil && !session.available(provider) {
                Text("\(provider.name) sign-in isn't available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func profile(_ account: SmartSpendAccount) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(account.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? account.email ?? "SmartSpend account",
                  systemImage: "person.crop.circle")
                .font(.headline)
            if let email = account.email, email != account.displayName {
                Text(email).font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Signed in with \(account.provider.name)").font(.footnote).foregroundStyle(.secondary)
            Divider()
            Button("Sign out") { Task { await session.signOut() } }
                .disabled(session.busy || session.loading)
                .accessibilityIdentifier("account.signOut")
            Button("Delete account", role: .destructive) { confirmingDeletion = true }
                .disabled(session.busy || session.loading)
                .accessibilityIdentifier("account.delete")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Apple's own button artwork, while the existing backend handles the web OAuth flow.
private struct AccountAppleSignInButton: UIViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        button.accessibilityIdentifier = "account.signIn.apple"
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = enabled
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}
