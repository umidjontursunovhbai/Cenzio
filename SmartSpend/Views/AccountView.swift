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

/// The signed-in Apple account. Expenses stay on this iPhone; signing out only returns to the sign-in screen.
struct AccountView: View {
    @ObservedObject private var store = AppleAccountStore.shared
    @State private var confirmingSignOut = false
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
    }
}
