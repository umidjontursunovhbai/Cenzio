import SwiftUI

struct AddExpenseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    
    @State private var title = ""
    @State private var amount = ""
    @State private var selectedCategory: UserCategory?
    @State private var selectedDate = Date()
    @State private var showingSuggestions = false
    @State private var categorySuggestions: [(category: UserCategory, confidence: Double)] = []
    @State private var suggestedPrice: Double?
    @State private var showingCategoryManagement = false
    @State private var voiceDateConfirmed = false
    @State private var saveError: String?
    private let prefill: VoiceExpensePrefill?
    private let onSaved: (() -> Void)?

    init(prefill: VoiceExpensePrefill? = nil, onSaved: (() -> Void)? = nil) {
        self.prefill = prefill
        self.onSaved = onSaved
        _title = State(initialValue: prefill?.title ?? "")
        _amount = State(initialValue: prefill?.amount.map { AmountInputFormatter.formatValue($0, maxFractionDigits: 6) } ?? "")
        _selectedDate = State(initialValue: prefill?.date ?? Date())
        _selectedCategory = State(initialValue: prefill?.categoryID.flatMap { id in DataManager.shared.userCategories.first { $0.id == id } })
        _voiceDateConfirmed = State(initialValue: prefill?.requiresDateConfirmation != true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Title Field with Auto-completion
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("expense_title_placeholder".localized, text: $title, axis: .vertical)
                            .accessibilityIdentifier("expense.title")
                            .textFieldStyle(.plain)
                            .onChange(of: title) { _, _ in
                                checkForSuggestions()
                            }

                        if showingSuggestions && !categorySuggestions.isEmpty {
                            SmartSuggestionChips(
                                categories: categorySuggestions,
                                suggestedPrice: suggestedPrice,
                                currency: dataManager.user.currency,
                                onCategory: { category in
                                    selectedCategory = category
                                },
                                onPrice: { price in
                                    amount = AmountInputFormatter.formatValue(price)
                                }
                            )
                            .transition(.opacity)
                        }
                    }

                    // Amount Field
                    HStack {
                        Text(dataManager.user.currency.symbol)
                            .foregroundStyle(.secondary)
                            .font(.body)
                        TextField("0", text: $amount)
                            .accessibilityIdentifier("expense.amount")
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.plain)
                            .onChange(of: amount) {
                                formatAmountInput()
                            }
                    }
                    
                    // Category Selection
                    HStack {
                        Text("category".localized)
                        Spacer()
                        Menu {
                            ForEach(dataManager.userCategories) { userCategory in
                                Button(action: {
                                    selectedCategory = userCategory
                                }) {
                                    Label {
                                        Text(userCategory.name)
                                    } icon: {
                                        HeroIcon(systemName: userCategory.iconSystemName)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            // Create New Category
                            Button(action: { showingCategoryManagement = true }) {
                                HeroIconLabel(title: "create_new_category".localized, systemName: "plus.circle")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if let userCat = selectedCategory {
                                    HeroIcon(systemName: userCat.iconSystemName)
                                        .foregroundStyle(userCat.color)
                                    Text(userCat.name)
                                        .foregroundStyle(.primary)
                                } else {
                                    Text("select_category".localized)
                                        .foregroundStyle(.secondary)
                                }
                                HeroIcon(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    // Date Picker
                    DatePicker("column_date".localized, selection: $selectedDate, displayedComponents: .date)
                        .onChange(of: selectedDate) { _, _ in voiceDateConfirmed = true }
                    if prefill?.requiresDateConfirmation == true {
                        if let phrase = prefill?.dateExpression {
                            Text(voiceText("Check the date for: \(phrase)", "Проверьте дату: \(phrase)"))
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        Toggle(voiceText("This date is correct", "Дата указана верно"), isOn: $voiceDateConfirmed)
                    }
                } header: {
                    Text("expense_details".localized)
                }
            }
            .navigationTitle("add_expense".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                    .foregroundStyle(.tint)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("save".localized) {
                        saveExpense()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amount.isEmpty || (AmountInputFormatter.parse(amount) ?? 0) <= 0 || selectedCategory == nil || !voiceDateConfirmed || (prefill != nil && prefill?.currency != dataManager.user.currency.rawValue))
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingCategoryManagement) {
                CategoryManagementView()
            }
            .alert(voiceText("Expense not saved", "Расход не сохранён"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .onAppear {
                if selectedCategory == nil && prefill == nil {
                    selectedCategory = dataManager.userCategories.first
                }
            }
        }
    }
    
    private func checkForSuggestions() {
        guard !title.isEmpty else {
            showingSuggestions = false
            return
        }
        
        // Smart suggestions need a few expenses to learn from.
        guard dataManager.expenses.count >= 3 else {
            showingSuggestions = false
            return
        }
        
        // Get category predictions
        let categoryPreds = dataManager.getTopCategorySuggestions(for: title, limit: 3)
        
        // Get price suggestions from similar patterns
        let suggestions = dataManager.getCategoryFocusedSuggestions(for: title)
        let priceSuggestion = suggestions.first?.mostUsedPrice
        
        if !categoryPreds.isEmpty {
            categorySuggestions = categoryPreds
            suggestedPrice = priceSuggestion
            showingSuggestions = true
        } else {
            showingSuggestions = false
        }
    }
    
    private func saveExpense() {
        guard let amountValue = AmountInputFormatter.parse(amount),
              amountValue.isFinite, amountValue > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, voiceDateConfirmed,
              let categoryId = selectedCategory?.id else { return }

        var expense = Expense(
            title: title,
            amount: amountValue,
            categoryId: categoryId,
            date: selectedDate
        )
        if let prefill {
            expense.id = prefill.id
            do { try dataManager.addReviewedVoiceExpense(expense, currency: prefill.currency ?? "") }
            catch { saveError = error.localizedDescription; return }
        } else {
            dataManager.addExpense(expense)
        }
        onSaved?()
        dismiss()
    }
    
    private func formatAmountInput() {
        let formatted = AmountInputFormatter.formatEditingText(amount, maxFractionDigits: 6)
        if formatted != amount {
            amount = formatted
        }
    }
}

// MARK: - Compact smart suggestion chips

struct SmartSuggestionChips: View {
    let categories: [(category: UserCategory, confidence: Double)]
    let suggestedPrice: Double?
    let currency: Currency
    let onCategory: (UserCategory) -> Void
    let onPrice: (Double) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HeroIcon(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let price = suggestedPrice {
                    chip {
                        onPrice(price)
                    } content: {
                        Text(CurrencyFormatter.format(price, currency: currency))
                    }
                }

                ForEach(categories, id: \.category) { item in
                    chip {
                        onCategory(item.category)
                    } content: {
                        HStack(spacing: 4) {
                            HeroIcon(systemName: item.category.iconSystemName)
                                .foregroundStyle(item.category.color)
                            Text(item.category.name)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip<Content: View>(action: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(.caption.weight(.medium))
                .padding(.horizontal, iOSDesignSystem.Spacing.medium)
                .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                .liquidGlassSurface(Capsule())
                .foregroundStyle(.primary)
        }
        .liquidGlassButtonStyle()
    }
}

#Preview {
    AddExpenseView()
}
