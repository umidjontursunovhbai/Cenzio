import SwiftUI

struct DeletedExpensesView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var pendingPermanentDelete: ArchivedExpense?

    // Night street swipe colors: dusk blue for Restore, brick red for Delete.
    // Both are dark enough for the system's white label and icon.
    private static let restoreTint = Color(red: 58 / 255, green: 88 / 255, blue: 138 / 255)
    private static let deleteTint = Color(red: 176 / 255, green: 52 / 255, blue: 48 / 255)

    private var filteredDeletedExpenses: [ArchivedExpense] {
        let sorted = dataManager.deletedExpenses.sorted { $0.archivedDate > $1.archivedDate }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        let items = filteredDeletedExpenses
        NavigationStack {
            List {
                if items.isEmpty {
                    Group {
                        if searchText.isEmpty {
                            ContentUnavailableView {
                                HeroIconLabel(title: "no_deleted_expenses".localized, systemName: "archivebox")
                            } description: {
                                Text("exp_deleted_empty_body".localized)
                            }
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(items) { expense in
                            DeletedExpenseRowView(deletedExpense: expense)
                                // Swipe left only: Delete sits at the edge, Restore next to the row.
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingPermanentDelete = expense
                                    } label: {
                                        Label("delete_button".localized, systemImage: "trash")
                                    }
                                    .tint(Self.deleteTint)
                                    Button {
                                        withAnimation { dataManager.restoreExpense(expense) }
                                    } label: {
                                        Label("restore_button".localized, systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(Self.restoreTint)
                                }
                                .contextMenu {
                                    Button {
                                        withAnimation { dataManager.restoreExpense(expense) }
                                    } label: {
                                        Label("restore_button".localized, systemImage: "arrow.uturn.backward")
                                    }
                                    Button(role: .destructive) {
                                        pendingPermanentDelete = expense
                                    } label: {
                                        Label("delete_button".localized, systemImage: "trash")
                                    }
                                }
                        }
                    } footer: {
                        Text("exp_deleted_footer".localized)
                            .foregroundStyle(NightTheme.secondaryLabel)
                    }
                    .listRowBackground(NightTheme.glassFill)
                }
            }
            .listStyle(.insetGrouped)
            .listRowSeparatorTint(NightTheme.hair)
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "search_deleted_expenses".localized
            )
            .navigationTitle("deleted_expenses_title".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            // Permanent deletion can't be undone, so it always asks first.
            .confirmationDialog(
                "exp_delete_forever_title".localized,
                isPresented: Binding(
                    get: { pendingPermanentDelete != nil },
                    set: { if !$0 { pendingPermanentDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingPermanentDelete
            ) { expense in
                Button("delete_button".localized, role: .destructive) {
                    withAnimation { dataManager.permanentlyDeleteExpense(expense) }
                }
            } message: { _ in
                Text("exp_delete_forever_message".localized)
            }
        }
    }
}

struct DeletedExpenseRowView: View {
    let deletedExpense: ArchivedExpense
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        let category = dataManager.resolveCategory(id: deletedExpense.categoryId)
        let days = dataManager.getDaysRemainingForExpense(deletedExpense)
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            HeroIcon(systemName: category.iconSystemName, size: 18)
                .foregroundStyle(NightTheme.accent)
                .frame(width: 34, height: 34)
                .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .opacity(0.7)

            VStack(alignment: .leading, spacing: 2) {
                Text(deletedExpense.title.isEmpty ? "exp_untitled".localized : deletedExpense.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(category.name + " · " + deletedExpense.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: iOSDesignSystem.Spacing.small)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CurrencyFormatter.format(deletedExpense.amount, currency: dataManager.user.currency))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(NightTheme.secondaryLabel)
                Text(days > 0 ? String(format: "exp_days_left_format".localized, days) : "expired".localized)
                    .font(.caption2)
                    .foregroundStyle(days <= 7 ? Color(.systemRed) : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    DeletedExpensesView()
}
