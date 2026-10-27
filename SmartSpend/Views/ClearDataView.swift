import SwiftUI
import LocalAuthentication

/// Lets the owner pick which parts of local data to delete, then confirms with Face ID
/// (or the device passcode) before anything is removed.
struct ClearDataView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var cloudSync = CloudSyncController.shared
    @State private var selection: Set<DataManager.ClearablePart> = []
    @State private var showingConfirm = false
    @State private var isAuthenticating = false
    @State private var authError: String?

    private typealias Part = DataManager.ClearablePart

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("clear_data_select_all".localized, isOn: Binding(
                        get: { selection.count == Part.allCases.count },
                        set: { selection = $0 ? Set(Part.allCases) : [] }
                    ))
                    .fontWeight(.medium)
                }

                Section {
                    ForEach(Part.allCases) { part in
                        Toggle(isOn: Binding(
                            get: { selection.contains(part) },
                            set: { isOn in
                                if isOn { selection.insert(part) } else { selection.remove(part) }
                            }
                        )) {
                            HStack {
                                Text("clear_part_\(part.rawValue)".localized)
                                Spacer()
                                if let count = count(of: part) {
                                    Text("\(count)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                } header: {
                    Text("clear_data_choose".localized)
                } footer: {
                    Text("icloud_sync_clear_note".localized)
                }

                if let authError {
                    Section {
                        Text(authError)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingConfirm = true
                    } label: {
                        HStack {
                            if isAuthenticating { ProgressView() }
                            Text("clear_data_delete_selected".localized)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(selection.isEmpty || isAuthenticating)
                }
            }
            .navigationTitle("clear_data_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel".localized) { dismiss() }
                }
            }
            // An alert always shows both buttons; a confirmation dialog shown as a popover hides Cancel.
            .alert("clear_data_confirm_title".localized, isPresented: $showingConfirm) {
                Button("cancel".localized, role: .cancel) { }
                Button("delete".localized, role: .destructive) { authenticateAndClear() }
            } message: {
                Text("clear_data_confirm_message".localized)
            }
        }
    }

    /// Item counts for list-like parts; nil for parts that aren't a list.
    private func count(of part: Part) -> Int? {
        switch part {
        case .expenses: return dataManager.expenses.count
        case .deletedExpenses: return dataManager.deletedExpenses.count
        case .categories: return dataManager.userCategories.count
        case .budgetsAndGoals: return dataManager.categoryBudgets.count + dataManager.spendingGoals.count
        case .salaries: return dataManager.monthlySalaries.count
        case .recurring: return dataManager.recurringExpenses.count
        case .suggestions, .settings: return nil
        }
    }

    private func authenticateAndClear() {
        authError = nil
        isAuthenticating = true
        let parts = selection
        Task {
            // deviceOwnerAuthentication falls back to the passcode when Face ID is unavailable or fails.
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                               localizedReason: "clear_data_auth_reason".localized)) ?? false
            isAuthenticating = false
            guard approved else {
                authError = "clear_data_auth_failed".localized
                return
            }
            cloudSync.localDataWasCleared()
            dataManager.clearData(parts)
            dismiss()
        }
    }
}
