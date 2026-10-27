import SwiftUI

/// Pure rules of the Add Expense form, kept outside the view so they can be unit tested.
enum AddExpenseDraft {
    /// A learned suggestion must be at least this confident to replace the default category.
    static let autoCategoryConfidence = 0.6
    /// Same precision as every other amount field and as `CurrencyFormatter` displays.
    static let maxFractionDigits = 2

    /// Single line, no surrounding whitespace — the title field wraps, so Return/paste could
    /// otherwise store newlines, and " Coffee" would miss the learned "Coffee" pattern.
    static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validAmount(_ text: String) -> Double? {
        guard let value = AmountInputFormatter.parse(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    static func canSave(title: String, amount: String, categoryID: UUID?, availableCategoryIDs: Set<UUID>,
                        dateConfirmed: Bool, currencyMatches: Bool) -> Bool {
        guard let categoryID else { return false }
        return !normalizedTitle(title).isEmpty
            && validAmount(amount) != nil
            && availableCategoryIDs.contains(categoryID)
            && dateConfirmed
            && currencyMatches
    }

    /// Last moment an expense may be dated: the end of today. Expenses are spent money, and a
    /// future date would silently inflate this month's budget and analytics.
    static func latestAllowedDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return startOfTomorrow.addingTimeInterval(-1)
    }

    /// The picker only edits the day, so keep the day the user (or voice) chose but use the
    /// current time of day; otherwise "today" from voice lands at 00:00, below earlier expenses.
    static func date(onDayOf day: Date, timeFrom time: Date, calendar: Calendar = .current) -> Date {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
        let combined = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                     second: clock.second ?? 0, of: day) ?? day
        return min(combined, latestAllowedDate(now: time, calendar: calendar))
    }

    /// Applies the best learned category only while the user has not picked one themselves.
    static func autoSelectedCategoryID(current: UUID?, userChose: Bool,
                                       suggestions: [(category: UserCategory, confidence: Double)]) -> UUID? {
        guard !userChose, let best = suggestions.first, best.confidence >= autoCategoryConfidence else { return current }
        return best.category.id
    }
}

struct AddExpenseView: View {
    private enum Field: Hashable { case title, amount }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    @State private var title = ""
    @State private var amount = ""
    // Store the id and resolve it live, so a category renamed or deleted from the
    // "Create New Category" sheet is reflected instead of saving a stale/missing id.
    @State private var selectedCategoryID: UUID?
    @State private var categoryChosenByUser = false
    @State private var selectedDate = Date()
    @State private var categorySuggestions: [(category: UserCategory, confidence: Double)] = []
    @State private var suggestedPrice: Double?
    @State private var showingCategoryManagement = false
    @State private var needsDateConfirmation = false
    @State private var voiceDateConfirmed = false
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var focusedField: Field?
    private let prefill: VoiceExpensePrefill?
    private let onSaved: (() -> Void)?

    init(prefill: VoiceExpensePrefill? = nil, onSaved: (() -> Void)? = nil) {
        self.prefill = prefill
        self.onSaved = onSaved
        _title = State(initialValue: prefill?.title ?? "")
        _amount = State(initialValue: prefill?.amount.map { AmountInputFormatter.formatValue($0, maxFractionDigits: 6) } ?? "")
        let now = Date()
        _selectedDate = State(initialValue: prefill.map { AddExpenseDraft.date(onDayOf: $0.date, timeFrom: now) } ?? now)
        let initialCategoryID = prefill?.categoryID.flatMap { id in DataManager.shared.getCategory(id: id)?.id }
        _selectedCategoryID = State(initialValue: initialCategoryID)
        _categoryChosenByUser = State(initialValue: initialCategoryID != nil)
        // A future voice date is clamped to today, so the owner must confirm it as well.
        let dateWasClamped = prefill.map { $0.date > AddExpenseDraft.latestAllowedDate(now: now) } ?? false
        let needsConfirmation = prefill?.requiresDateConfirmation == true || dateWasClamped
        _needsDateConfirmation = State(initialValue: needsConfirmation)
        _voiceDateConfirmed = State(initialValue: !needsConfirmation)
    }

    private var selectedCategory: UserCategory? {
        selectedCategoryID.flatMap { dataManager.getCategory(id: $0) }
    }

    private var currencyMatches: Bool {
        prefill.map { $0.currency == dataManager.user.currency.rawValue } ?? true
    }

    private var canSave: Bool {
        !isSaving && AddExpenseDraft.canSave(
            title: title, amount: amount, categoryID: selectedCategoryID,
            availableCategoryIDs: Set(dataManager.userCategories.map(\.id)),
            dateConfirmed: voiceDateConfirmed, currencyMatches: currencyMatches)
    }

    private var hasUnsavedInput: Bool {
        !AddExpenseDraft.normalizedTitle(title).isEmpty || !amount.isEmpty
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
                            .focused($focusedField, equals: .title)
                            .submitLabel(.next)
                            .onChange(of: title) { _, newValue in
                                handleTitleNewlines(newValue)
                            }

                        if !categorySuggestions.isEmpty {
                            SmartSuggestionChips(
                                categories: categorySuggestions,
                                suggestedPrice: suggestedPrice,
                                currency: dataManager.user.currency,
                                onCategory: { category in
                                    selectedCategoryID = category.id
                                    categoryChosenByUser = true
                                },
                                onPrice: { price in
                                    amount = AmountInputFormatter.formatValue(price, maxFractionDigits: AddExpenseDraft.maxFractionDigits)
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
                            .focused($focusedField, equals: .amount)
                            .onChange(of: amount) { oldValue, newValue in
                                formatAmountInput(old: oldValue, new: newValue)
                            }
                    }

                    // Category Selection
                    HStack {
                        Text("category".localized)
                        Spacer()
                        Menu {
                            ForEach(dataManager.userCategories) { userCategory in
                                Button(action: {
                                    selectedCategoryID = userCategory.id
                                    categoryChosenByUser = true
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
                        .accessibilityIdentifier("expense.category")
                    }

                    // Date Picker
                    DatePicker("column_date".localized, selection: $selectedDate,
                               in: ...AddExpenseDraft.latestAllowedDate(), displayedComponents: .date)
                        .accessibilityIdentifier("expense.date")
                        .onChange(of: selectedDate) { _, _ in voiceDateConfirmed = true }
                    if needsDateConfirmation {
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("add_expense".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("expense.cancel")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("save".localized) {
                        saveExpense()
                    }
                    .disabled(!canSave)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("expense.save")
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done".localized) { focusedField = nil }
                }
            }
            // Swiping the sheet away would silently discard a typed expense; Cancel still works.
            .interactiveDismissDisabled(prefill == nil && hasUnsavedInput)
            .sheet(isPresented: $showingCategoryManagement) {
                CategoryManagementView()
            }
            .alert(voiceText("Expense not saved", "Расход не сохранён"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("ok".localized) { saveError = nil }
            } message: { Text(saveError ?? "") }
            .onChange(of: dataManager.userCategories) { oldValue, newValue in
                categoriesChanged(from: oldValue, to: newValue)
            }
            // Debounced: suggestion matching runs Levenshtein over every learned pattern.
            // Also runs on appear, so a voice prefill title gets suggestions too.
            .task(id: AddExpenseDraft.normalizedTitle(title)) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                updateSuggestions()
            }
            .onAppear {
                if selectedCategoryID == nil && prefill == nil {
                    selectedCategoryID = dataManager.userCategories.first?.id
                }
                if prefill == nil && title.isEmpty {
                    // Sheets need a beat before a field can become first responder.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusedField = .title }
                }
            }
        }
    }

    private func handleTitleNewlines(_ newValue: String) {
        guard newValue.contains(where: \.isNewline) else { return }
        let pressedReturn = newValue.last?.isNewline == true
        title = newValue.split(whereSeparator: \.isNewline).joined(separator: " ")
        if pressedReturn { focusedField = .amount }
    }

    private func updateSuggestions() {
        let query = AddExpenseDraft.normalizedTitle(title)
        // Smart suggestions need a few expenses to learn from.
        guard !query.isEmpty, dataManager.expenses.count >= 3 else {
            categorySuggestions = []
            suggestedPrice = nil
            return
        }

        categorySuggestions = dataManager.getTopCategorySuggestions(for: query, limit: 3)
        // Merged patterns can carry 0-priced combinations; never offer a 0 amount.
        suggestedPrice = categorySuggestions.isEmpty ? nil
            : dataManager.getCategoryFocusedSuggestions(for: query).first.map(\.mostUsedPrice).flatMap { $0 > 0 ? $0 : nil }

        // Voice review deliberately keeps the model's category (or none); only manual entry auto-fills.
        if prefill == nil {
            selectedCategoryID = AddExpenseDraft.autoSelectedCategoryID(
                current: selectedCategoryID, userChose: categoryChosenByUser, suggestions: categorySuggestions)
        }
    }

    private func categoriesChanged(from oldValue: [UserCategory], to newValue: [UserCategory]) {
        let oldIDs = Set(oldValue.map(\.id))
        if showingCategoryManagement, let created = newValue.last(where: { !oldIDs.contains($0.id) }) {
            // Created via "Create New Category" from this form: use it.
            selectedCategoryID = created.id
            categoryChosenByUser = true
        } else if let id = selectedCategoryID, !newValue.contains(where: { $0.id == id }) {
            selectedCategoryID = prefill == nil ? newValue.first?.id : nil
            categoryChosenByUser = false
        }
        categorySuggestions.removeAll { suggestion in !newValue.contains { $0.id == suggestion.category.id } }
    }

    private func saveExpense() {
        // Guards fast double taps: the sheet is still on screen until dismissal animates.
        guard canSave, let amountValue = AddExpenseDraft.validAmount(amount),
              let categoryId = selectedCategoryID else { return }
        isSaving = true

        var expense = Expense(
            title: AddExpenseDraft.normalizedTitle(title),
            amount: amountValue,
            categoryId: categoryId,
            date: min(selectedDate, AddExpenseDraft.latestAllowedDate())
        )
        if let prefill {
            expense.id = prefill.id
            do { try dataManager.addReviewedVoiceExpense(expense, currency: prefill.currency ?? "") }
            catch { saveError = error.localizedDescription; isSaving = false; return }
        } else {
            dataManager.addExpense(expense)
        }
        focusedField = nil
        onSaved?()
        dismiss()
    }

    private func formatAmountInput(old: String, new: String) {
        let formatted = AmountInputFormatter.formatEditingText(new, previous: old, maxFractionDigits: AddExpenseDraft.maxFractionDigits)
        if formatted != new {
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
