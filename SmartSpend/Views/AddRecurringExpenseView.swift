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
    @State private var showingCategoryGrid = false
    @Environment(\.colorScheme) private var colorScheme
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
                } header: {
                    StreetSectionHeader(title: "status".localized)
                } footer: {
                    Text("recurring_active_footer".localized)
                }
                .listRowBackground(NightTheme.glassFill)

                if let stored {
                    statusSection(for: stored)
                }

                Section {
                    RecurrencePreviewView(
                        recurrenceType: recurrence,
                        startDate: startDate,
                        endDate: hasEndDate ? endDate : nil,
                        amount: AmountInputFormatter.parse(amount),
                        currency: dataManager.user.currency
                    )
                } header: {
                    StreetSectionHeader(title: "upcoming_occurrences".localized)
                } footer: {
                    if let note = backfillNote {
                        Text(note)
                    }
                }
                .listRowBackground(NightTheme.glassFill)

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("recurring_delete_button".localized, systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("recurringDeleteButton")
                    }
                    .listRowBackground(NightTheme.glassFill)
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .tint(NightTheme.accent)
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .navigationTitle((isEditing ? "edit_recurring_expense" : "add_recurring_expense").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel".localized) { dismiss() }
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

    /// Save as the white capsule at the bottom, like Add expense.
    private var saveBar: some View {
        Button("save".localized, action: save)
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .disabled(!canSave)
            .accessibilityIdentifier("recurringSaveButton")
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(NightGround())
    }

    private var detailsSection: some View {
        Section {
            TextField("title".localized, text: $title)
                .textInputAutocapitalization(.words)
                .submitLabel(.next)
                .focused($focusedField, equals: .title)
                .onSubmit { focusedField = .amount }
                .accessibilityIdentifier("recurringTitleField")

            HStack(alignment: .firstTextBaseline) {
                Text("amount".localized)
                    .foregroundStyle(NightTheme.secondaryLabel)
                Spacer()
                TextField("0", text: $amount)
                    .font(NightTheme.display(28, relativeTo: .title))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focusedField, equals: .amount)
                    .accessibilityIdentifier("recurringAmountField")
                Text(dataManager.user.currency.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NightTheme.secondaryLabel)
            }

            // Category: a row that opens the same inline tile grid as Add expense.
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
            .accessibilityIdentifier("recurringCategoryPicker")
            .accessibilityValue(selectedCategory?.name ?? "select_category".localized)

            if showingCategoryGrid {
                CategoryTileGrid(categories: dataManager.userCategories, selectedID: selectedCategory?.id) { category in
                    selectedCategory = category
                    withAnimation(.snappy(duration: 0.3)) { showingCategoryGrid = false }
                } onCreate: {
                    showingCategoryManagement = true
                }
            }
        } header: {
            StreetSectionHeader(title: "expense_details".localized, figure: .walker)
        }
        .listRowBackground(NightTheme.glassFill)
    }

    private var scheduleSection: some View {
        Section {
            frequencyGrid
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
            StreetSectionHeader(title: "recurrence".localized)
        } footer: {
            if isEditing {
                Text("recurring_schedule_footer".localized)
            }
        }
        .listRowBackground(NightTheme.glassFill)
    }

    /// All six frequencies as cells, three per row; the chosen one is filled with the accent.
    private var frequencyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(RecurrenceType.allCases, id: \.self) { type in
                let isOn = recurrence == type
                Button {
                    withAnimation(.snappy(duration: 0.2)) { recurrence = type }
                } label: {
                    Text(type.localizedName)
                        .font(.subheadline.weight(isOn ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(isOn ? (colorScheme == .dark ? NightTheme.ink : Color.white) : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: iOSDesignSystem.Size.minimumTapTarget)
                        .background(isOn ? NightTheme.accent : NightTheme.iconFill,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("frequency".localized)
    }

    private func statusSection(for stored: RecurringExpense) -> some View {
        Section {
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
                        .foregroundStyle(stored.isOverdue ? RecurringStatusColor.overdue : NightTheme.secondaryLabel)
                }
            }
        }
        .listRowBackground(NightTheme.glassFill)
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

// MARK: - Recurrence Preview

/// The next few charges from today (or from the start day, if it is later).
struct RecurrencePreviewView: View {
    let recurrenceType: RecurrenceType
    let startDate: Date
    let endDate: Date?
    var amount: Double? = nil
    var currency: Currency? = nil

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

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dates.prefix(Self.limit).enumerated()), id: \.offset) { index, date in
                if index > 0 {
                    Rectangle().fill(NightTheme.hair).frame(height: 1)
                }
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .frame(width: 18, alignment: .leading)

                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.primary)

                    if date == startDay {
                        Text("(\("start".localized))")
                            .font(.caption)
                            .foregroundStyle(NightTheme.secondaryLabel)
                    }

                    Spacer()

                    if let amount, amount > 0, let currency {
                        Text(CurrencyFormatter.format(amount, currency: currency))
                            .foregroundStyle(NightTheme.secondaryLabel)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .padding(.vertical, 9)
            }

            if dates.count > Self.limit {
                Text("…")
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .padding(.leading, 28)
                    .padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AddRecurringExpenseView()
}
