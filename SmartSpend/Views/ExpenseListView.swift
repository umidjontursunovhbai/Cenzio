import SwiftUI

struct ExpenseListView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    @StateObject private var voice = InlineVoiceExpenseController()

    // Filtering. Results are cached and recomputed only when an input changes,
    // not on every view update (voice state, selection taps, etc.).
    @State private var query = ExpenseListQuery()
    @State private var results: [Expense] = []
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
                    AppSearchField(text: $query.searchText, prompt: "search_expenses".localized)
                        .padding(.bottom, iOSDesignSystem.Spacing.small)
                    filterChips
                }

                content
            }
            .background(iOSDesignSystem.appBackground)
            .expenseEntryBar(ExpenseEntryBar(accessibilityPrefix: "expenses", isRecording: voice.isRecording, isProcessing: voice.isProcessing, onAdd: {
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
            .sheet(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .sheet(item: $voice.prefill, onDismiss: { voice.reviewDidDismiss() }) { item in
                AddExpenseView(prefill: item) { voice.didSave() }
            }
            .sheet(item: $editingExpense) { expense in
                EditExpenseView(expense: expense) { archive([expense]) }
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
            }
            .sheet(isPresented: $showingDeleted) {
                DeletedExpensesView()
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
        AppScreenHeader("expenses".localized, subtitle: headerSubtitle) {
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
            } else {
                if !dataManager.expenses.isEmpty {
                    filterButton
                }
                moreMenu
            }
        }
    }

    private var headerSubtitle: String? {
        if isSelecting {
            return String(format: "selected_count".localized, selection.count)
        }
        // "All Time" adds nothing above an unfiltered list.
        return dataManager.expenses.isEmpty || query.period == .all ? nil : periodTitle
    }

    private var filterButton: some View {
        ActionIconButton(icon: "funnel", style: .secondary) {
            showingFilterSheet = true
        }
        .overlay(alignment: .topTrailing) {
            if query.hasFilters {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(iOSDesignSystem.appBackground, lineWidth: 2))
                    .offset(x: 1, y: -1)
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
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                .liquidGlassSurface(Circle())
                .contentShape(Circle())
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
            .padding(.horizontal, 24)
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
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isOn ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
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
            ContentUnavailableView {
                HeroIconLabel(title: "exp_empty_title".localized, systemName: "tray")
            } description: {
                Text("exp_empty_body".localized)
            } actions: {
                Button("add_expense".localized) { showingAddExpense = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else if results.isEmpty {
            noResults
                .frame(maxHeight: .infinity)
        } else {
            expenseList
        }
    }

    @ViewBuilder
    private var noResults: some View {
        if query.isSearching && !query.hasFilters {
            ContentUnavailableView.search(text: query.trimmedSearch)
        } else {
            ContentUnavailableView {
                HeroIconLabel(title: "no_expenses_found".localized, systemName: "line.3.horizontal.decrease.circle")
            } description: {
                Text(query.isSearching
                     ? String(format: "exp_no_matches_in_period_format".localized, query.trimmedSearch, periodTitle)
                     : String(format: "exp_nothing_in_period_format".localized, periodTitle))
            } actions: {
                Button("exp_clear_filters".localized, action: clearFilters)
                    .buttonStyle(.bordered)
            }
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
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // Keeps the last rows scrollable above the entry bar and floating tab bar.
        .contentMargins(.bottom, 88 + tabBarClearance, for: .scrollContent)
        .animation(.snappy(duration: 0.25), value: isSelecting)
    }

    private func dayHeader(_ group: ExpenseDayGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ExpenseDayGroup.title(for: group.day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(CurrencyFormatter.format(group.total, currency: currency))
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.top, 4)
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
        .listRowBackground(isSelecting && isSelected ? Color.accentColor.opacity(0.12) : Self.rowBackground)
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
                .tint(.accentColor)
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

    private static let rowBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.135, blue: 0.15, alpha: 1)
            : UIColor.secondarySystemBackground
    })

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
                // Sits above the entry bar's 56pt buttons.
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.bottom, 12 + 56 + 12 + tabBarClearance)
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
                .foregroundStyle(.secondary)
            Text(String(format: "exp_moved_to_deleted_format".localized, batch.expenseIds.count))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("exp_undo".localized) { undo(batch) }
                .font(.subheadline.weight(.semibold))
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
                iOSDesignSystem.appBackground
                    .ignoresSafeArea()

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
                    .foregroundStyle(Color.accentColor)

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
                        .fill(isActive ? Color.accentColor : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
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
            .background(isActive ? Color.accentColor.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
            .liquidGlassCard(cornerRadius: iOSDesignSystem.Radius.large)
            .overlay(
                RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                    .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.25)
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
                    .foregroundStyle(Color.accentColor)
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
                .fill(Color(.tertiarySystemFill))
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

            Divider()
                .overlay(Color(.separator).opacity(0.35))

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
        .liquidGlassCard(cornerRadius: iOSDesignSystem.Radius.sheet)
    }

    private var monthNavigation: some View {
        HStack {
            Button(action: previousMonth) {
                HeroIcon(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .iOSMinimumTapTarget()
                    .liquidGlassSurface(Circle())
            }
            
            Spacer()
            
            Text(monthYearString(from: currentMonth))
                .font(.headline.weight(.semibold))
                .contentTransition(.opacity)
            
            Spacer()
            
            Button(action: nextMonth) {
                HeroIcon(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .iOSMinimumTapTarget()
                    .liquidGlassSurface(Circle())
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
    
    var body: some View {
        Button(action: action) {
            ZStack {
                rangeBackground

                if Calendar.current.isDateInToday(date) && !showsSelection {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                        .frame(width: 34, height: 34)
                }
                
                if showsSelection {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .shadow(color: Color.accentColor.opacity(0.22), radius: 5, x: 0, y: 2)
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
            return .white
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
                    .fill(Color.accentColor.opacity(0.12))
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
                Section("time_period".localized) {
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
                                    .foregroundStyle(Color.accentColor)
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            if draftPeriod == .custom {
                                Text(customRangeText)
                                    .foregroundStyle(Color.accentColor)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityAddTraits(draftPeriod == .custom ? .isSelected : [])
                }

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
                                        .foregroundStyle(category.color)
                                }
                            } action: {
                                toggle(category.id)
                            }
                        }
                    }
                } header: {
                    Text("category".localized)
                } footer: {
                    Text("filter_category_hint".localized)
                }
            }
            .listStyle(.insetGrouped)
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
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(_ id: UUID) {
        if draftCategoryIds.contains(id) {
            draftCategoryIds.remove(id)
        } else {
            draftCategoryIds.insert(id)
        }
    }
}

#Preview {
    ExpenseListView()
}
