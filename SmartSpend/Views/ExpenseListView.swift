import SwiftUI

struct ExpenseListView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var voice = InlineVoiceExpenseController()

    // Filtering. Results are cached and recomputed only when an input changes,
    // not on every view update (voice state, selection taps, etc.).
    @State private var query = ExpenseListQuery()
    @State private var results: [Expense] = []
    @State private var resultsTotal: Double = 0
    @State private var groups: [ExpenseDayGroup] = []
    @State private var visibleLimit = ExpenseListView.initialPageSize

    // Presentation
    @State private var showingAddExpense = false
    @State private var showingFilterSheet = false
    @State private var showingRangePicker = false
    @State private var openRangeAfterFilter = false
    @State private var showingDeleted = false
    @State private var editingExpense: Expense?

    // Selection & undo
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var undoBatch: UndoBatch?

    private static let initialPageSize = 40
    private static let pageSize = 60

    private struct UndoBatch: Equatable {
        let id = UUID()
        let expenseIds: [UUID]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .opacity(voice.isVisible && voice.prefill == nil ? 0 : 1)
                    .allowsHitTesting(!voice.isVisible || voice.prefill != nil)
                    .accessibilityHidden(voice.isVisible && voice.prefill == nil)

                if !dataManager.expenses.isEmpty {
                    AppSearchField(text: $query.searchText, prompt: "search_expenses".localized, style: .glass)
                        .padding(.bottom, iOSDesignSystem.Spacing.small)
                    filterChips
                }

                content
            }
            .background(NightGround())
            .expenseEntryBar(ExpenseEntryBar(accessibilityPrefix: "expenses", compact: true, isRecording: voice.isRecording, isProcessing: voice.isProcessing, onAdd: {
                showingAddExpense = true
            }, onVoice: {
                voice.start()
            }, onStop: { voice.stop() }), hidden: isSelecting)
            .overlay(alignment: .bottom) { bottomBars }
            .voiceExpenseOverlay(controller: voice)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .fullScreenCover(item: $voice.prefill, onDismiss: { voice.reviewDidDismiss() }) { item in
                AddExpenseView(prefill: item) { voice.didSave() }
            }
            .sheet(item: $voice.batch, onDismiss: { voice.batchDidDismiss() }) { batch in
                VoiceExpenseBatchView(batch: batch)
            }
            .sheet(item: $editingExpense) { expense in
                EditExpenseView(expense: expense) { archive([expense]) }
                    .tint(NightTheme.accent)
            }
            .sheet(isPresented: $showingFilterSheet, onDismiss: {
                // Present the range picker only once the filter sheet is gone;
                // presenting both at once drops the second sheet.
                if openRangeAfterFilter {
                    openRangeAfterFilter = false
                    showingRangePicker = true
                }
            }) {
                ExpenseFilterSheet(
                    categories: sortedCategories,
                    query: query,
                    onApply: { period, categoryIds in
                        query.period = period
                        query.categoryIds = categoryIds
                    },
                    onPickCustomRange: { categoryIds in
                        query.categoryIds = categoryIds
                        openRangeAfterFilter = true
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .tint(NightTheme.accent)
            }
            .sheet(isPresented: $showingRangePicker) {
                CalendarPickerView(
                    selectedStartDate: $query.customStart,
                    selectedEndDate: $query.customEnd,
                    selectedPeriod: $query.period
                )
                .presentationDetents([.fraction(0.85)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .tint(NightTheme.accent)
            }
            .navigationDestination(isPresented: $showingDeleted) {
                DeletedExpensesView()
                    .tint(NightTheme.accent)
            }
            .onAppear(perform: refresh)
            .onDisappear { voice.cancel() }
            .onChange(of: query) { _, _ in
                visibleLimit = Self.initialPageSize
                refresh()
            }
            .onChange(of: dataManager.expenses) { _, _ in refresh() }
            .onChange(of: dataManager.userCategories) { _, categories in
                // A deleted category must not leave an invisible, un-clearable filter behind.
                let existing = Set(categories.map(\.id))
                if !query.categoryIds.isSubset(of: existing) {
                    query.categoryIds.formIntersection(existing)
                } else {
                    refresh()
                }
            }
            .onChange(of: visibleLimit) { _, limit in
                groups = ExpenseDayGroup.make(from: results, limit: limit)
            }
            .onChange(of: scenePhase) { _, phase in
                // "Today" / "This week" move on after midnight.
                if phase == .active { refresh() }
            }
            .task(id: undoBatch?.id) {
                guard undoBatch != nil else { return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { undoBatch = nil }
            }
        }
        .tint(NightTheme.accent)
    }

    // MARK: - Derived data

    private var currency: Currency { dataManager.user.currency }

    private var sortedCategories: [UserCategory] {
        dataManager.userCategories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var categoryLookup: [UUID: UserCategory] {
        Dictionary(dataManager.userCategories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func refresh() {
        let names = categoryLookup.mapValues(\.name)
        results = query.apply(to: dataManager.expenses, categoryNames: names)
        resultsTotal = results.reduce(0) { $0 + $1.amount }
        groups = ExpenseDayGroup.make(from: results, limit: visibleLimit)
        // Selections hidden by a filter or removed elsewhere must not be deleted unseen.
        let visible = Set(results.map(\.id))
        if !selection.isSubset(of: visible) {
            selection.formIntersection(visible)
        }
    }

    private var periodTitle: String {
        switch query.period {
        case .all: return "time_period_all".localized
        case .custom: return ExpenseRangeText.text(from: query.customStart, through: query.customEnd)
        default: return query.period.localizedName
        }
    }

    private var allResultsSelected: Bool {
        !results.isEmpty && results.count == selection.count
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("expenses".localized)
                    .font(NightTheme.display(46))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .capFigure(isSelecting ? nil : .shopper, fontSize: 46, relativeTo: .largeTitle)
                    .accessibilityAddTraits(.isHeader)
                headerSubtitle
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if isSelecting {
                    Button(allResultsSelected ? "exp_deselect_all".localized : "exp_select_all".localized) {
                        withAnimation(.snappy) {
                            selection = ExpenseSelection.toggleAll(selected: selection, visible: results.map(\.id))
                        }
                    }
                    .font(.body.weight(.medium))
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .disabled(results.isEmpty)

                    Button("done".localized, action: endSelection)
                        .font(.body.weight(.semibold))
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                        .padding(.leading, 10)
                } else {
                    if !dataManager.expenses.isEmpty {
                        filterButton
                    }
                    moreMenu
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    /// "This month · 42 items · 3 184 000 so'm" for what is shown; "N selected" while selecting.
    @ViewBuilder
    private var headerSubtitle: some View {
        if isSelecting {
            Text(String(format: "selected_count".localized, selection.count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NightTheme.secondaryLabel)
        } else if !dataManager.expenses.isEmpty {
            let prefix = "\(periodTitle) · \(String(format: "exp_items_count_format".localized, results.count)) · "
            let total = Text(CurrencyFormatter.format(resultsTotal, currency: currency)).foregroundStyle(.primary)
            Text("\(prefix)\(total)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// A 44 pt white glass circle for header actions.
    private func headerCircle<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(NightTheme.accent)
            .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
            .background(NightTheme.glassFill, in: Circle())
            .overlay(Circle().stroke(NightTheme.glassLine, lineWidth: 1))
            .contentShape(Circle())
    }

    private var groundColor: Color {
        colorScheme == .dark ? NightTheme.ink : Color(.systemGroupedBackground)
    }

    private var filterButton: some View {
        Button {
            showingFilterSheet = true
        } label: {
            headerCircle { HeroIcon("funnel", size: 22) }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if query.hasFilters {
                Circle()
                    .fill(NightTheme.accent)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(groundColor, lineWidth: 2))
                    .offset(x: -5, y: 5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("filter".localized)
        .accessibilityValue(query.hasFilters ? "exp_filters_on".localized : "")
        .accessibilityIdentifier("expenses.filter")
    }

    private var moreMenu: some View {
        Menu {
            if !results.isEmpty {
                Button {
                    withAnimation(.snappy) { isSelecting = true }
                } label: {
                    Label("exp_select".localized, systemImage: "checkmark.circle")
                }
            }
            Button {
                showingDeleted = true
            } label: {
                Label("deleted_expenses".localized, systemImage: "trash")
                if !dataManager.deletedExpenses.isEmpty {
                    Text(String(format: "exp_items_count_format".localized, dataManager.deletedExpenses.count))
                }
            }
        } label: {
            headerCircle {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .accessibilityLabel("exp_more_actions".localized)
        .accessibilityIdentifier("expenses.more")
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: iOSDesignSystem.Spacing.small) {
                ForEach(ExpensePeriod.quickPeriods, id: \.self) { period in
                    chip(period.localizedName, isOn: query.period == period) {
                        query.period = period
                    }
                }

                chip(query.period == .custom ? ExpenseRangeText.text(from: query.customStart, through: query.customEnd) : "exp_custom_range".localized,
                     systemImage: "calendar",
                     isOn: query.period == .custom) {
                    showingRangePicker = true
                }

                if !query.categoryIds.isEmpty {
                    chip(categoryChipTitle, systemImage: "xmark", isOn: true) {
                        withAnimation(.snappy) { query.categoryIds.removeAll() }
                    }
                    .accessibilityHint("exp_remove_category_filter".localized)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, iOSDesignSystem.Spacing.small)
        .disabled(isSelecting)
        .opacity(isSelecting ? 0.5 : 1)
    }

    private var categoryChipTitle: String {
        let names = sortedCategories.filter { query.categoryIds.contains($0.id) }.map(\.name)
        if names.count == 1 { return names[0] }
        return String(format: "exp_categories_count_format".localized, names.count)
    }

    private func chip(_ title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage, systemImage != "xmark" {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(isOn ? .semibold : .medium))
                    .lineLimit(1)
                if systemImage == "xmark" {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(isOn ? (colorScheme == .dark ? NightTheme.ink : Color.white) : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isOn ? NightTheme.accent : NightTheme.glassFill, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : NightTheme.glassLine, lineWidth: 1))
            .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if dataManager.expenses.isEmpty {
            emptyState
        } else if results.isEmpty {
            noResults
                .frame(maxHeight: .infinity)
        } else {
            expenseList
        }
    }

    /// A small dark street with one unlit building: nothing spent yet.
    private var emptyState: some View {
        VStack(spacing: 0) {
            EmptyStreetView()
            Text("exp_empty_title".localized)
                .font(NightTheme.display(34))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
            Text("exp_empty_body".localized)
                .font(.subheadline)
                .foregroundStyle(NightTheme.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .padding(.top, 10)
        }
        .padding(.horizontal, 32)
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var noResults: some View {
        if query.isSearching && !query.hasFilters {
            ContentUnavailableView.search(text: query.trimmedSearch)
        } else {
            VStack(spacing: 10) {
                Text("no_expenses_found".localized)
                    .font(NightTheme.display(30))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(query.isSearching
                     ? String(format: "exp_no_matches_in_period_format".localized, query.trimmedSearch, periodTitle)
                     : String(format: "exp_nothing_in_period_format".localized, periodTitle))
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                Button("exp_clear_filters".localized, action: clearFilters)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .background(NightTheme.glassFill, in: Capsule())
                    .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
    }

    private var expenseList: some View {
        let lookup = categoryLookup
        let fallback = UserCategory.createDefault()
        return List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.expenses) { expense in
                        row(expense, category: lookup[expense.categoryId] ?? fallback)
                    }
                } header: {
                    dayHeader(group)
                }
            }

            if results.count > visibleLimit {
                loadMoreRow
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // Keeps the last rows scrollable above the entry bar and floating tab bar.
        .contentMargins(.bottom, 76 + tabBarClearance, for: .scrollContent)
        .animation(.snappy(duration: 0.25), value: isSelecting)
    }

    /// Big Shoulders day title with the day total; the snacker stands on "Today".
    private func dayHeader(_ group: ExpenseDayGroup) -> some View {
        let isToday = Calendar.current.isDateInToday(group.day)
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(ExpenseDayGroup.title(for: group.day))
                .font(NightTheme.display(21, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .capFigure(isToday ? .snacker : nil, fontSize: 21, relativeTo: .title3, weight: .semibold, height: 22, gap: 6)
            Spacer(minLength: 8)
            Text(CurrencyFormatter.format(group.total, currency: currency))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
        }
        .textCase(nil)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ expense: Expense, category: UserCategory) -> some View {
        let isSelected = selection.contains(expense.id)
        return Button {
            if isSelecting {
                toggleSelection(expense.id)
            } else {
                editingExpense = expense
            }
        } label: {
            ExpenseRowView(
                expense: expense,
                category: category,
                currency: currency,
                selection: isSelecting ? isSelected : nil
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelecting && isSelected ? NightTheme.accent.opacity(0.14) : NightTheme.glassFill)
        .listRowSeparatorTint(NightTheme.hair)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isSelecting {
                Button(role: .destructive) {
                    archive([expense])
                } label: {
                    Label("delete".localized, systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            if !isSelecting {
                Button {
                    editingExpense = expense
                } label: {
                    Label("exp_edit".localized, systemImage: "pencil")
                }
                .tint(Color(.systemGray))
            }
        }
        .contextMenu {
            if !isSelecting {
                Button {
                    editingExpense = expense
                } label: {
                    Label("exp_edit".localized, systemImage: "pencil")
                }
                Button {
                    duplicate(expense)
                } label: {
                    Label("exp_add_again".localized, systemImage: "plus.square.on.square")
                }
                Divider()
                Button(role: .destructive) {
                    archive([expense])
                } label: {
                    Label("delete".localized, systemImage: "trash")
                }
            }
        }
    }

    private var loadMoreRow: some View {
        HStack(spacing: iOSDesignSystem.Spacing.small) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("exp_loading_more".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .onAppear { visibleLimit += Self.pageSize }
    }

    // MARK: - Bottom bars

    @ViewBuilder
    private var bottomBars: some View {
        if isSelecting {
            selectionBar
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.bottom, 12 + tabBarClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let undoBatch {
            undoToast(undoBatch)
                // Sits above the entry bar's 44pt buttons.
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.bottom, 12 + 44 + 12 + tabBarClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var selectionBar: some View {
        let selected = ExpenseSelection.deletable(from: results, selected: selection)
        let total = selected.reduce(0) { $0 + $1.amount }
        return HStack(spacing: iOSDesignSystem.Spacing.medium) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "selected_count".localized, selected.count))
                    .font(.subheadline.weight(.semibold))
                if !selected.isEmpty {
                    Text(CurrencyFormatter.format(total, currency: currency))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("delete".localized, systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Color(.systemRed).opacity(selected.isEmpty ? 0.35 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .accessibilityIdentifier("expenses.delete-selected")
        }
        .padding(.leading, iOSDesignSystem.Spacing.large)
        .padding(.trailing, iOSDesignSystem.Spacing.small)
        .padding(.vertical, iOSDesignSystem.Spacing.small)
        .liquidGlassSurface(Capsule())
    }

    private func undoToast(_ batch: UndoBatch) -> some View {
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            HeroIcon("trash", size: 18)
                .foregroundStyle(NightTheme.secondaryLabel)
            Text(String(format: "exp_moved_to_deleted_format".localized, batch.expenseIds.count))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("exp_undo".localized) { undo(batch) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                .accessibilityIdentifier("expenses.undo-delete")
        }
        .padding(.horizontal, iOSDesignSystem.Spacing.large)
        .liquidGlassSurface(Capsule())
    }

    // MARK: - Actions

    private func clearFilters() {
        withAnimation(.snappy) {
            query.period = .all
            query.categoryIds.removeAll()
            query.searchText = ""
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func endSelection() {
        withAnimation(.snappy) {
            isSelecting = false
            selection.removeAll()
        }
    }

    private func deleteSelected() {
        let toDelete = ExpenseSelection.deletable(from: results, selected: selection)
        archive(toDelete)
        endSelection()
    }

    /// Moves expenses to Deleted (recoverable for 30 days) and offers an undo.
    private func archive(_ expenses: [Expense]) {
        guard !expenses.isEmpty else { return }
        withAnimation(.snappy) {
            dataManager.moveToDeletedExpenses(expenses)
            undoBatch = UndoBatch(expenseIds: expenses.map(\.id))
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func undo(_ batch: UndoBatch) {
        withAnimation(.snappy) {
            dataManager.restoreExpenses(ids: Set(batch.expenseIds))
            undoBatch = nil
        }
    }

    private func duplicate(_ expense: Expense) {
        dataManager.addExpense(Expense(title: expense.title, amount: expense.amount,
                                       categoryId: expense.categoryId, date: Date()))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}


struct CalendarPickerView: View {
    @Binding var selectedStartDate: Date
    @Binding var selectedEndDate: Date
    @Binding var selectedPeriod: ExpensePeriod
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentMonth: Date = Date()
    @State private var selectionStep: SelectionStep = .startDate
    @State private var tempStartDate: Date = Date()
    @State private var tempEndDate: Date = Date()
    
    enum SelectionStep {
        case startDate
        case endDate
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                NightGround()

                ScrollView {
                    VStack(spacing: iOSDesignSystem.Spacing.large) {
                        headerSection
                        calendarSection
                    }
                    .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                    .padding(.top, iOSDesignSystem.Spacing.small)
                    .padding(.bottom, iOSDesignSystem.Spacing.large)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("custom_date_range".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        applySelection()
                    }
                    .fontWeight(.semibold)
                    .disabled(!selectionIsValid)
                }
            }
        }
        .onAppear {
            currentMonth = selectedStartDate
            tempStartDate = selectedStartDate
            tempEndDate = selectedEndDate
            selectionStep = .startDate
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.medium) {
            HStack(spacing: iOSDesignSystem.Spacing.small) {
                HeroIcon("calendar-days", size: 18)
                    .foregroundStyle(NightTheme.accent)

                Text(instructionText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, iOSDesignSystem.Spacing.xSmall)

            HStack(spacing: iOSDesignSystem.Spacing.small) {
                selectionCard(
                    title: "date_from".localized,
                    date: tempStartDate,
                    isActive: selectionStep == .startDate
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectionStep = .startDate
                    }
                }

                HeroIcon("arrow-right", size: 15)
                    .foregroundStyle(.tertiary)

                selectionCard(
                    title: "date_to".localized,
                    date: tempEndDate,
                    isActive: selectionStep == .endDate
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectionStep = .endDate
                    }
                }
            }

            rangeDetails
        }
        .padding(.top, iOSDesignSystem.Spacing.small)
    }

    private func selectionCard(title: String, date: Date, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.small) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isActive ? NightTheme.accent : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? NightTheme.accent : .secondary)
                }

                Text(localizedDateString(from: date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(iOSDesignSystem.Spacing.medium)
            .frame(minHeight: 72)
            .background(NightTheme.glassFill,
                        in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                    .stroke(NightTheme.glassLine, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                    .stroke(isActive ? NightTheme.accent.opacity(0.55) : Color.clear, lineWidth: 1.25)
            )
        }
        .buttonStyle(.plain)
    }

    private var rangeDetails: some View {
        HStack(spacing: iOSDesignSystem.Spacing.small) {
            HeroIconLabel(title: rangeLengthText, systemName: "arrow.left.and.right", iconSize: 18)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    resetRange()
                }
            } label: {
                HStack(spacing: 5) {
                    HeroIcon("arrow-path", size: 14)
                    Text("reset".localized)
                }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(NightTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, iOSDesignSystem.Spacing.medium)
        .padding(.trailing, iOSDesignSystem.Spacing.xSmall)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.medium, style: .continuous)
                .fill(NightTheme.iconFill)
        )
    }

    private var rangeLengthText: String {
        let calendar = Calendar.current
        let dayDelta = calendar.dateComponents([.day], from: tempStartDate, to: tempEndDate).day ?? 0
        let totalDays = max(dayDelta, 0) + 1
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day]
        formatter.maximumUnitCount = 1
        return formatter.string(from: DateComponents(day: totalDays)) ?? "\(totalDays) d"
    }

    private func resetRange() {
        tempStartDate = selectedStartDate
        tempEndDate = selectedEndDate
        selectionStep = .startDate
    }

    private var calendarSection: some View {
        VStack(spacing: iOSDesignSystem.Spacing.medium) {
            monthNavigation

            Rectangle()
                .fill(NightTheme.hair)
                .frame(height: 1)

            VStack(spacing: 12) {
                weekdayHeader
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                    ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                        if let date = date {
                            CalendarDayView(
                                date: date,
                                state: dayState(for: date),
                                isCurrentMonth: Calendar.current.isDate(date, equalTo: currentMonth, toGranularity: .month),
                                action: { selectDate(date) }
                            )
                        } else {
                            Color.clear
                                .frame(height: 40)
                        }
                    }
                }
            }
        }
        .padding(iOSDesignSystem.Spacing.medium)
        .nightGroup()
    }

    private var monthNavigation: some View {
        HStack {
            Button(action: previousMonth) {
                HeroIcon(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NightTheme.accent)
                    .iOSMinimumTapTarget()
                    .background(NightTheme.glassFill, in: Circle())
                    .overlay(Circle().stroke(NightTheme.glassLine, lineWidth: 1))
            }
            
            Spacer()
            
            Text(monthYearString(from: currentMonth))
                .font(.headline.weight(.semibold))
                .contentTransition(.opacity)
            
            Spacer()
            
            Button(action: nextMonth) {
                HeroIcon(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NightTheme.accent)
                    .iOSMinimumTapTarget()
                    .background(NightTheme.glassFill, in: Circle())
                    .overlay(Circle().stroke(NightTheme.glassLine, lineWidth: 1))
            }
        }
    }
    
    private var weekdayHeader: some View {
        let symbols = weekdaySymbols
        return HStack(spacing: 0) {
            ForEach(symbols, id: \.self) { day in
                Text(day)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
    
    private var calendarDays: [Date?] {
        let calendar = Calendar.current
        let startOfMonth = calendar.dateInterval(of: .month, for: currentMonth)?.start ?? currentMonth
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: startOfMonth)?.start ?? startOfMonth
        
        var days: [Date?] = []
        let endDate = calendar.date(byAdding: .day, value: 41, to: startOfWeek) ?? startOfWeek
        
        var currentDate = startOfWeek
        while currentDate < endDate {
            if calendar.isDate(currentDate, equalTo: currentMonth, toGranularity: .month) {
                days.append(currentDate)
            } else {
                days.append(nil)
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }
        
        return days
    }
    
    private func previousMonth() {
        withAnimation(.snappy(duration: 0.22)) {
            currentMonth = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
        }
    }
    
    private func nextMonth() {
        withAnimation(.snappy(duration: 0.22)) {
            currentMonth = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
        }
    }
    
    private func selectDate(_ date: Date) {
        withAnimation(.snappy(duration: 0.2)) {
            switch selectionStep {
            case .startDate:
                tempStartDate = date
                if tempEndDate < tempStartDate {
                    tempEndDate = tempStartDate
                }
                selectionStep = .endDate
            case .endDate:
                if date < tempStartDate {
                    tempStartDate = date
                    tempEndDate = date
                    selectionStep = .endDate
                } else {
                    tempEndDate = date
                    selectionStep = .startDate
                }
            }
        }
    }

    private func applySelection() {
        selectedStartDate = tempStartDate
        selectedEndDate = tempEndDate
        selectedPeriod = .custom
        dismiss()
    }
    
    private func dayState(for date: Date) -> CalendarDayView.DayState {
        let calendar = Calendar.current
        let isStart = calendar.isDate(date, inSameDayAs: tempStartDate)
        let isEnd = calendar.isDate(date, inSameDayAs: tempEndDate)
        
        if isStart && isEnd {
            return .single
        } else if isStart {
            return .start
        } else if isEnd {
            return .end
        } else if date > Calendar.current.startOfDay(for: tempStartDate) && date < tempEndDate {
            return .inRange
        } else {
            return .none
        }
    }
    
    private var instructionText: String {
        switch selectionStep {
        case .startDate:
            return "date_range_instruction_first".localized
        case .endDate:
            return "date_range_instruction_second".localized
        }
    }

    private var selectionIsValid: Bool {
        tempEndDate >= tempStartDate
    }
    
    private func monthYearString(from date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    private func localizedDateString(from date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private var weekdaySymbols: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let firstIndex = max(min(calendar.firstWeekday - 1, symbols.count - 1), 0)
        if firstIndex == 0 { return symbols }
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }
}

struct CalendarDayView: View {
    enum DayState: Equatable {
        case none
        case inRange
        case start
        case end
        case single
    }
    
    let date: Date
    let state: DayState
    let isCurrentMonth: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                rangeBackground

                if Calendar.current.isDateInToday(date) && !showsSelection {
                    Circle()
                        .stroke(NightTheme.accent.opacity(0.45), lineWidth: 1)
                        .frame(width: 34, height: 34)
                }
                
                if showsSelection {
                    Circle()
                        .fill(NightTheme.accent)
                        .frame(width: 36, height: 36)
                }
                
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 15, weight: showsSelection ? .semibold : .regular))
                    .foregroundStyle(textColor)
            }
            .frame(maxWidth: .infinity, minHeight: iOSDesignSystem.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: state)
    }
    
    private var showsSelection: Bool {
        switch state {
        case .start, .end, .single:
            return true
        default:
            return false
        }
    }
    
    private var textColor: Color {
        if showsSelection {
            return colorScheme == .dark ? NightTheme.ink : .white
        } else if isCurrentMonth {
            return Color(.label)
        } else {
            return Color(.tertiaryLabel)
        }
    }
    
    private var rangeBackground: some View {
        Group {
            if state == .inRange {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(NightTheme.accent.opacity(0.14))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Filter Sheet

/// Period and category filters. Changes are drafted and applied on Done,
/// so swiping the sheet away leaves the list untouched.
struct ExpenseFilterSheet: View {
    let categories: [UserCategory]
    let customRangeText: String
    var onApply: (ExpensePeriod, Set<UUID>) -> Void
    var onPickCustomRange: (Set<UUID>) -> Void

    @State private var draftPeriod: ExpensePeriod
    @State private var draftCategoryIds: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(
        categories: [UserCategory],
        query: ExpenseListQuery,
        onApply: @escaping (ExpensePeriod, Set<UUID>) -> Void,
        onPickCustomRange: @escaping (Set<UUID>) -> Void
    ) {
        self.categories = categories
        self.customRangeText = ExpenseRangeText.text(from: query.customStart, through: query.customEnd)
        self.onApply = onApply
        self.onPickCustomRange = onPickCustomRange
        self._draftPeriod = State(initialValue: query.period)
        self._draftCategoryIds = State(initialValue: query.categoryIds)
    }

    private var hasDraftFilters: Bool {
        draftPeriod != .all || !draftCategoryIds.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ExpensePeriod.quickPeriods, id: \.self) { period in
                        checkRow(isOn: draftPeriod == period) {
                            Text(period.localizedName)
                        } action: {
                            draftPeriod = period
                        }
                    }

                    Button {
                        onPickCustomRange(draftCategoryIds)
                        dismiss()
                    } label: {
                        HStack {
                            Label {
                                Text("custom_date_range".localized)
                            } icon: {
                                HeroIcon("calendar-days", size: 20)
                                    .foregroundStyle(NightTheme.accent)
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            if draftPeriod == .custom {
                                Text(customRangeText)
                                    .foregroundStyle(NightTheme.secondaryLabel)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityAddTraits(draftPeriod == .custom ? .isSelected : [])
                } header: {
                    sectionTitle("time_period".localized)
                }
                .listRowBackground(NightTheme.glassFill)

                Section {
                    if categories.isEmpty {
                        Text("exp_no_categories".localized)
                            .foregroundStyle(.secondary)
                    } else {
                        checkRow(isOn: draftCategoryIds.isEmpty) {
                            Text("exp_all_categories".localized)
                        } action: {
                            draftCategoryIds.removeAll()
                        }

                        ForEach(categories) { category in
                            checkRow(isOn: draftCategoryIds.contains(category.id)) {
                                Label {
                                    Text(category.name)
                                } icon: {
                                    HeroIcon(systemName: category.iconSystemName, size: 20)
                                        .foregroundStyle(NightTheme.accent)
                                }
                            } action: {
                                toggle(category.id)
                            }
                        }
                    }
                } header: {
                    sectionTitle("category".localized)
                } footer: {
                    Text("filter_category_hint".localized)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .listRowBackground(NightTheme.glassFill)
            }
            .listStyle(.insetGrouped)
            .listRowSeparatorTint(NightTheme.hair)
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .navigationTitle("filter".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("reset".localized) {
                        withAnimation(.snappy) {
                            draftPeriod = .all
                            draftCategoryIds.removeAll()
                        }
                    }
                    .disabled(!hasDraftFilters)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        onApply(draftPeriod, draftCategoryIds)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func checkRow<Content: View>(
        isOn: Bool,
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                content()
                    .foregroundStyle(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(NightTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(NightTheme.sectionFont)
            .foregroundStyle(NightTheme.secondaryLabel)
            .textCase(nil)
    }

    private func toggle(_ id: UUID) {
        if draftCategoryIds.contains(id) {
            draftCategoryIds.remove(id)
        } else {
            draftCategoryIds.insert(id)
        }
    }
}

// MARK: - Empty street

/// One unlit building, a street lamp and a walker: the Expenses empty state.
struct EmptyStreetView: View {
    /// The Expenses tab has the walker; Recurring has the cyclist.
    var figure: StreetFigure = .walker
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let dark = colorScheme == .dark
        let building = dark ? Color(red: 22 / 255, green: 28 / 255, blue: 44 / 255) : Color(.systemGray5)
        let window = dark ? Color(red: 35 / 255, green: 43 / 255, blue: 64 / 255) : Color(.systemGray4)
        let figureColor = NightTheme.figure(colorScheme)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.fill(Path(roundedRect: CGRect(x: 70, y: 14, width: 56, height: 96), cornerRadius: 3),
                         with: .color(building))
                for row in 0..<4 {
                    for col in 0..<3 {
                        let rect = CGRect(x: 80 + Double(col) * 14, y: 26 + Double(row) * 20, width: 9, height: 12)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(window))
                    }
                }
                var ground = Path()
                ground.move(to: CGPoint(x: 6, y: 110.5))
                ground.addLine(to: CGPoint(x: 184, y: 110.5))
                ctx.stroke(ground, with: .color(NightTheme.hair), lineWidth: 1)

                var post = Path()
                post.move(to: CGPoint(x: 150, y: 110))
                post.addLine(to: CGPoint(x: 150, y: 52))
                post.addQuadCurve(to: CGPoint(x: 156, y: 46), control: CGPoint(x: 150, y: 46))
                post.addLine(to: CGPoint(x: 162, y: 46))
                ctx.stroke(post, with: .color(figureColor), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: 153, y: 38, width: 20, height: 20)),
                         with: .color(NightTheme.window.opacity(0.16)))
                ctx.fill(Path(roundedRect: CGRect(x: 160, y: 45, width: 7, height: 4), cornerRadius: 1),
                         with: .color(NightTheme.window))
            }
            if !typeSize.isAccessibilitySize {
                StreetFigureView(figure: figure, height: 22)
                    .offset(x: figure == .cyclist ? 22 : 34, y: 88)
            }
        }
        .frame(width: 190, height: 120)
        .accessibilityHidden(true)
    }
}

#Preview {
    ExpenseListView()
}
