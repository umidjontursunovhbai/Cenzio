import SwiftUI

/// Same layout as Add expense: glass rows, inline category tiles, Save at the bottom.
struct EditExpenseView: View {
    private enum Field: Hashable { case title, amount }

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
    @State private var showingCategoryGrid = false
    @State private var confirmingDelete = false
    @FocusState private var focusedField: Field?

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
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .title)
                        .accessibilityIdentifier("edit-expense.title")

                    HStack {
                        Text(dataManager.user.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("0", text: $amount)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .amount)
                            .accessibilityIdentifier("edit-expense.amount")
                            .onChange(of: amount) { old, _ in
                                formatAmountInput(previous: old)
                            }
                    }

                    categoryRow

                    if showingCategoryGrid {
                        CategoryTileGrid(categories: dataManager.userCategories, selectedID: selectedCategory?.id) { category in
                            selectedCategory = category
                            withAnimation(.snappy(duration: 0.3)) { showingCategoryGrid = false }
                        } onCreate: {
                            showingCategoryManagement = true
                        }
                    }

                    DatePicker("column_date".localized, selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                } header: {
                    StreetSectionHeader(title: "expense_details".localized, figure: .cyclist)
                } footer: {
                    if !amount.isEmpty && validAmount == nil {
                        Text("exp_amount_must_be_positive".localized)
                            .foregroundStyle(Color(.systemRed))
                    }
                }
                .listRowBackground(NightTheme.glassFill)

                if onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("exp_delete_expense".localized, systemImage: "trash")
                                .foregroundStyle(Color(.systemRed))
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("exp_delete_footer".localized)
                            .foregroundStyle(NightTheme.secondaryLabel)
                    }
                    .listRowBackground(NightTheme.glassFill)
                }
            }
            .listRowSeparatorTint(NightTheme.hair)
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .navigationTitle("exp_edit_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                        .foregroundStyle(.tint)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done".localized) { focusedField = nil }
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

    private var saveBar: some View {
        Button("save".localized, action: updateExpense)
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .disabled(!canSave)
            .accessibilityIdentifier("edit-expense.save")
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(NightGround())
    }

    /// Opens the inline category tiles, like Add expense.
    private var categoryRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { showingCategoryGrid.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text("category".localized)
                    .foregroundStyle(.primary)
                Spacer()
                if let category = selectedCategory {
                    HeroIcon(systemName: category.iconSystemName)
                        .foregroundStyle(category.color)
                    Text(category.name)
                        .foregroundStyle(.primary)
                } else {
                    Text("select_category".localized)
                        .foregroundStyle(.secondary)
                }
                HeroIcon(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showingCategoryGrid ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("edit-expense.category")
        .accessibilityValue(selectedCategory?.name ?? "select_category".localized)
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
