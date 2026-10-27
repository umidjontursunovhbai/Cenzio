import AuthenticationServices
import LocalAuthentication
import SwiftUI

/// Display rules for the signed-in Apple ID, shared by Settings and the Account screen.
enum AppleAccountDisplay {
    /// Full name, then email, then "Apple ID" (Apple only shares name and email on first sign-in).
    static func title(for account: AppleAccount?) -> String {
        nonEmpty(account?.fullName) ?? nonEmpty(account?.email) ?? "account_apple_id".localized
    }

    /// Email when it adds information beyond the title, otherwise "Signed in with Apple".
    static func subtitle(for account: AppleAccount?) -> String {
        guard let account else { return "account_not_signed_in".localized }
        if let email = nonEmpty(account.email), email != title(for: account) { return email }
        return "account_signed_in_with_apple".localized
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

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.primary, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppleAccountDisplay.title(for: store.account))
                            .font(.headline)
                            .accessibilityIdentifier("account.name")
                        Text(store.account == nil ? "account_not_signed_in".localized : "account_signed_in_with_apple".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("account.provider")
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                if let name = store.account?.fullName, !name.isEmpty {
                    LabeledContent("account_name".localized, value: name)
                }
                if let email = store.account?.email, !email.isEmpty {
                    LabeledContent("account_email".localized, value: email)
                }
            } footer: {
                Text("account_local_data_footer".localized)
            }

            if store.account != nil {
                Section {
                    Button("account_sign_out".localized, role: .destructive) { confirmingSignOut = true }
                        .accessibilityIdentifier("account.signOut")
                } footer: {
                    Text("account_manage_apple_id_footer".localized)
                }

                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        HStack {
                            Text("account_delete".localized)
                            if isDeleting {
                                Spacer()
                                ProgressView()
                            }
                        }
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
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .listRowInsets(EdgeInsets())
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
        .listStyle(.insetGrouped)
        .navigationTitle("account_title".localized)
        .navigationBarTitleDisplayMode(.inline)
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
