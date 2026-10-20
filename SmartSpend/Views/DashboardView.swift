import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var tabManager = TabManager.shared
    @State private var showingAddExpense = false
    @StateObject private var voice = InlineVoiceExpenseController()
    @State private var showingMonthlySalary = false
    @State private var selectedBudgetAlertCategory: UserCategory?
    @State private var showingBudgetSettings = false
    @State private var overview = DashboardOverview(
        expenses: DataManager.shared.expenses,
        now: Date()
    )

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    AppScreenHeader("dashboard".localized) {
                        ExpenseEntryButton(accessibilityID: "dashboard.add-expense", isRecording: voice.isRecording, isProcessing: voice.isProcessing, onTap: {
                            showingAddExpense = true
                        }, onVoice: {
                            voice.start()
                        }, onStop: { voice.stop() })
                    }
                    .padding(.horizontal, -iOSDesignSystem.Spacing.screenMargin)
                    // The voice HUD temporarily replaces the header visually,
                    // keeping its layout space without duplicate controls behind it.
                    .opacity(voice.isVisible && voice.prefill == nil ? 0 : 1)
                    .allowsHitTesting(!voice.isVisible || voice.prefill != nil)
                    .accessibilityHidden(voice.isVisible && voice.prefill == nil)

                    monthlyOverviewCard
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard.overview")
                    if !budgetAlerts.isEmpty {
                        budgetAlertsCard
                    }
                    if !upcomingBills.isEmpty {
                        upcomingBillsCard
                    }
                    if !overview.monthExpenses.isEmpty {
                        categoryCard
                    }
                    if !overview.recentExpenses.isEmpty {
                        recentExpensesCard
                    } else {
                        emptyExpensesCard
                    }
                    if !overview.previousMonthsWithExpenses.isEmpty {
                        previousMonthsCard
                    }
                }
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.vertical, iOSDesignSystem.Spacing.screenMargin)
            }
            .background(iOSDesignSystem.appBackground)
            .voiceExpenseOverlay(controller: voice)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .sheet(item: $voice.prefill, onDismiss: { voice.reviewDidDismiss() }) { item in
                AddExpenseView(prefill: item) { voice.didSave() }
            }
            .sheet(isPresented: $showingMonthlySalary) {
                MonthlySalaryView()
            }
            .sheet(item: $selectedBudgetAlertCategory) { category in
                BudgetSettingsView(focusCategoryID: category.id)
            }
            .sheet(isPresented: $showingBudgetSettings) {
                BudgetSettingsView()
            }
            .onAppear(perform: refreshOverview)
            #if DEBUG
            .onAppear {
                // Explicit UI-test replay: no microphone, no save, synthetic text only.
                if ProcessInfo.processInfo.environment["SMARTSPEND_GPT_UI_TEST"] == "1" {
                    voice.prepareRecognizedText("for bus i spend 2500 today")
                }
                if let state = ProcessInfo.processInfo.environment["SMARTSPEND_VOICE_OVERLAY_TEST"] {
                    voice.showOverlayForTesting(state: state)
                }
            }
            #endif
            .onDisappear { voice.cancel() }
            .onChange(of: dataManager.expenses) { _, _ in
                refreshOverview()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshOverview() }
            }
        }
    }

    private var currency: Currency { dataManager.user.currency }

    private func compactAmount(_ amount: Double) -> String {
        return CurrencyFormatter.format(amount, currency: currency)
    }

    // MARK: - Derived data

    private func refreshOverview() {
        overview = DashboardOverview(expenses: dataManager.expenses, now: Date(), calendar: calendar)
    }
    private var spendableSnapshot: SpendableTodaySnapshot {
        BudgetPeriodCalculator.spendableToday(
            monthlyIncome: monthlySalary,
            expenses: overview.monthExpenses,
            recurringExpenses: dataManager.recurringExpenses
        )
    }
    private var monthlySalary: Double {
        let now = Date()
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)
        guard let salary = dataManager.monthlySalaries.first(where: {
            $0.month == month && $0.year == year && $0.currency == currency
        }) else { return 0 }
        return salary.amount
    }

    private var upcomingBills: [RecurringExpense] {
        let now = calendar.startOfDay(for: Date())
        let limit = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        return dataManager.recurringExpenses
            .filter { $0.isActive && $0.nextDueDate >= now && $0.nextDueDate <= limit }
            .sorted { $0.nextDueDate < $1.nextDueDate }
    }

    private var budgetAlerts: [(category: UserCategory, spent: Double, limit: Double)] {
        let spentByCategory = overview.categoryTotals
        return dataManager.categoryBudgets
            .filter { $0.isEnabled && $0.amount > 0 }
            .compactMap { budget -> (category: UserCategory, spent: Double, limit: Double)? in
                let spent = spentByCategory[budget.categoryId, default: 0]
                guard spent >= budget.amount * 0.8 else { return nil }
                return (dataManager.resolveCategory(id: budget.categoryId), spent, budget.amount)
            }
            .sorted { ($0.spent / $0.limit) > ($1.spent / $1.limit) }
    }

    // MARK: - Cards

    private var monthlyOverviewCard: some View {
        let spent = overview.monthTotal
        let incomeLeft = monthlySalary - spent
        let incomeShare = monthlySalary > 0 ? spent / monthlySalary : 0

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("month_spending".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Date().formatted(.dateTime.month(.wide).year()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(compactAmount(spent))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .contentTransition(.numericText())
                .accessibilityLabel("\("month_spending".localized), \(CurrencyFormatter.formatFull(spent, currency: currency))")

            if monthlySalary > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("monthly_income_used".localized)
                        Spacer()
                        Text(incomeShare.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ProgressView(value: min(max(incomeShare, 0), 1))
                        .tint(incomeShare >= 1 ? .red : Color(.systemBlue))
                        .accessibilityLabel("monthly_income_used".localized)
                        .accessibilityValue(incomeShare.formatted(.percent.precision(.fractionLength(0))))
                }

                Rectangle()
                    .fill(Color(.separator).opacity(0.55))
                    .frame(height: 1)

                HStack(alignment: .top, spacing: 12) {
                    overviewMetric(
                        title: incomeLeft < 0 ? "over_income".localized : "income_left".localized,
                        value: compactAmount(abs(incomeLeft)),
                        color: incomeLeft < 0 ? .red : .primary
                    )
                    Rectangle().fill(Color(.separator)).frame(width: 1, height: 38)
                    overviewMetric(
                        title: "daily_guide".localized,
                        value: compactAmount(spendableSnapshot.spendableToday),
                        color: spendableSnapshot.availableAfterBills < 0 ? .red : .primary
                    )
                }

            } else {
                Button {
                    showingMonthlySalary = true
                } label: {
                    HStack(spacing: 8) {
                        HeroIcon("wallet", size: 17)
                        Text("set_income_for_budget".localized)
                        Spacer()
                        HeroIcon("chevron-right", size: 13)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.systemBlue))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .dashboardCard()
    }

    private func overviewMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryCard: some View {
        let leading = Array(overview.sortedCategories.prefix(3))
        let otherAmount = overview.sortedCategories.dropFirst(3).reduce(0) { $0 + $1.amount }

        return VStack(alignment: .leading, spacing: 12) {
            cardHeader("category_breakdown".localized)

            ForEach(leading, id: \.categoryID) { item in
                let category = dataManager.resolveCategory(id: item.categoryID)
                let share = overview.monthTotal > 0 ? item.amount / overview.monthTotal : 0

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(category.color)
                            .frame(width: 8, height: 8)
                        Text(category.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(compactAmount(item.amount))
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                    }
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color(.systemGray5))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(category.color)
                                    .frame(width: geometry.size.width * min(max(share, 0), 1))
                            }
                    }
                    .frame(height: 5)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(share.formatted(.percent.precision(.fractionLength(0))))
            }

            if otherAmount > 0 {
                HStack {
                    Text("other_categories".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(compactAmount(otherAmount))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .dashboardCard()
    }

    private var recentExpensesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("recent_expenses".localized, actionTitle: "view_all".localized) {
                tabManager.selectedTab = 1
            }

            ForEach(Array(overview.recentExpenses.prefix(3).enumerated()), id: \.element.id) { index, expense in
                let category = dataManager.resolveCategory(id: expense.categoryId)
                HStack(spacing: 12) {
                    HeroIcon(systemName: category.iconSystemName, size: 20)
                        .foregroundStyle(category.color)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(category.name) · \(expense.date.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(compactAmount(expense.amount))
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .padding(.vertical, 5)

                if index < min(overview.recentExpenses.count, 3) - 1 {
                    Divider()
                }
            }
        }
        .dashboardCard()
    }

    private var emptyExpensesCard: some View {
        Button {
            showingAddExpense = true
        } label: {
            HStack(spacing: 12) {
                HeroIcon("plus", size: 20)
                    .foregroundStyle(Color(.systemBlue))
                VStack(alignment: .leading, spacing: 3) {
                    Text("no_expenses_yet".localized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("add_first_expense".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HeroIcon("chevron-right", size: 13)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .dashboardCard()
    }

    private var previousMonthsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader("previous_months".localized)

            ForEach(Array(overview.previousMonthsWithExpenses.enumerated()), id: \.element.month) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.month.formatted(.dateTime.month(.wide).year()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Text(compactAmount(item.amount))
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .accessibilityElement(children: .combine)

                if index < overview.previousMonthsWithExpenses.count - 1 {
                    Divider()
                }
            }
        }
        .dashboardCard()
    }

    private var upcomingBillsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("upcoming_bills".localized, actionTitle: "view_all".localized) {
                tabManager.selectedTab = 2
            }
            VStack(spacing: 0) {
                ForEach(Array(upcomingBills.prefix(2).enumerated()), id: \.element.id) { index, bill in
                    let cat = dataManager.resolveCategory(id: bill.categoryId)
                    HStack(spacing: 12) {
                        HeroIcon(systemName: cat.iconSystemName, size: 21).foregroundStyle(cat.color).frame(width: iOSDesignSystem.Size.compactIcon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bill.title).lineLimit(1)
                            Text(dueText(bill.nextDueDate))
                                .font(.caption)
                                .foregroundStyle(dueColor(bill.nextDueDate))
                        }
                        Spacer()
                        Text(compactAmount(bill.amount)).fontWeight(.medium)
                    }
                    .padding(.vertical, 8)
                    if index < min(upcomingBills.count, 2) - 1 { Divider() }
                }
            }
        }
        .dashboardCard()
    }

    private var budgetAlertsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("budget_alerts".localized, actionTitle: "view_all".localized) {
                showingBudgetSettings = true
            }
            VStack(spacing: 0) {
                ForEach(Array(budgetAlerts.prefix(2).enumerated()), id: \.offset) { index, alert in
                    let over = alert.spent > alert.limit
                    Button {
                        selectedBudgetAlertCategory = alert.category
                    } label: {
                        HStack(spacing: 12) {
                            HeroIcon(systemName: alert.category.iconSystemName, size: 21)
                                .foregroundStyle(alert.category.color)
                                .frame(width: iOSDesignSystem.Size.compactIcon)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.category.name)
                                    .foregroundStyle(.primary)
                                Text("\(compactAmount(alert.spent)) / \(compactAmount(alert.limit))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            HStack(spacing: 5) {
                                Text(over ? "over_budget".localized : "near_limit".localized)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(over ? .red : .orange)
                                HeroIcon("chevron-right", size: 12)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this category's budget settings")

                    if index < min(budgetAlerts.count, 2) - 1 { Divider() }
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Helpers

    private func cardHeader(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .liquidGlassSurface(Capsule())
                    .liquidGlassButtonStyle()
            }
        }
    }

    private func dueText(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "due_today".localized }
        if calendar.isDateInTomorrow(date) { return "due_tomorrow".localized }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        return String(format: "due_in_days_format".localized, days)
    }

    private func dueColor(_ date: Date) -> Color {
        (calendar.isDateInToday(date) || calendar.isDateInTomorrow(date)) ? .orange : .secondary
    }
}

private extension View {
    func dashboardCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(iOSDesignSystem.Spacing.screenMargin)
            .liquidGlassCard()
    }

}

struct DashboardOverview {
    struct CategorySpend {
        let categoryID: UUID
        let amount: Double
    }

    struct MonthSpend {
        let month: Date
        let amount: Double
    }

    let monthExpenses: [Expense]
    let monthTotal: Double
    let categoryTotals: [UUID: Double]
    let sortedCategories: [CategorySpend]
    let recentExpenses: [Expense]
    let previousMonthsWithExpenses: [MonthSpend]

    init(expenses: [Expense], now: Date, calendar: Calendar = .current) {
        let month = BudgetPeriodCalculator.monthInterval(containing: now, calendar: calendar)
        let current = expenses.filter { month.contains($0.date) && $0.date <= now }
        let totals = current.reduce(into: [UUID: Double]()) { result, expense in
            result[expense.categoryId, default: 0] += expense.amount
        }

        monthExpenses = current
        monthTotal = current.reduce(0) { $0 + $1.amount }
        categoryTotals = totals
        sortedCategories = totals
            .map { CategorySpend(categoryID: $0.key, amount: $0.value) }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.categoryID.uuidString < $1.categoryID.uuidString
            }
        recentExpenses = expenses.filter { $0.date <= now }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }

        let historicalTotals = expenses.reduce(into: [Date: Double]()) { result, expense in
            guard expense.date <= now,
                  let monthStart = calendar.dateInterval(of: .month, for: expense.date)?.start else {
                return
            }
            result[monthStart, default: 0] += expense.amount
        }
        previousMonthsWithExpenses = Array(historicalTotals
            .filter { $0.key < month.start && $0.value > 0 }
            .map { MonthSpend(month: $0.key, amount: $0.value) }
            .sorted { $0.month > $1.month }
            .prefix(3))
    }
}

struct BudgetDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @State private var showingCustomMonthPicker = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Time Period Selector
                    timePeriodSelector
                    
                    // Budget Overview Card
                    budgetOverviewCard
                    
                    // Category Breakdown
                    categoryBreakdownCard
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("budget_details".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingCustomMonthPicker) {
                CustomMonthPickerView()
                    .presentationDetents([.fraction(0.85)])
            }
        }
    }
    
    private var timePeriodSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("time_period".localized)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            
            // Show custom date range if custom month is selected
            if dataManager.selectedTimePeriod == .customMonth {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("custom_date_range".localized)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        
                        Text("\(formatDate(dataManager.customStartDate)) - \(formatDate(dataManager.customEndDate))")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        showingCustomMonthPicker = true
                    }) {
                        HeroIcon(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
            }
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 12) {
                ForEach(TimePeriod.allCases, id: \.self) { period in
                    Button(action: {
                        if period == .customMonth {
                            showingCustomMonthPicker = true
                        } else {
                            dataManager.selectedTimePeriod = period
                        }
                    }) {
                        HStack(spacing: 8) {
                            HeroIcon(systemName: period.icon)
                                .font(.title3)
                                .foregroundStyle(dataManager.selectedTimePeriod == period ? .white : .primary)
                            
                            Text(period.localizedName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(dataManager.selectedTimePeriod == period ? .white : .primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            dataManager.selectedTimePeriod == period ? 
                            Color(.systemBlue) : 
                            Color(.systemGray6),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    dataManager.selectedTimePeriod == period ? Color.clear : Color(.systemGray4),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.2), value: dataManager.selectedTimePeriod)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    private var budgetOverviewCard: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                HeroIconLabel(title: "budget_overview".localized, systemName: "chart.pie.fill")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
            }
            
            // Progress Section
            VStack(spacing: 12) {
                HStack {
                    Text("budget_used".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(dataManager.getProgressPercentageForPeriod() * 100))%")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dataManager.getProgressPercentageForPeriod() > 0.8 ? .red : .primary)
                }
                
                ProgressView(value: dataManager.getProgressPercentageForPeriod())
                    .progressViewStyle(LinearProgressViewStyle(tint: dataManager.getProgressPercentageForPeriod() > 0.8 ? Color(.systemRed) : Color(.systemBlue)))
                    .scaleEffect(x: 1, y: 1.5, anchor: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            // Budget Stats
            HStack(spacing: 16) {
                BudgetStatView(
                    title: "spent".localized,
                    amount: dataManager.getTotalExpensesForPeriod(),
                    currency: dataManager.user.currency,
                    color: Color(.systemRed)
                )
                
                Divider()
                    .frame(height: 40)
                
                BudgetStatView(
                    title: "remaining".localized,
                    amount: dataManager.getRemainingBudgetForPeriod(),
                    currency: dataManager.user.currency,
                    color: Color(.systemGreen)
                )
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    private var categoryBreakdownCard: some View {
        VStack(spacing: 16) {
            HStack {
                HeroIconLabel(title: "category_breakdown".localized, systemName: "chart.bar.fill")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
            }
            
            LazyVStack(spacing: 12) {
                ForEach(dataManager.getCategoryBreakdownForPeriod().prefix(5), id: \.name) { item in
                    CategoryBreakdownRow(
                        name: item.name,
                        amount: item.amount,
                        total: dataManager.getTotalExpensesForPeriod(),
                        currency: dataManager.user.currency,
                        color: item.color,
                        icon: item.icon
                    )
                }
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter.string(from: date)
    }
    
}

struct SpendingTrendsView: View {
    @ObservedObject private var dataManager = DataManager.shared
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("spending_trends".localized)
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 16) {
                TrendStat(
                    title: "daily_avg".localized,
                    value: dataManager.getDailyAverageForPeriod(),
                    currency: dataManager.user.currency
                )
                Divider().frame(height: 40)
                TrendStat(
                    title: "weekly_avg".localized,
                    value: dataManager.getWeeklyAverageForPeriod(),
                    currency: dataManager.user.currency
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TrendStat: View {
    let title: String
    let value: Double
    let currency: Currency

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CurrencyFormatter.format(value, currency: currency))
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CategoryBreakdownRow: View {
    let name: String
    let amount: Double
    let total: Double
    let currency: Currency
    let color: Color
    let icon: String
    
    private var percentage: Double {
        guard total > 0 else { return 0 }
        return amount / total
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HeroIcon(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Text("\(Int(percentage * 100))% \("of_total".localized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Text(CurrencyFormatter.format(amount, currency: currency))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 8)
    }
}

struct SalaryHeaderView: View {
    let salary: Double
    let currency: Currency
    let onEditSalary: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeroIconLabel(title: "monthly_salary".localized, systemName: "dollarsign.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(action: onEditSalary) {
                    HeroIcon(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
            }
            
            Text(formatCurrency(salary, currency))
                .font(.largeTitle)
                .fontWeight(.bold)
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
    
    private func formatCurrency(_ amount: Double, _ currency: Currency) -> String {
        return CurrencyFormatter.format(amount, currency: currency)
    }
}

struct BudgetOverviewView: View {
    let totalExpenses: Double
    let remainingBudget: Double
    let salary: Double
    let currency: Currency
    
    var progressPercentage: Double {
        guard salary > 0 else { return 0 }
        return min(totalExpenses / salary, 1.0)
    }
    
    private var ringColor: Color {
        progressPercentage > 0.8 ? .red : .accentColor
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("budget_overview".localized)
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 24) {
                // Budget ring
                ZStack {
                    Circle()
                        .stroke(Color(.systemGray5), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: progressPercentage)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: progressPercentage)
                    VStack(spacing: 1) {
                        Text("\(Int(progressPercentage * 100))%")
                            .font(.title3.weight(.bold))
                            .fontDesign(.rounded)
                        Text("budget_used".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)

                // Spent / remaining
                VStack(spacing: 10) {
                    statRow(title: "spent".localized, amount: totalExpenses, color: Color(.systemRed))
                    Divider()
                    statRow(title: "remaining".localized, amount: remainingBudget, color: Color(.systemGreen))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statRow(title: String, amount: Double, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(CurrencyFormatter.format(amount, currency: currency))
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

struct BudgetStatView: View {
    let title: String
    let amount: Double
    let currency: Currency
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            Text(formatCurrency(amount, currency))
                .font(.title3)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
    
    private func formatCurrency(_ amount: Double, _ currency: Currency) -> String {
        return CurrencyFormatter.format(amount, currency: currency)
    }
}

struct CategoryBreakdownView: View {
    let breakdown: [(name: String, amount: Double, color: Color, icon: String)]
    @ObservedObject private var dataManager = DataManager.shared

    private var total: Double { breakdown.reduce(0) { $0 + $1.amount } }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("category_breakdown".localized)
                    .font(.headline)
                Spacer()
            }

            if breakdown.isEmpty {
                VStack(spacing: 8) {
                    HeroIcon(systemName: "chart.pie")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("no_expenses_yet".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                HStack(spacing: 20) {
                    Chart {
                        ForEach(breakdown.prefix(8), id: \.name) { item in
                            SectorMark(
                                angle: .value("Amount", item.amount),
                                innerRadius: .ratio(0.62),
                                angularInset: 1.5
                            )
                            .cornerRadius(4)
                            .foregroundStyle(item.color)
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(width: 120, height: 120)
                    .overlay {
                        VStack(spacing: 1) {
                            Text(CurrencyFormatter.formatCompact(total, currency: dataManager.user.currency))
                                .font(.subheadline.bold())
                                .fontDesign(.rounded)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text("spent".localized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                    }

                    VStack(spacing: 10) {
                        ForEach(breakdown.prefix(4), id: \.name) { item in
                            HStack(spacing: 8) {
                                Circle().fill(item.color).frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text(CurrencyFormatter.format(item.amount, currency: dataManager.user.currency))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CustomMonthPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @State private var currentMonth: Date = Date()
    @State private var selectionStep: SelectionStep = .firstDate
    @State private var tempStartDate: Date = Date()
    @State private var tempEndDate: Date = Date()
    
    enum SelectionStep {
        case firstDate
        case secondDate
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with Instructions
                VStack(spacing: 20) {
                    // Instructions
                    Text(instructionText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    // From and To Buttons
                    HStack(spacing: 16) {
                        Button(action: {
                            selectionStep = .firstDate
                        }) {
                            HStack(spacing: 8) {
                                HeroIcon(systemName: "calendar.badge.plus")
                                    .font(.system(size: 14, weight: .medium))
                                Text("from".localized)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(selectionStep == .firstDate ? .white : .blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectionStep == .firstDate ? Color.blue : Color.blue.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            selectionStep = .secondDate
                        }) {
                            HStack(spacing: 8) {
                                HeroIcon(systemName: "calendar.badge.clock")
                                    .font(.system(size: 14, weight: .medium))
                                Text("to".localized)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundColor(selectionStep == .secondDate ? .white : .blue)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectionStep == .secondDate ? Color.blue : Color.blue.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .background(Color(.systemGroupedBackground))
                
                // Calendar View
                VStack(spacing: 20) {
                    // Month Navigation
                    HStack {
                        Button(action: previousMonth) {
                            HeroIcon(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Color(.systemBlue))
                                .frame(width: 36, height: 36)
                                .background(Color(.systemGray6))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        Text(monthYearString(from: currentMonth))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(Color(.label))
                        
                        Spacer()
                        
                        Button(action: nextMonth) {
                            HeroIcon(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(Color(.systemBlue))
                                .frame(width: 36, height: 36)
                                .background(Color(.systemGray6))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    // Calendar Grid
                    VStack(spacing: 12) {
                        // Day headers
                        HStack(spacing: 0) {
                            ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { index, day in
                                Text(day)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color(.secondaryLabel))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        // Calendar days
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                            ForEach(Array(calendarDays.enumerated()), id: \.offset) { index, date in
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
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                
                Spacer()
            }
            .navigationTitle("select_custom_date_range".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        // Apply the selected date range when Done is pressed
                        dataManager.updateCustomDateRange(startDate: tempStartDate, endDate: tempEndDate)
                        dataManager.selectedTimePeriod = .customMonth
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                currentMonth = dataManager.customStartDate
                tempStartDate = dataManager.customStartDate
                tempEndDate = dataManager.customEndDate
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
        currentMonth = Calendar.current.date(byAdding: .month, value: -1, to: currentMonth) ?? currentMonth
    }
    
    private func nextMonth() {
        currentMonth = Calendar.current.date(byAdding: .month, value: 1, to: currentMonth) ?? currentMonth
    }
    
    private func selectDate(_ date: Date) {
        switch selectionStep {
        case .firstDate:
            tempStartDate = date
            if tempEndDate < tempStartDate {
                tempEndDate = date
            }
        case .secondDate:
            tempEndDate = max(date, tempStartDate)
        }
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
    
    private func monthYearString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    
    private var instructionText: String {
        switch selectionStep {
        case .firstDate:
            return "tap_from_select_start".localized
        case .secondDate:
            return "select_end_date".localized
        }
    }
}



#Preview {
    DashboardView()
}
