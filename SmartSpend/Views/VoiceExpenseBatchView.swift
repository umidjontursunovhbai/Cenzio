import SwiftUI

/// Several expenses from one voice input, prepared by the AI as separate drafts.
struct VoiceExpenseBatch: Identifiable {
    let id = UUID()
    let items: [VoiceExpensePrefill]
}

/// One editable draft of the batch. Mirrors the rules of `AddExpenseView`.
private struct VoiceBatchRow: Identifiable {
    let id: UUID
    let currency: String?
    let dateExpression: String?
    let needsDateConfirmation: Bool
    var title: String
    var amount: String
    var categoryID: UUID?
    var date: Date
    var dateConfirmed: Bool

    init(prefill: VoiceExpensePrefill, now: Date, categoryIDs: Set<UUID>) {
        id = prefill.id
        currency = prefill.currency
        dateExpression = prefill.dateExpression
        title = prefill.title
        amount = prefill.amount.map { AmountInputFormatter.formatValue($0, maxFractionDigits: AddExpenseDraft.maxFractionDigits) } ?? ""
        categoryID = prefill.categoryID.flatMap { categoryIDs.contains($0) ? $0 : nil }
        date = AddExpenseDraft.date(onDayOf: prefill.date, timeFrom: now)
        needsDateConfirmation = prefill.requiresDateConfirmation || prefill.date > AddExpenseDraft.latestAllowedDate(now: now)
        dateConfirmed = !needsDateConfirmation
    }

    func canSave(categoryIDs: Set<UUID>, ledgerCurrency: String) -> Bool {
        AddExpenseDraft.canSave(title: title, amount: amount, categoryID: categoryID,
                                availableCategoryIDs: categoryIDs, dateConfirmed: dateConfirmed,
                                currencyMatches: currency == ledgerCurrency)
    }
}

/// Reviews every draft of one voice input on one screen and saves them together.
struct VoiceExpenseBatchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @State private var rows: [VoiceBatchRow]
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingCategoryManagement = false
    init(batch: VoiceExpenseBatch) {
        let now = Date()
        let categoryIDs = Set(DataManager.shared.userCategories.map(\.id))
        _rows = State(initialValue: batch.items.map { VoiceBatchRow(prefill: $0, now: now, categoryIDs: categoryIDs) })
    }

    private var categoryIDs: Set<UUID> { Set(dataManager.userCategories.map(\.id)) }

    private var canSaveAll: Bool {
        !isSaving && !rows.isEmpty
            && rows.allSatisfy { $0.canSave(categoryIDs: categoryIDs, ledgerCurrency: dataManager.user.currency.rawValue) }
    }

    private var total: Double {
        rows.compactMap { AddExpenseDraft.validAmount($0.amount) }.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach($rows) { $row in
                    let index = rows.firstIndex { $0.id == row.id } ?? 0
                    Section {
                        VoiceBatchRowFields(row: $row, onCreateCategory: { showingCategoryManagement = true })
                    } header: {
                        HStack {
                            Text(voiceText("Expense \(index + 1) of \(rows.count)", "Расход \(index + 1) из \(rows.count)"))
                            Spacer()
                            Button(role: .destructive) {
                                let id = row.id
                                rows.removeAll { $0.id == id }
                            } label: {
                                HeroIcon(systemName: "trash")
                                    .frame(width: 44, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(voiceText("Remove expense \(index + 1)", "Удалить расход \(index + 1)"))
                            .accessibilityIdentifier("voice.batch.remove.\(index)")
                        }
                    }
                }

                Section {
                    HStack {
                        Text(voiceText("Total", "Итого"))
                        Spacer()
                        Text(CurrencyFormatter.formatFull(total, currency: dataManager.user.currency))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                } footer: {
                    Text(voiceText("Nothing is saved until you tap Save all.", "Ничего не сохраняется, пока вы не нажмёте «Сохранить все»."))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(voiceText("\(rows.count) expenses", "Расходов: \(rows.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                        .accessibilityIdentifier("voice.batch.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(voiceText("Save all", "Сохранить все")) { saveAll() }
                        .disabled(!canSaveAll)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("voice.batch.save")
                }
            }
            .onChange(of: rows.isEmpty) { _, isEmpty in
                if isEmpty { dismiss() }
            }
            .sheet(isPresented: $showingCategoryManagement) {
                CategoryManagementView()
            }
            .alert(voiceText("Expense not saved", "Расход не сохранён"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("ok".localized) { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }

    private func saveAll() {
        guard canSaveAll else { return }
        isSaving = true
        defer { isSaving = false }
        let latest = AddExpenseDraft.latestAllowedDate()
        // Saved one by one: a failure keeps the unsaved drafts on screen, and each draft's
        // stable UUID makes a retry skip the ones that were already stored.
        while let row = rows.first {
            guard let amount = AddExpenseDraft.validAmount(row.amount), let categoryID = row.categoryID else { return }
            var expense = Expense(title: AddExpenseDraft.normalizedTitle(row.title), amount: amount,
                                  categoryId: categoryID, date: min(row.date, latest))
            expense.id = row.id
            do {
                try dataManager.addReviewedVoiceExpense(expense, currency: row.currency ?? "")
            } catch {
                saveError = error.localizedDescription
                return
            }
            rows.removeFirst()
        }
        dismiss()
    }
}

private struct VoiceBatchRowFields: View {
    @Binding var row: VoiceBatchRow
    let onCreateCategory: () -> Void
    @ObservedObject private var dataManager = DataManager.shared

    private var selectedCategory: UserCategory? {
        row.categoryID.flatMap { dataManager.getCategory(id: $0) }
    }

    var body: some View {
        TextField("expense_title_placeholder".localized, text: $row.title)
            .textFieldStyle(.plain)

        HStack {
            Text(dataManager.user.currency.symbol)
                .foregroundStyle(.secondary)
            TextField("0", text: $row.amount)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .onChange(of: row.amount) { oldValue, newValue in
                    let formatted = AmountInputFormatter.formatEditingText(newValue, previous: oldValue,
                                                                           maxFractionDigits: AddExpenseDraft.maxFractionDigits)
                    if formatted != newValue { row.amount = formatted }
                }
        }

        HStack {
            Text("category".localized)
            Spacer()
            Menu {
                ForEach(dataManager.userCategories) { category in
                    Button { row.categoryID = category.id } label: {
                        Label { Text(category.name) } icon: { HeroIcon(systemName: category.iconSystemName) }
                    }
                }
                Divider()
                Button(action: onCreateCategory) {
                    HeroIconLabel(title: "create_new_category".localized, systemName: "plus.circle")
                }
            } label: {
                HStack(spacing: 4) {
                    if let category = selectedCategory {
                        HeroIcon(systemName: category.iconSystemName)
                            .foregroundStyle(category.color)
                        Text(category.name)
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

        DatePicker("column_date".localized, selection: $row.date,
                   in: ...AddExpenseDraft.latestAllowedDate(), displayedComponents: .date)
            .onChange(of: row.date) { _, _ in row.dateConfirmed = true }
        if row.needsDateConfirmation {
            if let phrase = row.dateExpression {
                Text(voiceText("Check the date for: \(phrase)", "Проверьте дату: \(phrase)"))
                    .font(.footnote).foregroundStyle(.orange)
            }
            Toggle(voiceText("This date is correct", "Дата указана верно"), isOn: $row.dateConfirmed)
        }
    }
}
