import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var tabManager = TabManager.shared
    @State private var showingAddExpense = false
    @StateObject private var voice = InlineVoiceExpenseController()
    @State private var showingMonthlySalary = false
    @State private var selectedBudgetCategory: UserCategory?
    @State private var showingBudgetSettings = false
    @State private var selectedPaceDay: Int?
    @State private var selectedCalendarDay: Int?
    @State private var spotlight: Spotlight = .places
    @State private var overview = DashboardOverview(
        expenses: DataManager.shared.expenses,
        now: Date()
    )

    private let calendar = Calendar.current

    private enum Spotlight: Hashable, CaseIterable {
        case places
        case largest

        var title: String {
            switch self {
            case .places: return "dash_top_places".localized
            case .largest: return "dash_largest".localized
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    AppScreenHeader(
                        "dashboard".localized,
                        subtitle: Date().formatted(.dateTime.month(.wide).year())
                    )
                    .padding(.horizontal, -iOSDesignSystem.Spacing.screenMargin)
                    // The voice HUD temporarily replaces the header visually,
                    // keeping its layout space without duplicate controls behind it.
                    .opacity(voice.isVisible && voice.prefill == nil ? 0 : 1)
                    .allowsHitTesting(!voice.isVisible || voice.prefill != nil)
                    .accessibilityHidden(voice.isVisible && voice.prefill == nil)

                    heroCard
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard.overview")

                    if !upcomingBills.isEmpty {
                        upcomingBillsCard
                    }

                    if hasMonthSpending {
                        spendingPaceCard
                        calendarHeatmapCard
                        categoryCard
                        spotlightCard
                    } else {
                        emptyMonthCard
                    }

                    if overview.weekdaySampleDays >= 14, overview.peakWeekday != nil {
                        weekdayPatternCard
                    }

                    if !overview.previousMonthsWithExpenses.isEmpty {
                        monthlyHistoryCard
                    }
                }
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.vertical, iOSDesignSystem.Spacing.screenMargin)
                // Keeps the last card scrollable above the entry bar.
                .padding(.bottom, 72)
            }
            .background(iOSDesignSystem.appBackground)
            .expenseEntryBar(ExpenseEntryBar(accessibilityPrefix: "dashboard", isRecording: voice.isRecording, isProcessing: voice.isProcessing, onAdd: {
                showingAddExpense = true
            }, onVoice: {
                voice.start()
            }, onStop: { voice.stop() }))
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
            .sheet(item: $selectedBudgetCategory) { category in
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
    private var hasMonthSpending: Bool { overview.monthTotal > 0 }

    private func money(_ amount: Double) -> String {
        CurrencyFormatter.format(amount, currency: currency)
    }

    private func compactMoney(_ amount: Double) -> String {
        CurrencyFormatter.formatCompact(amount, currency: currency)
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
            .filter { $0.isActive && !$0.isExpired && $0.nextDueDate >= now && $0.nextDueDate <= limit }
            .sorted { $0.nextDueDate < $1.nextDueDate }
    }

    private var activeBudgets: [UUID: Double] {
        dataManager.categoryBudgets
            .filter { $0.isEnabled && $0.amount > 0 }
            .reduce(into: [UUID: Double]()) { $0[$1.categoryId] = $1.amount }
    }

    /// Top spending categories, plus any category that is near or over its budget.
    private var categoryRows: [DashboardOverview.CategorySpend] {
        let budgets = activeBudgets
        var rows = Array(overview.sortedCategories.prefix(5))
        let shown = Set(rows.map(\.categoryID))
        rows += overview.sortedCategories.dropFirst(5).filter { item in
            guard !shown.contains(item.categoryID), let limit = budgets[item.categoryID] else { return false }
            return item.amount >= limit * 0.8
        }
        return rows
    }

    private var budgetAlertCount: Int {
        activeBudgets.filter { overview.categoryTotals[$0.key, default: 0] >= $0.value * 0.8 }.count
    }

    // MARK: - Hero

    private var heroCard: some View {
        let income = monthlySalary
        let snapshot = spendableSnapshot
        let isOver = income > 0 && snapshot.availableAfterBills < 0
        let forecastOverIncome = income > 0 && overview.projectedMonthTotal > income

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(heroTitle(income: income, isOver: isOver))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if hasMonthSpending && overview.previousMonthToDateTotal > 0 {
                    monthComparison
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(money(income > 0 ? abs(snapshot.availableAfterBills) : overview.monthTotal))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isOver ? Color(.systemRed) : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .contentTransition(.numericText())

                if income > 0 {
                    Text(String(format: "dash_of_income_days_format".localized, money(income), snapshot.daysRemaining))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            if income > 0 {
                budgetBar(income: income, snapshot: snapshot)
            }

            Rectangle()
                .fill(Color(.separator).opacity(0.5))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 10) {
                if income > 0 {
                    heroMetric(
                        title: "dash_safe_per_day".localized,
                        value: money(snapshot.spendableToday),
                        color: snapshot.availableAfterBills <= 0 ? Color(.systemRed) : .primary
                    )
                } else {
                    heroMetric(title: "dash_daily_average".localized, value: money(overview.dailyAverage))
                }
                metricDivider
                heroMetric(title: "dash_spent_today".localized, value: money(overview.todayTotal))
                metricDivider
                heroMetric(
                    title: "dash_forecast".localized,
                    value: hasMonthSpending ? money(overview.projectedMonthTotal) : "—",
                    color: forecastOverIncome ? Color(.systemRed) : .primary
                )
            }

            if income <= 0 {
                Button {
                    showingMonthlySalary = true
                } label: {
                    HStack(spacing: 10) {
                        HeroIcon("wallet", size: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("set_income_for_budget".localized)
                                .font(.subheadline.weight(.semibold))
                            Text("dash_set_income_hint".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HeroIcon("chevron-right", size: 13)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(12)
                    .frame(minHeight: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.medium, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .dashboardCard()
    }

    private func heroTitle(income: Double, isOver: Bool) -> String {
        if income <= 0 { return "month_spending".localized }
        return isOver ? "dash_over_plan".localized : "dash_left_to_spend".localized
    }

    private var metricDivider: some View {
        Rectangle().fill(Color(.separator).opacity(0.6)).frame(width: 1, height: 34)
    }

    private func heroMetric(title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Income split into what is spent, what is reserved for scheduled bills, and what is free.
    private func budgetBar(income: Double, snapshot: SpendableTodaySnapshot) -> some View {
        let spent = min(overview.monthTotal, income)
        let bills = min(max(snapshot.upcomingRecurring, 0), max(income - spent, 0))
        let free = max(income - spent - bills, 0)
        let overspent = overview.monthTotal > income

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 2) {
                    if spent > 0 {
                        Capsule()
                            .fill(overspent ? Color(.systemRed) : Color.accentColor)
                            .frame(width: max(width * spent / income, 6))
                    }
                    if bills > 0 {
                        Capsule()
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: max(width * bills / income, 6))
                    }
                    if free > 0 {
                        Capsule()
                            .fill(Color(.systemGray5))
                    }
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                legendDot("dash_legend_spent".localized, value: compactMoney(overview.monthTotal),
                          color: overspent ? Color(.systemRed) : Color.accentColor)
                if snapshot.upcomingRecurring > 0 {
                    legendDot("dash_legend_bills".localized, value: compactMoney(snapshot.upcomingRecurring), color: Color.orange.opacity(0.75))
                }
                legendDot("dash_legend_free".localized, value: compactMoney(max(snapshot.availableAfterBills, 0)), color: Color(.systemGray4))
                Spacer(minLength: 0)
            }
        }
    }

    private func legendDot(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.caption2)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// This month's change against the same number of days last month.
    private var monthComparison: some View {
        let previous = overview.previousMonthToDateTotal
        let change = (overview.monthTotal - previous) / previous
        let isUp = change > 0
        let tint = isUp ? Color(.systemRed) : Color(.systemGreen)

        return HStack(spacing: 4) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.bold))
            Text(abs(change).formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text("dashboard_vs_last_month".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Spending pace

    private var spendingPaceCard: some View {
        let income = monthlySalary
        let lastDay = max(overview.daysInMonth, overview.previousMonthCumulative.count)
        let paceGap = overview.paceDifference(monthlyIncome: income)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("dash_spending_pace".localized).font(.headline)
                Spacer()
                paceReadout(income: income, paceGap: paceGap)
            }

            Chart {
                if income > 0 {
                    ForEach([1, overview.daysInMonth], id: \.self) { day in
                        LineMark(
                            x: .value("Day", day),
                            y: .value("Amount", income * Double(day) / Double(max(overview.daysInMonth, 1))),
                            series: .value("Month", "even")
                        )
                        .foregroundStyle(Color(.systemGreen).opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [2, 4]))
                    }
                }
                ForEach(overview.previousMonthCumulative) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Amount", point.amount),
                        series: .value("Month", "previous")
                    )
                    .foregroundStyle(Color(.systemGray3))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .interpolationMethod(.monotone)
                }
                ForEach(overview.monthCumulative) { point in
                    AreaMark(x: .value("Day", point.day), y: .value("Amount", point.amount))
                        .foregroundStyle(LinearGradient(
                            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Amount", point.amount),
                        series: .value("Month", "current")
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                if let selectedPaceDay {
                    RuleMark(x: .value("Day", selectedPaceDay))
                        .foregroundStyle(Color(.systemGray3))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                } else if let today = overview.monthCumulative.last {
                    PointMark(x: .value("Day", today.day), y: .value("Amount", today.amount))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(40)
                }
            }
            .chartXScale(domain: 1...max(lastDay, 2))
            .chartXSelection(value: $selectedPaceDay)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(compactMoney(amount)).font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: [1, 10, 20, lastDay]) { _ in
                    AxisValueLabel().font(.caption2)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 150)
            .accessibilityLabel("dash_spending_pace".localized)
            .accessibilityValue(CurrencyFormatter.formatFull(overview.monthTotal, currency: currency))

            HStack(spacing: 14) {
                chartLegendItem("dashboard_this_month".localized, color: Color.accentColor, dashed: false)
                if !overview.previousMonthCumulative.isEmpty {
                    chartLegendItem("dashboard_last_month".localized, color: Color(.systemGray3), dashed: true)
                }
                if income > 0 {
                    chartLegendItem("dash_even_pace".localized, color: Color(.systemGreen).opacity(0.7), dashed: true)
                }
            }
        }
        .dashboardCard()
    }

    @ViewBuilder
    private func paceReadout(income: Double, paceGap: Double) -> some View {
        if let day = selectedPaceDay {
            let current = overview.monthCumulative.first { $0.day == day }?.amount
            let previous = overview.previousMonthCumulative.first { $0.day == day }?.amount
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "dash_day_format".localized, day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(current.map(money) ?? previous.map(money) ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
            }
        } else if income > 0 {
            let ahead = paceGap > 0
            Text(String(format: (ahead ? "dash_pace_above_format" : "dash_pace_below_format").localized, compactMoney(abs(paceGap))))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ahead ? Color(.systemRed) : Color(.systemGreen))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            Text(money(overview.monthTotal))
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func chartLegendItem(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 2)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Calendar heatmap

    private var calendarHeatmapCard: some View {
        let days = overview.calendarDays
        let maxAmount = days.map(\.amount).max() ?? 0
        let todayNumber = overview.daysElapsed
        let selected = days.first { $0.day == (selectedCalendarDay ?? todayNumber) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("dash_daily_spending".localized).font(.headline)
                Spacer()
                heatLegend
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(0..<overview.leadingBlankDays, id: \.self) { index in
                    Color.clear.frame(height: 1)
                }
                ForEach(days) { day in
                    heatCell(day, maxAmount: maxAmount, isToday: day.day == todayNumber,
                             isSelected: day.day == selected?.day)
                }
            }

            if let selected {
                HStack(spacing: 8) {
                    Text(selected.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if selected.amount > 0 {
                        Text(String(format: "dashboard_expense_count_format".localized, selected.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(money(selected.amount))
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                    } else {
                        Text((selected.isFuture ? "dash_upcoming_day" : "dash_no_spending_day").localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.medium, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .dashboardCard()
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func heatLevel(_ amount: Double, maxAmount: Double) -> Double {
        guard amount > 0, maxAmount > 0 else { return 0 }
        return 0.16 + 0.74 * (amount / maxAmount).squareRoot()
    }

    private func heatCell(_ day: DashboardOverview.CalendarDay, maxAmount: Double, isToday: Bool, isSelected: Bool) -> some View {
        let level = heatLevel(day.amount, maxAmount: maxAmount)
        let fill: Color = level > 0 ? Color.accentColor.opacity(level) : Color(.systemGray6)

        return Button {
            selectedCalendarDay = day.day
        } label: {
            Text("\(day.day)")
                .font(.caption.weight(isToday ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(day.isFuture ? Color(.tertiaryLabel) : (level > 0.55 ? Color.white : Color.primary))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(day.isFuture ? Color(.systemGray6).opacity(0.5) : fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.primary : (isToday ? Color.accentColor.opacity(0.6) : .clear),
                                lineWidth: isSelected ? 1.8 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.date.formatted(.dateTime.month(.wide).day()))
        .accessibilityValue(day.amount > 0 ? CurrencyFormatter.formatFull(day.amount, currency: currency) : "dash_no_spending_day".localized)
    }

    private var heatLegend: some View {
        HStack(spacing: 4) {
            Text("dash_less".localized)
            ForEach([0.0, 0.3, 0.6, 0.9], id: \.self) { level in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(level == 0 ? Color(.systemGray6) : Color.accentColor.opacity(level))
                    .frame(width: 10, height: 10)
            }
            Text("dash_more".localized)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: - Categories

    private var categoryCard: some View {
        let rows = categoryRows
        let budgets = activeBudgets
        let topAmount = overview.sortedCategories.first?.amount ?? 1
        let leading = Array(overview.sortedCategories.prefix(5))
        let otherAmount = overview.sortedCategories.dropFirst(5).reduce(0) { $0 + $1.amount }

        return VStack(alignment: .leading, spacing: 14) {
            cardHeader("dash_where_it_goes".localized, actionTitle: "dash_budgets".localized) {
                showingBudgetSettings = true
            }

            // Whole month at a glance: one stacked bar of category shares.
            Chart {
                ForEach(leading, id: \.categoryID) { item in
                    BarMark(x: .value("Amount", item.amount), y: .value("Month", "total"))
                        .foregroundStyle(dataManager.resolveCategory(id: item.categoryID).color)
                }
                if otherAmount > 0 {
                    BarMark(x: .value("Amount", otherAmount), y: .value("Month", "total"))
                        .foregroundStyle(Color(.systemGray4))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 12)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            if budgetAlertCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(String(format: "dash_budget_alert_count_format".localized, budgetAlertCount))
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.orange)
            }

            VStack(spacing: 14) {
                ForEach(rows, id: \.categoryID) { item in
                    categoryRow(item, limit: budgets[item.categoryID], topAmount: topAmount)
                }
            }

            if overview.sortedCategories.count > rows.count {
                HStack {
                    Text("other_categories".localized)
                    Spacer()
                    Text(money(overview.sortedCategories.dropFirst(rows.count).reduce(0) { $0 + $1.amount }))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }

    private func categoryRow(_ item: DashboardOverview.CategorySpend, limit: Double?, topAmount: Double) -> some View {
        let category = dataManager.resolveCategory(id: item.categoryID)
        let share = overview.monthTotal > 0 ? item.amount / overview.monthTotal : 0
        let progress: Double
        let barColor: Color
        let caption: String
        let captionColor: Color

        if let limit {
            progress = item.amount / limit
            barColor = progress > 1 ? Color(.systemRed) : (progress >= 0.8 ? .orange : category.color)
            caption = progress > 1
                ? String(format: "dash_budget_over_format".localized, compactMoney(item.amount - limit))
                : String(format: "dash_budget_left_format".localized, compactMoney(limit - item.amount))
            captionColor = progress > 1 ? Color(.systemRed) : (progress >= 0.8 ? .orange : .secondary)
        } else {
            progress = topAmount > 0 ? item.amount / topAmount : 0
            barColor = category.color
            caption = share.formatted(.percent.precision(.fractionLength(0)))
            captionColor = .secondary
        }

        return Button {
            selectedBudgetCategory = category
        } label: {
            HStack(spacing: 12) {
                HeroIcon(systemName: category.iconSystemName, size: 18)
                    .foregroundStyle(category.color)
                    .frame(width: 34, height: 34)
                    .background(category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(category.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(money(item.amount))
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.systemGray6))
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(proxy.size.width * min(progress, 1), 4))
                        }
                    }
                    .frame(height: 6)

                    HStack {
                        if let limit {
                            Text(String(format: "dash_budget_of_format".localized, compactMoney(limit)))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text(caption).foregroundStyle(captionColor)
                    }
                    .font(.caption2)
                    .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("dash_category_hint".localized)
    }

    // MARK: - Top places / largest expenses

    private var spotlightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("dash_spotlight".localized).font(.headline)

            Picker("dash_spotlight".localized, selection: $spotlight) {
                ForEach(Spotlight.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 0) {
                switch spotlight {
                case .places:
                    let items = overview.topTitles
                    let top = items.first?.amount ?? 1
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let category = dataManager.resolveCategory(id: item.categoryID)
                        rankedRow(
                            rank: index + 1,
                            icon: category.iconSystemName,
                            color: category.color,
                            title: item.title,
                            subtitle: String(format: "dash_times_format".localized, item.count),
                            amount: item.amount,
                            fraction: top > 0 ? item.amount / top : 0
                        )
                        if index < items.count - 1 { Divider().padding(.leading, 46) }
                    }
                case .largest:
                    let items = overview.largestExpenses
                    let top = items.first?.amount ?? 1
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, expense in
                        let category = dataManager.resolveCategory(id: expense.categoryId)
                        rankedRow(
                            rank: index + 1,
                            icon: category.iconSystemName,
                            color: category.color,
                            title: expense.title,
                            subtitle: "\(category.name) · \(expense.date.formatted(.dateTime.month(.abbreviated).day()))",
                            amount: expense.amount,
                            fraction: top > 0 ? expense.amount / top : 0
                        )
                        if index < items.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
            }
            .animation(.snappy, value: spotlight)
        }
        .dashboardCard()
    }

    private func rankedRow(rank: Int, icon: String, color: Color, title: String, subtitle: String, amount: Double, fraction: Double) -> some View {
        HStack(spacing: 12) {
            HeroIcon(systemName: icon, size: 18)
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(money(amount))
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Capsule()
                    .fill(color.opacity(0.55))
                    .frame(width: max(54 * fraction, 4), height: 3)
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rank). \(title), \(CurrencyFormatter.formatFull(amount, currency: currency))")
    }

    // MARK: - Weekday pattern

    private var weekdayPatternCard: some View {
        let items = overview.weekdayAverages
        let peak = overview.peakWeekday
        let symbols = calendar.shortWeekdaySymbols

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("dash_weekday_pattern".localized).font(.headline)
                Text("dash_weekday_subtitle".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart {
                ForEach(items) { item in
                    BarMark(
                        x: .value("Weekday", symbols[item.weekday - 1]),
                        y: .value("Average", item.average),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(6)
                    .foregroundStyle(item.weekday == peak?.weekday ? Color.accentColor : Color(.systemGray4))
                }
            }
            .chartXScale(domain: items.map { symbols[$0.weekday - 1] })
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(compactMoney(amount)).font(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 130)
            .accessibilityHidden(true)

            if let peak {
                HStack(spacing: 8) {
                    HeroIcon("sparkles", size: 16)
                        .foregroundStyle(Color.accentColor)
                    Text(String(
                        format: "dash_weekday_peak_format".localized,
                        calendar.weekdaySymbols[peak.weekday - 1],
                        money(peak.average)
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .dashboardCard()
    }

    // MARK: - Monthly history

    private var monthlyHistoryCard: some View {
        let history = overview.monthlyHistory
        let previousNonZero = history.dropLast().map(\.amount).filter { $0 > 0 }
        let average = previousNonZero.isEmpty ? 0 : previousNonZero.reduce(0, +) / Double(previousNonZero.count)
        let currentMonth = history.last?.month

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("dash_monthly_history".localized).font(.headline)
                Spacer()
                if average > 0 {
                    Text(String(format: "dash_monthly_average_format".localized, compactMoney(average)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(history, id: \.month) { item in
                    BarMark(
                        x: .value("Month", item.month, unit: .month),
                        y: .value("Amount", item.amount),
                        width: .ratio(0.55)
                    )
                    .cornerRadius(6)
                    .foregroundStyle(item.month == currentMonth ? Color.accentColor : Color(.systemGray4))
                    .annotation(position: .top, spacing: 4) {
                        if item.amount > 0 {
                            Text(compactMoney(item.amount))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(Color(.systemGray2))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                        .font(.caption2)
                }
            }
            .frame(height: 140)
            .accessibilityLabel("dash_monthly_history".localized)
            .accessibilityValue(history.map { "\($0.month.formatted(.dateTime.month(.wide))): \(CurrencyFormatter.formatFull($0.amount, currency: currency))" }.joined(separator: ", "))
        }
        .dashboardCard()
    }

    // MARK: - Lists

    private var upcomingBillsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader("upcoming_bills".localized, actionTitle: "view_all".localized) {
                tabManager.selectedTab = 2
            }
            VStack(spacing: 0) {
                ForEach(Array(upcomingBills.prefix(3).enumerated()), id: \.element.id) { index, bill in
                    let cat = dataManager.resolveCategory(id: bill.categoryId)
                    HStack(spacing: 12) {
                        HeroIcon(systemName: cat.iconSystemName, size: 18)
                            .foregroundStyle(cat.color)
                            .frame(width: 34, height: 34)
                            .background(cat.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bill.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(dueText(bill.nextDueDate))
                                .font(.caption)
                                .foregroundStyle(dueColor(bill.nextDueDate))
                        }
                        Spacer()
                        Text(money(bill.amount))
                            .font(.subheadline.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if index < min(upcomingBills.count, 3) - 1 { Divider().padding(.leading, 46) }
                }
            }
        }
        .dashboardCard()
    }

    private var emptyMonthCard: some View {
        Button {
            showingAddExpense = true
        } label: {
            VStack(spacing: 12) {
                HeroIcon("chart-bar", size: 30)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, height: 60)
                    .background(Color(.tertiarySystemFill), in: Circle())
                VStack(spacing: 4) {
                    Text((overview.recentExpenses.isEmpty ? "no_expenses_yet" : "dash_no_expenses_month").localized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("dash_empty_month_hint".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 6) {
                    HeroIcon("plus", size: 15)
                    Text("add_expense".localized)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(Color.accentColor, in: Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
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
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .liquidGlassSurface(Capsule())
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .contentShape(Rectangle())
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

    /// Running total on a given day of the month (1-based), for pace charts.
    struct DayPoint: Identifiable {
        let day: Int
        let amount: Double
        var id: Int { day }
    }

    struct DaySpend: Identifiable {
        let day: Date
        let amount: Double
        var id: Date { day }
    }

    /// One cell of the current-month calendar heatmap.
    struct CalendarDay: Identifiable {
        let date: Date
        /// Day of month, 1-based.
        let day: Int
        let amount: Double
        let count: Int
        let isFuture: Bool
        var id: Int { day }
    }

    /// Average spend on one weekday (1 = Sunday … 7 = Saturday, like `Calendar`).
    struct WeekdaySpend: Identifiable {
        let weekday: Int
        let average: Double
        var id: Int { weekday }
    }

    /// Expenses grouped by title (case- and whitespace-insensitive).
    struct TitleSpend: Identifiable {
        let title: String
        let categoryID: UUID
        let amount: Double
        let count: Int
        var id: String { title.lowercased() }
    }

    /// Weeks of history used for the weekday pattern.
    static let weekdayWindowWeeks = 12

    let monthExpenses: [Expense]
    let monthTotal: Double
    let categoryTotals: [UUID: Double]
    let sortedCategories: [CategorySpend]
    let recentExpenses: [Expense]
    let previousMonthsWithExpenses: [MonthSpend]
    let todayTotal: Double
    let todayCount: Int
    let daysElapsed: Int
    let daysInMonth: Int
    /// Day 1 through today of the current month.
    let monthCumulative: [DayPoint]
    /// Every day of last month; empty when nothing was recorded then.
    let previousMonthCumulative: [DayPoint]
    /// Last month's spending through the same day-of-month as today.
    let previousMonthToDateTotal: Double
    /// Oldest first, ending today.
    let lastSevenDays: [DaySpend]
    /// Every day of the current month, including future days (always zero).
    let calendarDays: [CalendarDay]
    /// Empty cells before day 1 so the month grid starts on `calendar.firstWeekday`.
    let leadingBlankDays: Int
    /// Seven entries ordered from `calendar.firstWeekday`.
    let weekdayAverages: [WeekdaySpend]
    /// Days of history behind `weekdayAverages` (from the first recorded expense in the window).
    let weekdaySampleDays: Int
    /// This month's most expensive titles, highest first (max 5).
    let topTitles: [TitleSpend]
    /// This month's single largest expenses, highest first (max 5).
    let largestExpenses: [Expense]
    /// The last six months including the current one (month-to-date), oldest first.
    let monthlyHistory: [MonthSpend]

    var dailyAverage: Double {
        daysElapsed > 0 ? monthTotal / Double(daysElapsed) : 0
    }

    /// Straight-line projection of the current pace to month end.
    var projectedMonthTotal: Double {
        dailyAverage * Double(daysInMonth)
    }

    /// Weekday with the highest average spend; nil when nothing was spent.
    var peakWeekday: WeekdaySpend? {
        weekdayAverages
            .filter { $0.average > 0 }
            .max { $0.average < $1.average }
    }

    /// Spending so far minus an even spread of `monthlyIncome` through today.
    /// Positive means spending is ahead of an even pace.
    func paceDifference(monthlyIncome: Double) -> Double {
        guard monthlyIncome > 0, daysInMonth > 0 else { return 0 }
        return monthTotal - monthlyIncome * Double(daysElapsed) / Double(daysInMonth)
    }

    init(expenses: [Expense], now: Date, calendar: Calendar = .current) {
        let month = BudgetPeriodCalculator.monthInterval(containing: now, calendar: calendar)
        let current = expenses.filter { month.contains($0.date) && $0.date <= now }
        let today = calendar.startOfDay(for: now)
        let past = expenses.filter { $0.date <= now }
        var dailyTotals: [Date: Double] = [:]
        var dailyCounts: [Date: Int] = [:]
        for expense in past {
            let day = calendar.startOfDay(for: expense.date)
            dailyTotals[day, default: 0] += expense.amount
            dailyCounts[day, default: 0] += 1
        }
        func runningTotals(from start: Date, days: Int) -> [DayPoint] {
            var total = 0.0
            return (0..<days).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
                total += dailyTotals[day, default: 0]
                return DayPoint(day: offset + 1, amount: total)
            }
        }

        todayTotal = dailyTotals[today, default: 0]
        todayCount = current.filter { calendar.isDate($0.date, inSameDayAs: now) }.count
        daysElapsed = calendar.component(.day, from: now)
        daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? daysElapsed
        monthCumulative = runningTotals(from: month.start, days: daysElapsed)

        let previousStart = calendar.date(byAdding: .month, value: -1, to: month.start) ?? month.start
        let previousDays = calendar.range(of: .day, in: .month, for: previousStart)?.count ?? 0
        let previous = runningTotals(from: previousStart, days: previousDays)
        previousMonthCumulative = (previous.last?.amount ?? 0) > 0 ? previous : []
        previousMonthToDateTotal = previousMonthCumulative.prefix(daysElapsed).last?.amount ?? 0
        lastSevenDays = (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map {
                DaySpend(day: $0, amount: dailyTotals[$0, default: 0])
            }
        }

        // Calendar heatmap
        calendarDays = (0..<daysInMonth).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: month.start) else { return nil }
            return CalendarDay(
                date: date,
                day: offset + 1,
                amount: dailyTotals[date, default: 0],
                count: dailyCounts[date, default: 0],
                isFuture: date > today
            )
        }
        leadingBlankDays = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7

        // Weekday pattern: averages over the last 12 weeks, starting at the first
        // recorded expense so new users are not diluted by empty weeks.
        let windowStart = calendar.date(byAdding: .day, value: -(Self.weekdayWindowWeeks * 7 - 1), to: today) ?? today
        let firstRecorded = dailyTotals.keys.filter { $0 >= windowStart && $0 <= today }.min()
        var weekdayTotals = [Int: Double]()
        var weekdayOccurrences = [Int: Int]()
        var sampleDays = 0
        if let firstRecorded {
            var day = firstRecorded
            while day <= today {
                let weekday = calendar.component(.weekday, from: day)
                weekdayTotals[weekday, default: 0] += dailyTotals[day, default: 0]
                weekdayOccurrences[weekday, default: 0] += 1
                sampleDays += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        weekdaySampleDays = sampleDays
        weekdayAverages = (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            let occurrences = weekdayOccurrences[weekday, default: 0]
            return WeekdaySpend(
                weekday: weekday,
                average: occurrences > 0 ? weekdayTotals[weekday, default: 0] / Double(occurrences) : 0
            )
        }

        // Top titles and largest single expenses this month
        let newestFirst = current.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        var groups: [String: (title: String, categoryID: UUID, amount: Double, count: Int)] = [:]
        var groupOrder: [String] = []
        for expense in newestFirst {
            let display = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = display.lowercased()
            guard !key.isEmpty else { continue }
            if var group = groups[key] {
                group.amount += expense.amount
                group.count += 1
                groups[key] = group
            } else {
                groups[key] = (display, expense.categoryId, expense.amount, 1)
                groupOrder.append(key)
            }
        }
        topTitles = Array(groupOrder
            .compactMap { groups[$0] }
            .map { TitleSpend(title: $0.title, categoryID: $0.categoryID, amount: $0.amount, count: $0.count) }
            .sorted {
                if $0.amount != $1.amount { return $0.amount > $1.amount }
                return $0.title.lowercased() < $1.title.lowercased()
            }
            .prefix(5))
        largestExpenses = Array(newestFirst
            .sorted { $0.amount > $1.amount }
            .prefix(5))

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
        recentExpenses = past.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }

        let historicalTotals = past.reduce(into: [Date: Double]()) { result, expense in
            guard let monthStart = calendar.dateInterval(of: .month, for: expense.date)?.start else {
                return
            }
            result[monthStart, default: 0] += expense.amount
        }
        previousMonthsWithExpenses = Array(historicalTotals
            .filter { $0.key < month.start && $0.value > 0 }
            .map { MonthSpend(month: $0.key, amount: $0.value) }
            .sorted { $0.month > $1.month }
            .prefix(3))
        monthlyHistory = (0..<6).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: month.start) else { return nil }
            return MonthSpend(month: start, amount: historicalTotals[start, default: 0])
        }
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
                            Color.accentColor : 
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
                    .progressViewStyle(LinearProgressViewStyle(tint: dataManager.getProgressPercentageForPeriod() > 0.8 ? Color(.systemRed) : Color.accentColor))
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
                            .foregroundColor(selectionStep == .firstDate ? .white : Color.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectionStep == .firstDate ? Color.accentColor : Color.accentColor.opacity(0.1))
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
                            .foregroundColor(selectionStep == .secondDate ? .white : Color.accentColor)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectionStep == .secondDate ? Color.accentColor : Color.accentColor.opacity(0.1))
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
                                .foregroundColor(Color.accentColor)
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
                                .foregroundColor(Color.accentColor)
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
