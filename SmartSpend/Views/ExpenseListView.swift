import SwiftUI

struct ExpenseListView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @State private var searchText = ""
    @State private var selectedCategoryIds: Set<String> = []
    @State private var selectedTimePeriod: TimePeriod = .all
    @State private var selectedCustomMonth: Date = Date()
    @State private var selectedStartDate: Date = Date()
    @State private var selectedEndDate: Date = Date()
    @State private var showingMonthPicker = false
    @State private var showingAddExpense = false
    @StateObject private var voice = InlineVoiceExpenseController()
    @State private var showingFilterSheet = false
    @State private var isDateRangeMode = true
    @State private var isSelectionMode = false
    @State private var selectedExpenses: Set<UUID> = []
    @State private var visibleExpenseLimit = 36

    private let expensePageSize = 60
    private let initialExpensePageSize = 36

    enum TimePeriod: String, CaseIterable {
        case all = "All"
        case today = "Today"
        case yesterday = "Yesterday"
        case weekly = "This Week"
        case monthly = "This Month"
        case customMonth = "Custom Month"

        var icon: String {
            switch self {
            case .all: return "calendar"
            case .today: return "calendar.badge.exclamationmark"
            case .yesterday: return "calendar.badge.minus"
            case .weekly: return "calendar.badge.clock"
            case .monthly: return "calendar.badge.plus"
            case .customMonth: return "calendar.badge.clock"
            }
        }

        var localizedName: String {
            switch self {
            case .all:
                return "time_period_all".localized
            case .today:
                return "time_period_today".localized
            case .yesterday:
                return "yesterday".localized
            case .weekly:
                return "time_period_this_week".localized
            case .monthly:
                return "time_period_this_month".localized
            case .customMonth:
                return "time_period_custom".localized
            }
        }
    }
    
    // Unified category model for filter
    struct FilterCategory: Hashable {
        let id: String
        let name: String
        let icon: String
        let color: Color
    }
    
    var availableFilterCategories: [FilterCategory] {
        var filters: [FilterCategory] = []
        
        // Add User Categories that are used or exist
        for category in dataManager.userCategories {
            filters.append(FilterCategory(
                id: category.id.uuidString,
                name: category.name,
                icon: category.iconSystemName,
                color: category.color
            ))
        }
        
        return filters.sorted { $0.name < $1.name }
    }
    
    var filteredExpenses: [Expense] {
        var expenses = dataManager.expenses.sorted { $0.date > $1.date }
        let referenceDate = Date()
        
        // Apply time period filter
        expenses = expenses.filter { expense in
            switch selectedTimePeriod {
            case .all:
                return true
            case .today:
                return Calendar.current.isDateInToday(expense.date)
            case .yesterday:
                return Calendar.current.isDateInYesterday(expense.date)
            case .weekly:
                return ExpenseDateFilter.contains(expense.date, in: .weekOfYear, relativeTo: referenceDate)
            case .monthly:
                return ExpenseDateFilter.contains(expense.date, in: .month, relativeTo: referenceDate)
            case .customMonth:
                let calendar = Calendar.current
                if isDateRangeMode {
                    return expense.date >= selectedStartDate && expense.date <= selectedEndDate
                } else {
                    return calendar.isDate(expense.date, inSameDayAs: selectedStartDate)
                }
            }
        }

        if !searchText.isEmpty {
            expenses = expenses.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }

        // Multi-category filter — empty set means "all categories"
        if !selectedCategoryIds.isEmpty {
            expenses = expenses.filter { selectedCategoryIds.contains($0.categoryId.uuidString) }
        }

        return expenses
    }

    private func groupedExpenses(from expenses: [Expense]) -> [(date: Date, expenses: [Expense], total: Double)] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: Array(expenses.prefix(visibleExpenseLimit))) { expense in
            calendar.startOfDay(for: expense.date)
        }
        return dict.map { date, dayExpenses in
            let sorted = dayExpenses.sorted { $0.date > $1.date }
            return (date: date, expenses: sorted, total: sorted.reduce(0) { $0 + $1.amount })
        }
        .sorted { $0.date > $1.date }
    }

    private func canLoadMoreExpenses(from expenses: [Expense]) -> Bool {
        expenses.count > visibleExpenseLimit
    }

    private func sectionDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.dateFormat = isCurrentYear ? "EEEE, MMM d" : "EEEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    private var isFilterActive: Bool {
        selectedTimePeriod != .all || !selectedCategoryIds.isEmpty
    }

    private func customRangeText() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: selectedStartDate)) – \(f.string(from: selectedEndDate))"
    }

    // Size the filter sheet to its content: short for a few categories, taller
    // as more are added, but capped at ~90% so it never jumps to full unless the
    // list genuinely needs it (then it scrolls and can be dragged up to .large).
    private var filterSheetDetents: Set<PresentationDetent> {
        let rows = max(availableFilterCategories.count, 1)
        // nav bar + time section + category header/footer + rows
        let estimated: CGFloat = 56 + 100 + 80 + CGFloat(rows) * 44 + 40
        let cap = UIScreen.main.bounds.height * 0.9
        return [.height(min(estimated, cap)), .large]
    }

    // The segmented control already exposes the quick time periods, so the
    // active-filter bar only needs to surface categories and custom ranges.
    private var showActiveFilterBar: Bool {
        selectedTimePeriod == .customMonth || !selectedCategoryIds.isEmpty
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if selectedTimePeriod == .customMonth {
            parts.append(customRangeText())
        }
        let names = availableFilterCategories
            .filter { selectedCategoryIds.contains($0.id) }
            .map { $0.name }
        if names.count == 1 {
            parts.append(names[0])
        } else if names.count == 2 {
            parts.append("\(names[0]), \(names[1])")
        } else if names.count > 2 {
            parts.append("\(names[0]), \(names[1]) +\(names.count - 2)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let currentFilteredExpenses = filteredExpenses
        let currentGroupedExpenses = groupedExpenses(from: currentFilteredExpenses)

        NavigationStack {
            VStack(spacing: 0) {
                AppScreenHeader("expenses".localized) {
                    if isSelectionMode {
                        Button("cancel".localized) {
                            isSelectionMode = false
                            selectedExpenses.removeAll()
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(.systemBlue))
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)

                        ActionIconButton(icon: "trash", style: .destructive(enabled: !selectedExpenses.isEmpty)) {
                            deleteSelectedExpenses()
                        }
                    } else {
                        filterButton
                        if !dataManager.expenses.isEmpty {
                            ActionIconButton(icon: "check-circle", style: .secondary) {
                                isSelectionMode = true
                            }
                        }
                        ExpenseEntryButton(accessibilityID: "expenses.add-expense", isRecording: voice.isRecording, isProcessing: voice.isProcessing, onTap: {
                            showingAddExpense = true
                        }, onVoice: {
                            voice.start()
                        }, onStop: { voice.stop() })
                    }
                }
                .opacity(voice.isVisible && voice.prefill == nil ? 0 : 1)
                .allowsHitTesting(!voice.isVisible || voice.prefill != nil)
                .accessibilityHidden(voice.isVisible && voice.prefill == nil)

                AppSearchField(text: $searchText, prompt: "search_expenses".localized)
                    .padding(.bottom, iOSDesignSystem.Spacing.small)

                // Pinned quick time-period segmented control
                Picker("time_period".localized, selection: $selectedTimePeriod) {
                    Text("all".localized).tag(TimePeriod.all)
                    Text("time_period_today".localized).tag(TimePeriod.today)
                    Text("yesterday".localized).tag(TimePeriod.yesterday)
                    Text("timeframe_week".localized).tag(TimePeriod.weekly)
                    Text("timeframe_month".localized).tag(TimePeriod.monthly)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.top, iOSDesignSystem.Spacing.small)
                .padding(.bottom, iOSDesignSystem.Spacing.small)

                // Small active-filter bar — only for "hidden" filters
                // (selected categories or a custom date range). Tapping the
                // summary reopens the filter sheet.
                if showActiveFilterBar {
                    Button {
                        showingFilterSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            HeroIcon(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(.tint)
                            Text(activeFilterSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                    .padding(.bottom, iOSDesignSystem.Spacing.small)
                }

                // List / empty state
                if currentFilteredExpenses.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(currentGroupedExpenses, id: \.date) { group in
                            Section {
                                ForEach(group.expenses) { expense in
                                    let category = dataManager.resolveCategory(id: expense.categoryId)
                                    ExpenseRowView(
                                        expense: expense,
                                        categoryDisplayInfo: (category.name, category.iconSystemName, category.color),
                                        currency: dataManager.user.currency,
                                        isSelectionMode: isSelectionMode,
                                        isSelected: selectedExpenses.contains(expense.id),
                                        onToggleSelection: {
                                            toggleExpenseSelection(expense.id)
                                        },
                                        onDelete: {
                                            dataManager.moveToDeletedExpenses(expense)
                                        }
                                    )
                                }
                            } header: {
                                HStack {
                                    Text(sectionDateLabel(group.date))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                    Spacer()
                                    Text(CurrencyFormatter.format(group.total, currency: dataManager.user.currency))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .textCase(nil)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        if canLoadMoreExpenses(from: currentFilteredExpenses) {
                            loadMoreRow
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("")
            .voiceExpenseOverlay(controller: voice)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .sheet(item: $voice.prefill, onDismiss: { voice.reviewDidDismiss() }) { item in
                AddExpenseView(prefill: item) { voice.didSave() }
            }
            .sheet(isPresented: $showingFilterSheet) {
                ExpenseFilterSheet(
                    categories: availableFilterCategories,
                    selectedCategoryIds: selectedCategoryIds,
                    selectedTimePeriod: $selectedTimePeriod,
                    onApply: { categoryIds in
                        selectedCategoryIds = categoryIds
                    },
                    onPickCustomRange: {
                        showingFilterSheet = false
                        showingMonthPicker = true
                    },
                    onClear: { clearFilters() }
                )
                .presentationDetents(filterSheetDetents)
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingMonthPicker) {
                CalendarPickerView(
                    selectedStartDate: $selectedStartDate,
                    selectedEndDate: $selectedEndDate,
                    isDateRangeMode: $isDateRangeMode,
                    selectedTimePeriod: $selectedTimePeriod
                )
                .presentationDetents([.fraction(0.85)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                selectionInfoBar
            }
            .onChange(of: searchText) { _, _ in resetVisibleExpenses() }
            .onDisappear { voice.cancel() }
            .onChange(of: selectedTimePeriod) { _, _ in resetVisibleExpenses() }
            .onChange(of: selectedCategoryIds) { _, _ in resetVisibleExpenses() }
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if isFilterActive {
            ContentUnavailableView {
                HeroIconLabel(title: "no_expenses_found".localized, systemName: "line.3.horizontal.decrease.circle")
            } description: {
                Text("try_adjusting_filters".localized)
            } actions: {
                Button("clear".localized) { clearFilters() }
            }
        } else {
            ContentUnavailableView {
                HeroIconLabel(title: "no_expenses_found".localized, systemName: "tray")
            } description: {
                Text("try_adjusting_filters".localized)
            } actions: {
                Button("add_expense".localized) { showingAddExpense = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func clearFilters() {
        withAnimation {
            selectedTimePeriod = .all
            selectedCategoryIds.removeAll()
        }
        resetVisibleExpenses()
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading more")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .onAppear {
            visibleExpenseLimit += expensePageSize
        }
    }

    private func resetVisibleExpenses() {
        visibleExpenseLimit = initialExpensePageSize
    }

    // MARK: - Toolbar Content

    private var filterButton: some View {
        ActionIconButton(icon: "funnel", style: .secondary) {
            showingFilterSheet = true
        }
    }

    @ViewBuilder
    private var selectionInfoBar: some View {
        if isSelectionMode && !selectedExpenses.isEmpty {
            HStack {
                Text("\(selectedExpenses.count) selected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, iOSDesignSystem.Spacing.large)
            .padding(.vertical, iOSDesignSystem.Spacing.medium)
            .liquidGlassSurface(RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: -2)
            .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
            .padding(.bottom, iOSDesignSystem.Spacing.screenMargin)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }


    private func toggleExpenseSelection(_ id: UUID) {
        if selectedExpenses.contains(id) {
            selectedExpenses.remove(id)
        } else {
            selectedExpenses.insert(id)
        }
    }
    
    private func deleteSelectedExpenses() {
        withAnimation {
            for expenseId in selectedExpenses {
                if let expense = dataManager.expenses.first(where: { $0.id == expenseId }) {
                    dataManager.moveToDeletedExpenses(expense)
                }
            }
            selectedExpenses.removeAll()
            isSelectionMode = false
        }
    }
}

struct CalendarPickerView: View {
    @Binding var selectedStartDate: Date
    @Binding var selectedEndDate: Date
    @Binding var isDateRangeMode: Bool
    @Binding var selectedTimePeriod: ExpenseListView.TimePeriod
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
            isDateRangeMode = true
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.medium) {
            HStack(spacing: iOSDesignSystem.Spacing.small) {
                HeroIcon("calendar-days", size: 18)
                    .foregroundStyle(Color(.systemBlue))

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
                        .fill(isActive ? Color(.systemBlue) : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? Color(.systemBlue) : .secondary)
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
            .background(isActive ? Color(.systemBlue).opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
            .liquidGlassCard(cornerRadius: iOSDesignSystem.Radius.large)
            .overlay(
                RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                    .stroke(isActive ? Color(.systemBlue).opacity(0.55) : Color.clear, lineWidth: 1.25)
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
                    .foregroundStyle(Color(.systemBlue))
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
                    .foregroundStyle(Color(.systemBlue))
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
                    .foregroundStyle(Color(.systemBlue))
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
        selectedTimePeriod = .customMonth
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
        } else if date > tempStartDate && date < tempEndDate {
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
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }
    
    private func localizedDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let symbols = formatter.shortWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        let calendar = Calendar.current
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
                        .stroke(Color(.systemBlue).opacity(0.45), lineWidth: 1)
                        .frame(width: 34, height: 34)
                }
                
                if showsSelection {
                    Circle()
                        .fill(Color(.systemBlue))
                        .frame(width: 36, height: 36)
                        .shadow(color: Color(.systemBlue).opacity(0.22), radius: 5, x: 0, y: 2)
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
                    .fill(Color(.systemBlue).opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Filter Sheet

struct ExpenseFilterSheet: View {
    let categories: [ExpenseListView.FilterCategory]
    @State private var draftCategoryIds: Set<String>
    @Binding var selectedTimePeriod: ExpenseListView.TimePeriod
    var onApply: (Set<String>) -> Void
    var onPickCustomRange: () -> Void
    var onClear: () -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        categories: [ExpenseListView.FilterCategory],
        selectedCategoryIds: Set<String>,
        selectedTimePeriod: Binding<ExpenseListView.TimePeriod>,
        onApply: @escaping (Set<String>) -> Void,
        onPickCustomRange: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.categories = categories
        self._draftCategoryIds = State(initialValue: selectedCategoryIds)
        self._selectedTimePeriod = selectedTimePeriod
        self.onApply = onApply
        self.onPickCustomRange = onPickCustomRange
        self.onClear = onClear
    }

    private var hasActiveFilter: Bool {
        selectedTimePeriod != .all || !draftCategoryIds.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                iOSDesignSystem.appBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.large) {
                        dateFilterCard
                        categoryFilterSection
                    }
                    .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                    .padding(.top, iOSDesignSystem.Spacing.screenMargin)
                    .padding(.bottom, 96)
                }
            }
            .navigationTitle("filter".localized)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                filterActionBar
            }
        }
    }

    private var dateFilterCard: some View {
        VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.medium) {
            sectionLabel("time_period".localized, value: selectedTimePeriod == .customMonth ? "custom".localized : "all".localized)

            Button {
                onApply(draftCategoryIds)
                onPickCustomRange()
            } label: {
                HStack(spacing: 14) {
                    HeroIcon(selectedTimePeriod == .customMonth ? "calendar-days" : "calendar", size: 21)
                        .foregroundStyle(Color(.systemBlue))
                        .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                        .liquidGlassSurface(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("custom_date_range".localized)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(selectedTimePeriod == .customMonth ? "Custom date range is active" : "Use this only when quick dates are not enough")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    HeroIcon("chevron-right", size: 16)
                        .foregroundStyle(.tertiary)
                }
                .padding(iOSDesignSystem.Spacing.medium)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
            }
            .liquidGlassButtonStyle()
            .liquidGlassCard(cornerRadius: iOSDesignSystem.Radius.large)
            .overlay(
                RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                    .stroke(selectedTimePeriod == .customMonth ? Color(.systemBlue).opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
    }

    private var categoryFilterSection: some View {
        VStack(alignment: .leading, spacing: iOSDesignSystem.Spacing.medium) {
            sectionLabel("category".localized, value: draftCategoryIds.isEmpty ? "all".localized : "\(draftCategoryIds.count)")

            if categories.isEmpty {
                VStack(spacing: iOSDesignSystem.Spacing.small) {
                    HeroIcon("tag", size: 24)
                        .foregroundStyle(.secondary)
                    Text("No categories yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .liquidGlassCard()
            } else {
                LazyVStack(spacing: iOSDesignSystem.Spacing.small) {
                    ForEach(categories, id: \.id) { category in
                        categoryFilterRow(category)
                    }
                }
            }

            Text("filter_category_hint".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private func categoryFilterRow(_ category: ExpenseListView.FilterCategory) -> some View {
        let selected = draftCategoryIds.contains(category.id)

        return Button {
            toggle(category.id)
        } label: {
            HStack(spacing: iOSDesignSystem.Spacing.medium) {
                HeroIcon(systemName: category.icon, size: 21)
                    .foregroundStyle(category.color)
                    .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                    .background(category.color.opacity(selected ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.medium, style: .continuous))

                Text(category.name)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if selected {
                    HeroIcon("check-circle", size: 22)
                        .foregroundStyle(Color(.systemBlue))
                } else {
                    Circle()
                        .stroke(Color(.tertiaryLabel), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.horizontal, iOSDesignSystem.Spacing.medium)
            .frame(minHeight: 58)
            .contentShape(RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous))
        }
        .liquidGlassButtonStyle()
        .liquidGlassCard(cornerRadius: iOSDesignSystem.Radius.large)
        .overlay(
            RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.large, style: .continuous)
                .stroke(selected ? Color(.systemBlue).opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func sectionLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    private var filterActionBar: some View {
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            Button {
                withAnimation(.snappy) {
                    draftCategoryIds.removeAll()
                }
                onClear()
            } label: {
                Text("clear".localized)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: iOSDesignSystem.Size.minimumTapTarget)
            }
            .disabled(!hasActiveFilter)
            .foregroundStyle(hasActiveFilter ? Color(.systemBlue) : Color.secondary)
            .liquidGlassButtonStyle()
            .liquidGlassSurface(Capsule())

            Button {
                onApply(draftCategoryIds)
                dismiss()
            } label: {
                Text("done".localized)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: iOSDesignSystem.Size.minimumTapTarget)
                    .background(Color(.systemBlue), in: Capsule())
            }
            .liquidGlassButtonStyle()
        }
        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
        .padding(.vertical, iOSDesignSystem.Spacing.medium)
        .background(.bar)
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            if draftCategoryIds.contains(id) {
                draftCategoryIds.remove(id)
            } else {
                draftCategoryIds.insert(id)
            }
        }
    }
}

#Preview {
    ExpenseListView()
}
