import SwiftUI

struct AddRecurringExpenseView: View {
    var body: some View {
        RecurringExpenseFormView(existing: nil)
    }
}

struct EditRecurringExpenseView: View {
    let recurringExpense: RecurringExpense

    var body: some View {
        RecurringExpenseFormView(existing: recurringExpense)
    }
}

/// One form for add and edit. Editing copies the stored item, so its id, createdDate and
/// processing cursor survive, and saves through `updateRecurringExpense`, which handles a stale
/// cursor, resuming and start-date/frequency changes without duplicating charges.
struct RecurringExpenseFormView: View {
    let existing: RecurringExpense?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    @State private var title: String
    @State private var amount: String
    @State private var selectedCategory: UserCategory?
    @State private var recurrence: RecurrenceType
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var isActive: Bool
    @State private var showingCategoryManagement = false
    @State private var showingDeleteConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, amount }

    init(existing: RecurringExpense?) {
        self.existing = existing
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: existing?.startDate ?? Date())
        let defaultEnd = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        // State is seeded here, not in onAppear, so returning from the category sheet keeps edits.
        _title = State(initialValue: existing?.title ?? "")
        _amount = State(initialValue: existing.map { AmountInputFormatter.formatValue($0.amount) } ?? "")
        _selectedCategory = State(initialValue: existing.map { DataManager.shared.resolveCategory(id: $0.categoryId) })
        _recurrence = State(initialValue: existing?.recurrenceType ?? .monthly)
        _startDate = State(initialValue: start)
        _hasEndDate = State(initialValue: existing?.endDate != nil)
        _endDate = State(initialValue: max(existing?.endDate.map { calendar.startOfDay(for: $0) } ?? defaultEnd, start))
        _isActive = State(initialValue: existing?.isActive ?? true)
    }

    private var isEditing: Bool { existing != nil }

    /// The live copy, so the status rows reflect processing that ran while the sheet was open.
    private var stored: RecurringExpense? {
        guard let existing else { return nil }
        return dataManager.recurringExpenses.first { $0.id == existing.id } ?? existing
    }

    private var startDay: Date { Calendar.current.startOfDay(for: startDate) }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                scheduleSection

                Section {
                    Toggle("active".localized, isOn: $isActive)
                        .accessibilityIdentifier("recurringActiveToggle")
                } footer: {
                    Text("recurring_active_footer".localized)
                }

                if let stored {
                    statusSection(for: stored)
                }

                Section {
                    RecurrencePreviewView(
                        recurrenceType: recurrence,
                        startDate: startDate,
                        endDate: hasEndDate ? endDate : nil
                    )
                } footer: {
                    if let note = backfillNote {
                        Text(note)
                    }
                }

                if isEditing {
                    Section {
                        Button("recurring_delete_button".localized, role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("recurringDeleteButton")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle((isEditing ? "edit_recurring_expense" : "add_recurring_expense").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save".localized, action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("recurringSaveButton")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("done".localized) { focusedField = nil }
                }
            }
            .sheet(isPresented: $showingCategoryManagement) {
                CategoryManagementView()
            }
            .confirmationDialog(
                "recurring_delete_title".localized,
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("delete".localized, role: .destructive, action: delete)
            } message: {
                Text("recurring_delete_message".localized)
            }
            .onAppear {
                if selectedCategory == nil {
                    selectedCategory = dataManager.userCategories.first
                }
            }
            .onChange(of: startDate) { _, _ in
                // The end picker is bounded by the start day, but moving the start later must not
                // leave an end date behind it.
                if endDate < startDay { endDate = startDay }
            }
            .onChange(of: amount) { oldValue, newValue in
                let formatted = AmountInputFormatter.formatEditingText(newValue, previous: oldValue)
                if formatted != newValue { amount = formatted }
            }
        }
    }

    private var detailsSection: some View {
        Section("expense_details".localized) {
            TextField("title".localized, text: $title)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = .amount }
                .accessibilityIdentifier("recurringTitleField")

            HStack {
                Text("amount".localized)
                Spacer()
                TextField("0", text: $amount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focusedField, equals: .amount)
                    .frame(maxWidth: 160)
                    .accessibilityIdentifier("recurringAmountField")
                Text(dataManager.user.currency.symbol)
                    .foregroundStyle(.secondary)
            }

            RecurringCategoryPicker(selectedCategory: $selectedCategory) {
                showingCategoryManagement = true
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("frequency".localized, selection: $recurrence) {
                ForEach(RecurrenceType.allCases, id: \.self) { type in
                    Text(type.localizedName).tag(type)
                }
            }
            .accessibilityIdentifier("recurringFrequencyPicker")

            DatePicker("start_date".localized, selection: $startDate, displayedComponents: .date)
                .accessibilityIdentifier("recurringStartDatePicker")

            Toggle("set_end_date".localized, isOn: $hasEndDate.animation())
                .accessibilityIdentifier("recurringEndDateToggle")

            if hasEndDate {
                DatePicker("end_date".localized, selection: $endDate, in: startDay..., displayedComponents: .date)
                    .accessibilityIdentifier("recurringEndDatePicker")
            }
        } header: {
            Text("recurrence".localized)
        } footer: {
            if isEditing {
                Text("recurring_schedule_footer".localized)
            }
        }
    }

    private func statusSection(for stored: RecurringExpense) -> some View {
        Section("status".localized) {
            if let lastProcessed = stored.lastProcessedDate {
                LabeledContent("last_processed".localized) {
                    Text(lastProcessed.formatted(date: .abbreviated, time: .omitted))
                }
            }
            LabeledContent("next_due".localized) {
                if !stored.isActive {
                    Text("recurring_paused".localized)
                } else if stored.isExpired {
                    Text("expired".localized)
                } else {
                    Text(stored.nextDueDate.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
    }

    /// Past occurrences that saving will record immediately (a new bill starting last month).
    private var backfillNote: String? {
        guard isActive else { return nil }
        if let existing, existing.lastProcessedDate != nil || !existing.isActive { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lastDay = hasEndDate ? min(calendar.startOfDay(for: endDate), today) : today
        var count = 0
        var index = 0
        while count < 1_000 {
            let date = recurrence.occurrence(index, from: startDate)
            guard date < today, date <= lastDay else { break }
            count += 1
            index += 1
        }
        let since = startDay.formatted(date: .abbreviated, time: .omitted)
        switch count {
        case 0: return nil
        case 1: return String(format: "recurring_backfill_one_format".localized, since)
        default: return String(format: "recurring_backfill_format".localized, count, since)
        }
    }

    private var canSave: Bool {
        guard let value = AmountInputFormatter.parse(amount), value > 0, value.isFinite else { return false }
        if hasEndDate && Calendar.current.startOfDay(for: endDate) < startDay { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedCategory != nil
    }

    private func save() {
        guard canSave, let amountValue = AmountInputFormatter.parse(amount), let categoryId = selectedCategory?.id else { return }
        let calendar = Calendar.current
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = hasEndDate ? max(calendar.startOfDay(for: endDate), startDay) : nil

        if var updated = existing {
            updated.title = cleanTitle
            updated.amount = amountValue
            updated.categoryId = categoryId
            updated.recurrenceType = recurrence
            updated.startDate = startDay
            updated.endDate = end
            updated.isActive = isActive
            dataManager.updateRecurringExpense(updated)
        } else {
            var newRecurring = RecurringExpense(
                title: cleanTitle,
                amount: amountValue,
                categoryId: categoryId,
                recurrenceType: recurrence,
                startDate: startDay,
                endDate: end
            )
            newRecurring.isActive = isActive
            dataManager.addRecurringExpense(newRecurring)
        }
        dismiss()
    }

    private func delete() {
        guard let existing else { return }
        dataManager.deleteRecurringExpense(existing)
        dismiss()
    }
}

// MARK: - Shared Category Picker

struct RecurringCategoryPicker: View {
    @Binding var selectedCategory: UserCategory?
    var onCreateNew: () -> Void
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        HStack {
            Text("category".localized)
            Spacer()
            Menu {
                ForEach(dataManager.userCategories) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        HeroIconLabel(title: category.name, systemName: category.iconSystemName)
                    }
                }
                Divider()
                Button(action: onCreateNew) {
                    HeroIconLabel(title: "create_new_category".localized, systemName: "plus.circle")
                }
            } label: {
                HStack(spacing: 6) {
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
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("recurringCategoryPicker")
        }
    }
}

// MARK: - Recurrence Preview

/// The next few charges from today (or from the start day, if it is later).
struct RecurrencePreviewView: View {
    let recurrenceType: RecurrenceType
    let startDate: Date
    let endDate: Date?

    private static let limit = 5

    private var upcomingDates: [Date] {
        RecurrencePreviewView.upcomingDates(recurrenceType: recurrenceType, startDate: startDate, endDate: endDate, limit: Self.limit + 1)
    }

    static func upcomingDates(
        recurrenceType: RecurrenceType,
        startDate: Date,
        endDate: Date?,
        from today: Date = Date(),
        limit: Int,
        calendar: Calendar = .current
    ) -> [Date] {
        let firstDay = calendar.startOfDay(for: today)
        let lastDay = endDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
        var result: [Date] = []
        var index = 0
        // Daily schedules started years ago need many steps; the cap only guards bad dates.
        while result.count < limit && index < 20_000 {
            let date = recurrenceType.occurrence(index, from: startDate, calendar: calendar)
            if date > lastDay { break }
            if date >= firstDay { result.append(date) }
            index += 1
        }
        return result
    }

    var body: some View {
        let dates = upcomingDates
        let startDay = Calendar.current.startOfDay(for: startDate)

        VStack(alignment: .leading, spacing: 8) {
            Text("upcoming_occurrences".localized)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(dates.prefix(Self.limit).enumerated()), id: \.offset) { index, date in
                    HStack {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)

                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.primary)

                        if date == startDay {
                            Text("(\("start".localized))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .font(.caption.monospacedDigit())
                }

                if dates.count > Self.limit {
                    Text("…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AddRecurringExpenseView()
}
