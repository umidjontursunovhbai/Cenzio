import SwiftUI

/// Same layout as Add expense: full-screen page, glass rows, category menu, city and Save at the bottom.
struct EditExpenseView: View {
    private enum Field: Hashable { case title, amount }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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

                    CategoryMenuRow(
                        categories: dataManager.userCategories,
                        selectedID: Binding(
                            get: { selectedCategory?.id },
                            set: { id in selectedCategory = id.flatMap { dataManager.getCategory(id: $0) } }
                        ),
                        onCreate: { showingCategoryManagement = true }
                    )
                    .accessibilityIdentifier("edit-expense.category")

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

    /// Same bottom as Add expense: the mini city stays while typing (shorter), then Save.
    private var saveBar: some View {
        VStack(spacing: 0) {
            if !typeSize.isAccessibilitySize {
                SkylineBandView(litDays: litDays, today: calendar.component(.day, from: Date()),
                                parkedTaxi: true, glow: 0)
                    .frame(height: focusedField == nil ? 100 : 64)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: focusedField == nil)
            }
            Button("save".localized, action: updateExpense)
                .buttonStyle(PrimaryCapsuleButtonStyle())
                .disabled(!canSave)
                .accessibilityIdentifier("edit-expense.save")
                .padding(.horizontal, 28)
                .padding(.top, typeSize.isAccessibilitySize ? 12 : 0)
                .padding(.bottom, 10)
        }
        .background(NightGround())
    }

    private let calendar = Calendar.current

    /// Days of this month with expenses: the lit windows of the mini city.
    private var litDays: Set<Int> {
        let now = Date()
        return Set(dataManager.expenses
            .filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
            .map { calendar.component(.day, from: $0.date) })
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
