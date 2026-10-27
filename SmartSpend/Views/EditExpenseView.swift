import SwiftUI

struct EditExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    let expense: Expense
    /// Moves the expense to Deleted; the caller handles undo. Hidden when nil.
    var onDelete: (() -> Void)?

    @State private var title: String
    @State private var amount: String
    /// nil when the expense's category no longer exists; saving then keeps the original id.
    @State private var selectedCategory: UserCategory?
    @State private var selectedDate: Date
    @State private var showingCategoryManagement = false
    @State private var confirmingDelete = false

    init(expense: Expense, onDelete: (() -> Void)? = nil) {
        self.expense = expense
        self.onDelete = onDelete
        self._title = State(initialValue: expense.title)
        self._amount = State(initialValue: AmountInputFormatter.formatValue(expense.amount))
        // getCategory, not resolveCategory: the fallback "Other" has a fresh random id,
        // and saving it would silently re-point the expense at a category that doesn't exist.
        self._selectedCategory = State(initialValue: DataManager.shared.getCategory(id: expense.categoryId))
        self._selectedDate = State(initialValue: expense.date)
    }

    private var validTitle: String? { ExpenseEditValidator.title(title) }
    private var validAmount: Double? { ExpenseEditValidator.amount(amount) }
    private var canSave: Bool { validTitle != nil && validAmount != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("exp_title_placeholder".localized, text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("edit-expense.title")

                    HStack {
                        Text(dataManager.user.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("0", text: $amount)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("edit-expense.amount")
                            .onChange(of: amount) { old, _ in
                                formatAmountInput(previous: old)
                            }
                    }

                    categoryPicker

                    DatePicker("column_date".localized, selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                } header: {
                    Text("expense_details".localized)
                } footer: {
                    if !amount.isEmpty && validAmount == nil {
                        Text("exp_amount_must_be_positive".localized)
                            .foregroundStyle(Color(.systemRed))
                    }
                }

                if onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("exp_delete_expense".localized, systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("exp_delete_footer".localized)
                    }
                }
            }
            .navigationTitle("exp_edit_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("save".localized, action: updateExpense)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("edit-expense.save")
                }
            }
            .confirmationDialog("exp_delete_expense".localized, isPresented: $confirmingDelete, titleVisibility: .hidden) {
                Button("exp_delete_expense".localized, role: .destructive) {
                    dismiss()
                    onDelete?()
                }
            }
            .sheet(isPresented: $showingCategoryManagement) {
                CategoryManagementView()
            }
        }
    }

    private var categoryPicker: some View {
        HStack {
            Text("category".localized)
            Spacer()
            Menu {
                ForEach(dataManager.userCategories) { userCategory in
                    Button {
                        selectedCategory = userCategory
                    } label: {
                        Label {
                            Text(userCategory.name)
                        } icon: {
                            HeroIcon(systemName: userCategory.iconSystemName)
                        }
                    }
                }

                Divider()

                Button {
                    showingCategoryManagement = true
                } label: {
                    HeroIconLabel(title: "create_new_category".localized, systemName: "plus.circle")
                }
            } label: {
                HStack(spacing: 4) {
                    if let category = selectedCategory {
                        HeroIcon(systemName: category.iconSystemName, size: 18)
                            .foregroundStyle(category.color)
                        Text(category.name)
                            .foregroundStyle(.primary)
                    } else {
                        Text("select_category".localized)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func updateExpense() {
        guard let amountValue = validAmount, let titleValue = validTitle else { return }

        // Start from the stored copy so fields this form doesn't edit (e.g. notionId) survive.
        if var updatedExpense = dataManager.expenses.first(where: { $0.id == expense.id }) {
            updatedExpense.title = titleValue
            updatedExpense.amount = amountValue
            updatedExpense.categoryId = selectedCategory?.id ?? expense.categoryId
            updatedExpense.date = selectedDate
            dataManager.updateExpense(updatedExpense)
        }

        dismiss()
    }

    private func formatAmountInput(previous: String) {
        let formatted = AmountInputFormatter.formatEditingText(amount, previous: previous)
        if formatted != amount {
            amount = formatted
        }
    }
}

#Preview {
    EditExpenseView(expense: Expense(
        title: "Coffee",
        amount: 4.50,
        categoryId: UUID(),
        date: Date()
    ))
}
