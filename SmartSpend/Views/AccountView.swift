import AuthenticationServices
import LocalAuthentication
import SwiftUI

/// Display rules for the signed-in Apple ID, shared by Settings and the Account screen.
enum AppleAccountDisplay {
    /// Full name, then email, then "Apple ID" (Apple only shares name and email on first sign-in).
    static func title(for account: AppleAccount?) -> String {
        nonEmpty(account?.fullName) ?? nonEmpty(account?.email) ?? "account_apple_id".localized
    }

    /// Email under the name, only when it adds information beyond the title.
    static func detail(for account: AppleAccount?) -> String? {
        guard let email = nonEmpty(account?.email), email != title(for: account) else { return nil }
        return email
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The optional Apple account: sign in, sign out, or delete the account with all data.
struct AccountView: View {
    @ObservedObject private var store = AppleAccountStore.shared
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            profileHeader

            Group {
                if store.account != nil {
                    Section {
                        Button(role: .destructive) { confirmingSignOut = true } label: {
                            Text("account_sign_out".localized).frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("account.signOut")
                    } footer: {
                        Text("account_local_data_footer".localized)
                    }

                    Section {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            HStack(spacing: 8) {
                                Text("account_delete".localized)
                                if isDeleting { ProgressView() }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isDeleting)
                        .accessibilityIdentifier("account.delete")
                    } footer: {
                        Text("account_delete_footer".localized)
                    }
                } else {
                    Section {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = [.fullName, .email]
                        } onCompletion: { result in
                            store.handle(result)
                        }
                        // Apple's rule: white button on dark backgrounds, black on light.
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 52)
                        .clipShape(Capsule())
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("account.signIn")
                    } footer: {
                        if let message = store.errorMessage {
                            Text(message).foregroundStyle(.red)
                        } else {
                            Text("account_sign_in_footer".localized)
                        }
                    }
                }
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { cityBackground }
        .navigationTitle("account_title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .tint(colorScheme == .dark ? .white : OnboardingPalette.ink)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done".localized) { dismiss() }
            }
        }
        .confirmationDialog("account_sign_out_confirm_title".localized, isPresented: $confirmingSignOut,
                            titleVisibility: .visible) {
            Button("account_sign_out".localized, role: .destructive) {
                dismiss()
                store.signOut()
            }
            Button("cancel".localized, role: .cancel) { }
        } message: {
            Text("account_sign_out_confirm_message".localized)
        }
        .alert("account_delete_confirm_title".localized, isPresented: $confirmingDelete) {
            Button("cancel".localized, role: .cancel) { }
            Button("delete".localized, role: .destructive) { authenticateAndDelete() }
        } message: {
            Text("account_delete_confirm_message".localized)
        }
        .alert("account_delete".localized, isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("ok".localized) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    /// Large centered avatar, name and email, like the Apple ID page. No row background.
    private var profileHeader: some View {
        let account = store.account
        let detail = AppleAccountDisplay.detail(for: account)
        return Section {
            VStack(spacing: 4) {
                avatar(for: account)
                    .padding(.bottom, 8)
                Text(account == nil ? "account_not_signed_in".localized : AppleAccountDisplay.title(for: account))
                    .font(.custom("Big Shoulders Display", size: 30, relativeTo: .title).weight(.heavy))
                    .foregroundStyle(colorScheme == .dark ? OnboardingPalette.fg : OnboardingPalette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("account.name")
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(colorScheme == .dark ? OnboardingPalette.silver : .secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("account.email")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// White circle with the first letter of the name (or email); a person glyph when
    /// there is neither. Signed out: a quiet tile instead of the white circle.
    private func avatar(for account: AppleAccount?) -> some View {
        let source = account?.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? account?.email
        let initial = source?.trimmingCharacters(in: .whitespaces).first
        return ZStack {
            if account == nil {
                Circle().fill(Color.primary.opacity(0.12))
                Image(systemName: "person.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(colorScheme == .dark ? 0 : 0.12), lineWidth: 1))
                if let initial {
                    Text(String(initial).uppercased())
                        .font(OnboardingPalette.display(42))
                        .foregroundStyle(OnboardingPalette.ink)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(OnboardingPalette.ink)
                }
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    /// Same still, blurred city as Settings: night in dark mode, day in light mode.
    private var cityBackground: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
            NightCityView(page: colorScheme == .dark ? .smart : .privacy, reduceMotion: true, showsOverlay: false)
                .aspectRatio(City.W / City.H, contentMode: .fill)
                .blur(radius: 14)
                .opacity(colorScheme == .dark ? 0.8 : 0.55)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func authenticateAndDelete() {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            // deviceOwnerAuthentication falls back to the passcode when Face ID is unavailable or fails.
            let approved = (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                                                  localizedReason: "account_delete_auth_reason".localized)) ?? false
            guard approved else { return }
            // iCloud first: if it fails, nothing is deleted and the owner can retry.
            do {
                try await CloudSyncController.shared.deleteAllCloudData()
            } catch {
                deleteError = "account_delete_failed".localized
                return
            }
            CloudSyncController.shared.localDataWasCleared()
            DataManager.shared.clearAllData()
            dismiss()
            store.forgetAccount()
        }
    }
}
