import SwiftUI
import Charts

/// Dashboard in the night street look (DESIGN.md, mockup v8): the month name over a skyline
/// whose lit windows are spending days, the money left standing on the street below it,
/// then glass groups with Big Shoulders headings. Three figures: cyclist, snacker, shopper.
struct DashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var tabManager = TabManager.shared
    @State private var showingAddExpense = false
    @StateObject private var voice = InlineVoiceExpenseController()
    @State private var showingMonthlySalary = false
    @State private var selectedBudgetCategory: UserCategory?
    @State private var showingBudgetSettings = false
    @State private var selectedPaceDay: Double?
    @State private var spotlight: Spotlight = .places
    /// Added to the hero amount until the pay scene's bill lands, then animated to 0.
    @State private var heroTick: Double = 0
    /// Bumped on every appear so the pay scene plays again.
    @State private var payRun = 0
    /// Lower sections grow in once they scroll into view; reset when the screen goes away.
    @State private var monthsShown = false
    /// Weekly highlights: the insight shown, whether the card is on screen, and a token
    /// bumped on manual changes so the 5 s timer starts over.
    @State private var insightIndex = 0
    @State private var insightsVisible = false
    @State private var insightTimerToken = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var overview = DashboardOverview(
        expenses: DataManager.shared.expenses,
        now: Date()
    )

    private let calendar = Calendar.current
    private let margin: CGFloat = 20

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
                // Plain VStack: a LazyVStack re-measured cards near the bottom, so the content jumped.
                VStack(alignment: .leading, spacing: 0) {
                    monthHeader
                        .padding(.horizontal, margin)
                        .padding(.top, 10)
                        // The voice HUD temporarily replaces the header visually,
                        // keeping its layout space without duplicate controls behind it.
                        .opacity(voice.isVisible && voice.prefill == nil ? 0 : 1)
                        .accessibilityHidden(voice.isVisible && voice.prefill == nil)

                    heroStreet
                        .padding(.horizontal, margin)
                        .padding(.top, 28)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dashboard.overview")

                    metricTrio
                        .padding(.horizontal, margin)
                        .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 30) {
                        if !upcomingBills.isEmpty {
                            upcomingBillsSection
                        }

                        // An empty month shows nothing here (owner, 2026-11-26).
                        if hasMonthSpending {
                            spendingPaceSection
                            categorySection
                            spotlightSection
                        }

                        if overview.weekdaySampleDays >= 14 {
                            let insights = weeklyInsights
                            if insights.count >= 2 {
                                weeklyHighlightsSection(insights)
                            }
                        }

                        if !overview.previousMonthsWithExpenses.isEmpty {
                            monthlyHistorySection
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, 30)
                }
                // Keeps the last group scrollable above the entry bar.
                .padding(.bottom, 96)

            }
            .background(NightGround())
            .overlay(alignment: .top) { topScrollEdgeFade }
            .expenseEntryBar(ExpenseEntryBar(accessibilityPrefix: "dashboard", compact: true, isRecording: voice.isRecording, isProcessing: voice.isProcessing, onAdd: {
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
            .sheet(item: $voice.batch, onDismiss: { voice.batchDidDismiss() }) { batch in
                VoiceExpenseBatchView(batch: batch)
            }
            .sheet(isPresented: $showingMonthlySalary) {
                MonthlySalaryView()
            }
            // Full pages in the Dashboard stack: the system back button returns here.
            .navigationDestination(item: $selectedBudgetCategory) { category in
                BudgetSettingsView(focusCategoryID: category.id)
            }
            .navigationDestination(isPresented: $showingBudgetSettings) {
                BudgetSettingsView()
            }
            .onAppear(perform: refreshOverview)
            .onAppear(perform: playPayScene)
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
            .onDisappear {
                voice.cancel()
                insightsVisible = false
                monthsShown = false
            }
            .onChange(of: dataManager.expenses) { _, _ in
                refreshOverview()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshOverview() }
            }
        }
    }

    /// Fades scrolled content out under the status bar: page ground at the top, clear 12 pt below it.
    private var topScrollEdgeFade: some View {
        GeometryReader { proxy in
            let ground = colorScheme == .dark ? NightTheme.ink : Color(.systemGroupedBackground)
            LinearGradient(colors: [ground, ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: proxy.safeAreaInsets.top + 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var currency: Currency { dataManager.user.currency }
    private var hasMonthSpending: Bool { overview.monthTotal > 0 }
    private var today: Int { calendar.component(.day, from: Date()) }

    private func money(_ amount: Double) -> String {
        CurrencyFormatter.format(amount, currency: currency)
    }

    private func compactMoney(_ amount: Double) -> String {
        CurrencyFormatter.formatCompact(amount, currency: currency)
    }

    private func fullMoney(_ amount: Double) -> String {
        CurrencyFormatter.formatFull(amount, currency: currency)
    }

    /// `compactMoney` without the currency unit ("5.1M"); other currencies keep their symbol.
    private func compactNumber(_ amount: Double) -> String {
        let text = compactMoney(amount)
        guard currency == .uzs, text.hasSuffix(" so'm") else { return text }
        return String(text.dropLast(" so'm".count))
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

    // MARK: - Header

    private var monthHeader: some View {
        let now = Date()
        let month = now.formatted(.dateTime.month(.wide))
        let title = month.prefix(1).uppercased() + month.dropFirst()
        let year = String(calendar.component(.year, from: now))

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(NightTheme.display(46))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Text(String(format: "dash_year_day_format".localized, year, today))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NightTheme.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Hero on the street

    private var heroStreet: some View {
        let income = monthlySalary
        let snapshot = spendableSnapshot
        let isOver = income > 0 && snapshot.availableAfterBills < 0
        let amount = income > 0 ? abs(snapshot.availableAfterBills) : overview.monthTotal

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(heroTitle(income: income, isOver: isOver))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NightTheme.secondaryLabel)
                Spacer(minLength: 8)
                if hasMonthSpending && overview.previousMonthToDateTotal > 0 {
                    monthComparisonChip
                }
            }

            heroAmount(amount, isOver: isOver)
                .padding(.top, 20)

            if income > 0 {
                Text(String(format: "dash_of_income_days_format".localized, money(income), snapshot.daysRemaining))
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(2)
                    .padding(.top, 6)

                budgetMeter(income: income, snapshot: snapshot)
                    .padding(.top, 16)
            } else {
                setIncomeButton
                    .padding(.top, 16)
            }
        }
    }

    private func heroTitle(income: Double, isOver: Bool) -> String {
        if income <= 0 { return "month_spending".localized }
        return isOver ? "dash_over_plan".localized : "dash_left_until_month_end".localized
    }

    /// The hero amount as it was before today's last expense, minus the current one: the
    /// pay scene starts from there and ticks down to the real value when the bill lands.
    private var heroTickStart: Double {
        guard let last = overview.monthExpenses.filter({ calendar.isDateInToday($0.date) }).max(by: { $0.date < $1.date }) else {
            return 0
        }
        let income = monthlySalary
        if income <= 0 { return -min(last.amount, overview.monthTotal) }
        // left to spend grows back by the expense; an over-plan amount shrinks
        return spendableSnapshot.availableAfterBills < 0 ? -min(last.amount, abs(spendableSnapshot.availableAfterBills)) : last.amount
    }

    private func playPayScene() {
        payRun += 1
        guard !reduceMotion, !typeSize.isAccessibilitySize else {
            heroTick = 0
            return
        }
        let start = heroTickStart
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { heroTick = start }
        guard start != 0 else { return }
        let run = payRun
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PayScene.billLands))
            guard run == payRun else { return }
            withAnimation(.snappy(duration: 0.5)) { heroTick = 0 }
        }
    }

    /// The big number in Big Shoulders 60 with a smaller unit; the pay scene plays beside it.
    private func heroAmount(_ amount: Double, isOver: Bool) -> some View {
        let full = fullMoney(amount)
        let shown = fullMoney(max(amount + heroTick, 0))
        let unit = " so'm"
        let number = currency == .uzs && shown.hasSuffix(unit) ? String(shown.dropLast(unit.count)) : shown
        let showsScene = !typeSize.isAccessibilitySize

        // The scene keeps the trailing edge of the row; a long amount scales down before it can reach it.
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number)
                    .font(NightTheme.display(60))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                if currency == .uzs {
                    Text("so'm")
                        .font(NightTheme.display(22, weight: .semibold, relativeTo: .title2))
                        .foregroundStyle(isOver ? Color(.systemRed) : NightTheme.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                }
            }
            .foregroundStyle(isOver ? Color(.systemRed) : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .layoutPriority(1)

            Spacer(minLength: 8)

            if showsScene {
                PayScene()
                    .id(payRun)
                    .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 1 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(full)
    }

    /// Change against the same days of last month, as a quiet glass chip.
    private var monthComparisonChip: some View {
        let previous = overview.previousMonthToDateTotal
        let change = (overview.monthTotal - previous) / previous
        let percent = Int((abs(change) * 100).rounded())
        let signed = (change > 0 ? "+" : change < 0 ? "\u{2212}" : "") + "\(percent)%"

        return Text(String(format: "dash_vs_last_month_format".localized, signed))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(NightTheme.glassFill))
            .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
    }

    /// Income split into spent (solid), reserved for scheduled bills (dashed) and free (track).
    private func budgetMeter(income: Double, snapshot: SpendableTodaySnapshot) -> some View {
        let spent = min(overview.monthTotal, income)
        let bills = min(max(snapshot.upcomingRecurring, 0), max(income - spent, 0))
        let overspent = overview.monthTotal > income
        let free = max(snapshot.availableAfterBills, 0)

        return VStack(alignment: .leading, spacing: 9) {
            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 2) {
                    if spent > 0 {
                        Rectangle()
                            .fill(overspent ? Color(.systemRed) : NightTheme.accent)
                            .frame(width: max(width * spent / income, 4))
                    }
                    if bills > 0 {
                        DashedFill(color: NightTheme.secondaryLabel)
                            .frame(width: max(width * bills / income, 4))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(NightTheme.track)
            .clipShape(Capsule())

            HStack(spacing: 14) {
                legendItem("dash_legend_spent".localized, value: compactMoney(overview.monthTotal))
                if snapshot.upcomingRecurring > 0 {
                    legendItem("dash_legend_bills".localized, value: compactMoney(snapshot.upcomingRecurring))
                }
                legendItem("dash_legend_free".localized, value: compactMoney(free))
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "dash_meter_a11y_format".localized,
                                   fullMoney(overview.monthTotal), fullMoney(snapshot.upcomingRecurring), fullMoney(free)))
    }

    private func legendItem(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(NightTheme.secondaryLabel)
            Text(value).foregroundStyle(.primary).monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var setIncomeButton: some View {
        Button {
            showingMonthlySalary = true
        } label: {
            HStack(spacing: 12) {
                rowIcon(HeroIcon("wallet", size: 17))
                VStack(alignment: .leading, spacing: 2) {
                    Text("set_income_for_budget".localized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("dash_set_income_hint".localized)
                        .font(.caption)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                Spacer(minLength: 8)
                HeroIcon("chevron-right", size: 13)
                    .foregroundStyle(NightTheme.secondaryLabel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .nightGroup()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metric trio

    private var metricTrio: some View {
        let income = monthlySalary
        let snapshot = spendableSnapshot
        let forecastOverIncome = income > 0 && overview.projectedMonthTotal > income

        return HStack(spacing: 0) {
            if income > 0 {
                trioItem("dash_safe_per_day".localized, value: money(snapshot.spendableToday),
                         color: snapshot.availableAfterBills <= 0 ? Color(.systemRed) : .primary, first: true)
                trioDivider
            }
            trioItem("dash_daily_average".localized, value: hasMonthSpending ? money(overview.dailyAverage) : "—",
                     first: income <= 0)
            trioDivider
            trioItem("dash_forecast".localized, value: hasMonthSpending ? money(overview.projectedMonthTotal) : "—",
                     color: forecastOverIncome ? Color(.systemRed) : .primary)
        }
        .overlay(alignment: .top) { Rectangle().fill(NightTheme.hair).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(NightTheme.hair).frame(height: 1) }
    }

    private var trioDivider: some View {
        Rectangle().fill(NightTheme.hair).frame(width: 1)
    }

    private func trioItem(_ title: String, value: String, color: Color = .primary, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(NightTheme.display(22, weight: .bold, relativeTo: .title2))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 12)
        .padding(.leading, first ? 0 : 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Spending pace

    private var spendingPaceSection: some View {
        let days = max(overview.daysInMonth, 1)
        let current = overview.monthCumulative
        let previous = overview.previousMonthCumulative.filter { $0.day <= days }
        let maxY = max(current.last?.amount ?? 0, previous.map(\.amount).max() ?? 0, 1) * 1.1
        let dailyMax = max(overview.calendarDays.map(\.amount).max() ?? 0, 1)
        let barScale = maxY * 0.38 / dailyMax
        let selected = selectedPaceDay.map { min(max(Int($0.rounded()), 1), days) }
        let soFar = selected.flatMap { day in current.first { $0.day == day }?.amount } ?? overview.monthTotal
        let lastAtDay = selected.flatMap { day in previous.first { $0.day == day }?.amount } ?? overview.previousMonthToDateTotal
        let hasPrevious = !previous.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "dash_spending_pace".localized)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.map { String(format: "dash_day_format".localized, $0) } ?? "dash_so_far".localized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(NightTheme.secondaryLabel)
                        Text(compactMoney(soFar))
                            .font(NightTheme.display(30))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .accessibilityElement(children: .combine)
                    if hasPrevious {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("dashboard_last_month".localized)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(NightTheme.secondaryLabel)
                            Text(compactMoney(lastAtDay))
                                .font(NightTheme.display(17, weight: .semibold, relativeTo: .headline))
                                .foregroundStyle(NightTheme.secondaryLabel)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer(minLength: 0)
                    if hasPrevious, selected == nil {
                        paceDeltaChip(current: soFar, previous: lastAtDay)
                            .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 2 }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                paceChart(days: days, current: current, previous: previous, maxY: maxY, barScale: barScale)
                    .frame(height: 140)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .accessibilityLabel("dash_spending_pace".localized)
                    .accessibilityValue(String(format: "dash_pace_a11y_format".localized,
                                               fullMoney(overview.monthTotal), fullMoney(overview.previousMonthToDateTotal)))

                HStack(spacing: 14) {
                    paceKey("dash_key_month_total".localized) {
                        Capsule().fill(NightTheme.accent).frame(width: 14, height: 2)
                    }
                    if hasPrevious {
                        paceKey("dashboard_last_month".localized) {
                            Capsule()
                                .stroke(NightTheme.secondaryLabel, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                                .frame(width: 14, height: 1)
                        }
                    }
                    paceKey("dash_key_daily".localized) {
                        RoundedRectangle(cornerRadius: 1.5).fill(paceBarColor(today: false)).frame(width: 6, height: 9)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
            }
            .nightGroup()
        }
    }

    private func paceDeltaChip(current: Double, previous: Double) -> some View {
        let diff = current - previous
        let less = diff <= 0
        let tint = less ? Color(.systemGreen) : Color(.systemRed)
        return Text(String(format: (less ? "dash_delta_less_format" : "dash_delta_more_format").localized, compactMoney(abs(diff))))
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func paceBarColor(today: Bool) -> Color {
        if colorScheme == .dark {
            return today ? Color(red: 58 / 255, green: 69 / 255, blue: 102 / 255) : Color(red: 34 / 255, green: 43 / 255, blue: 68 / 255)
        }
        return NightTheme.ink.opacity(today ? 0.24 : 0.12)
    }

    private func paceKey<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 5) {
            mark()
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
        }
    }

    /// Daily spend as small buildings along the bottom (today has a lit window), the running
    /// total as a line with a soft fill, and last month dashed on the same scale.
    private func paceChart(days: Int, current: [DashboardOverview.DayPoint], previous: [DashboardOverview.DayPoint],
                           maxY: Double, barScale: Double) -> some View {
        let todayPoint = current.last
        let monthStart = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let firstLabel = "1 " + monthStart.formatted(.dateTime.month(.abbreviated))

        return GeometryReader { proxy in
            let barWidth = max(proxy.size.width / Double(days) * 0.62, 2)
            Chart {
                ForEach(overview.calendarDays) { day in
                    if day.isFuture {
                        BarMark(x: .value("Day", Double(day.day)), yStart: .value("Amount", 0.0),
                                yEnd: .value("Amount", maxY * 0.015), width: .fixed(barWidth))
                            .foregroundStyle(NightTheme.accent.opacity(0.10))
                            .cornerRadius(1)
                    } else if day.amount > 0 {
                        BarMark(x: .value("Day", Double(day.day)), yStart: .value("Amount", 0.0),
                                yEnd: .value("Amount", day.amount * barScale), width: .fixed(barWidth))
                            .foregroundStyle(paceBarColor(today: day.day == todayPoint?.day))
                            .cornerRadius(1.2)
                            .annotation(position: .overlay, alignment: .top) {
                                if day.day == todayPoint?.day {
                                    Rectangle().fill(NightTheme.window).frame(width: 3.2, height: 4).padding(.top, 3)
                                }
                            }
                    }
                }

                ForEach(current) { point in
                    AreaMark(x: .value("Day", Double(point.day)), y: .value("Amount", point.amount))
                        .foregroundStyle(LinearGradient(
                            colors: [NightTheme.accent.opacity(0.16), NightTheme.accent.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                ForEach(previous) { point in
                    LineMark(x: .value("Day", Double(point.day)), y: .value("Amount", point.amount),
                             series: .value("Month", "previous"))
                        .foregroundStyle(NightTheme.secondaryLabel.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 4]))
                        .interpolationMethod(.monotone)
                }
                ForEach(current) { point in
                    LineMark(x: .value("Day", Double(point.day)), y: .value("Amount", point.amount),
                             series: .value("Month", "current"))
                        .foregroundStyle(NightTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }

                RuleMark(y: .value("Amount", 0.0))
                    .foregroundStyle(NightTheme.accent.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                if let selectedPaceDay {
                    RuleMark(x: .value("Day", selectedPaceDay.rounded()))
                        .foregroundStyle(NightTheme.secondaryLabel.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                } else if let todayPoint {
                    PointMark(x: .value("Day", Double(todayPoint.day)), y: .value("Amount", todayPoint.amount))
                        .symbol {
                            ZStack {
                                Circle().fill(NightTheme.accent.opacity(0.14)).frame(width: 16, height: 16)
                                Circle().fill(NightTheme.accent).frame(width: 7.6, height: 7.6)
                                    .overlay(Circle().stroke(colorScheme == .dark ? NightTheme.ink : .white, lineWidth: 1.5))
                            }
                        }
                        .annotation(position: .top, spacing: 4) {
                            Text("dash_today_short".localized)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                        }
                }
            }
            .chartXScale(domain: 0.5...(Double(days) + 0.5))
            .chartYScale(domain: 0...maxY)
            .chartXSelection(value: $selectedPaceDay)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [1.0, 15.0, Double(days)]) { value in
                    AxisValueLabel {
                        if let day = value.as(Double.self) {
                            Text(day == 1 ? firstLabel : String(Int(day)))
                                .font(.caption2)
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
        }
    }

    // MARK: - Categories

    private var categorySection: some View {
        let rows = categoryRows
        let budgets = activeBudgets
        let topAmount = overview.sortedCategories.first?.amount ?? 1

        return VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "dash_where_it_goes".localized, figure: .shopper,
                               actionTitle: "dash_budgets".localized) {
                showingBudgetSettings = true
            }

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.categoryID) { index, item in
                    if index > 0 { rowDivider }
                    categoryRow(item, limit: budgets[item.categoryID], topAmount: topAmount)
                }
                if overview.sortedCategories.count > rows.count {
                    rowDivider
                    HStack {
                        Text("other_categories".localized)
                        Spacer()
                        Text(money(overview.sortedCategories.dropFirst(rows.count).reduce(0) { $0 + $1.amount }))
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            .nightGroup()
        }
    }

    private func categoryRow(_ item: DashboardOverview.CategorySpend, limit: Double?, topAmount: Double) -> some View {
        let category = dataManager.resolveCategory(id: item.categoryID)
        let progress = limit.map { item.amount / $0 } ?? (topAmount > 0 ? item.amount / topAmount : 0)
        let isOver = (limit.map { item.amount > $0 }) ?? false
        let caption: String? = limit.map { limit in
            isOver
                ? String(format: "dash_budget_over_format".localized, compactMoney(item.amount - limit))
                : String(format: "dash_budget_of_format".localized, compactMoney(limit))
        }

        return Button {
            selectedBudgetCategory = category
        } label: {
            HStack(spacing: 12) {
                rowIcon(HeroIcon(systemName: category.iconSystemName, size: 17))

                VStack(alignment: .leading, spacing: 7) {
                    Text(category.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NightTheme.track)
                            Capsule()
                                .fill(isOver ? Color(.systemRed) : NightTheme.accent)
                                .frame(width: max(proxy.size.width * min(progress, 1), 4))
                        }
                    }
                    .frame(height: 4)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(compactMoney(item.amount))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isOver ? Color(.systemRed) : .primary)
                        .lineLimit(1)
                    if let caption {
                        Text(caption)
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(isOver ? Color(.systemRed) : NightTheme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([category.name, fullMoney(item.amount), caption].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("dash_category_hint".localized)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Top places / largest expenses

    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "dash_spotlight".localized)

            VStack(spacing: 0) {
                Picker("dash_spotlight".localized, selection: $spotlight) {
                    ForEach(Spotlight.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

                switch spotlight {
                case .places:
                    let items = overview.topTitles
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { rowDivider }
                        rankedRow(
                            rank: index + 1,
                            icon: dataManager.resolveCategory(id: item.categoryID).iconSystemName,
                            title: item.title,
                            subtitle: String(format: "dash_times_format".localized, item.count),
                            amount: item.amount
                        )
                    }
                case .largest:
                    let items = overview.largestExpenses
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, expense in
                        let category = dataManager.resolveCategory(id: expense.categoryId)
                        if index > 0 { rowDivider }
                        rankedRow(
                            rank: index + 1,
                            icon: category.iconSystemName,
                            title: expense.title,
                            subtitle: "\(category.name) · \(expense.date.formatted(.dateTime.month(.abbreviated).day()))",
                            amount: expense.amount
                        )
                    }
                }
            }
            .animation(.snappy, value: spotlight)
            .nightGroup()
        }
    }

    private func rankedRow(rank: Int, icon: String, title: String, subtitle: String, amount: Double) -> some View {
        HStack(spacing: 12) {
            rowIcon(HeroIcon(systemName: icon, size: 17))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(compactMoney(amount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(title), \(subtitle), \(fullMoney(amount))")
    }

    // MARK: - Weekday pattern

    /// Ease used by the bars that grow in when a section scrolls into view.
    private func growIn(delay: Double) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(delay)
    }

    /// A localized lead sentence: the `**%@**` parts read primary semibold, the rest secondary.
    private func leadText(_ key: String, _ args: [String], strongFont: Font = .subheadline.weight(.semibold)) -> Text {
        var result = AttributedString()
        var rest = Substring(key.localized)
        var index = 0
        func plain(_ text: Substring) -> AttributedString {
            var part = AttributedString(String(text))
            part.swiftUI.foregroundColor = NightTheme.secondaryLabel
            return part
        }
        while let range = rest.range(of: "%@") {
            var before = rest[..<range.lowerBound]
            var after = rest[range.upperBound...]
            let strong = before.hasSuffix("**") && after.hasPrefix("**")
            if strong {
                before = before.dropLast(2)
                after = after.dropFirst(2)
            }
            result += plain(before)
            var value = AttributedString(index < args.count ? args[index] : "")
            value.swiftUI.foregroundColor = strong ? Color.primary : NightTheme.secondaryLabel
            if strong { value.swiftUI.font = strongFont }
            result += value
            index += 1
            rest = after
        }
        result += plain(rest)
        return Text(result)
    }

    /// The same sentence as plain text, for VoiceOver.
    private func leadString(_ key: String, _ args: [String]) -> String {
        String(format: key.localized.replacingOccurrences(of: "**", with: ""), arguments: args.map { $0 as CVarArg })
    }

    // MARK: - Weekly highlights

    /// The weekday highlights for the current data; the section shows only with 2 or more.
    private var weeklyInsights: [DashboardOverview.WeeklyInsight] {
        overview.weeklyInsights(
            weekdayName: { weekday in
                let name = calendar.weekdaySymbols[weekday - 1]
                let capitalized = name.prefix(1).uppercased() + name.dropFirst()
                return String(format: "dash_week_days_format".localized, capitalized)
            },
            money: compactMoney,
            category: { id in
                let category = dataManager.resolveCategory(id: id)
                return (category.name, category.iconSystemName)
            }
        )
    }

    /// Auto-advance runs only while the card is on screen, the app is active, and neither
    /// Reduce Motion nor VoiceOver is on.
    private func autoRotates(_ count: Int) -> Bool {
        count > 1 && insightsVisible && scenePhase == .active && !reduceMotion && !voiceOverEnabled
    }

    private func showInsight(_ index: Int, count: Int, manual: Bool) {
        guard count > 0 else { return }
        let next = ((index % count) + count) % count
        withAnimation(.easeOut(duration: 0.45)) { insightIndex = next }
        if manual { insightTimerToken += 1 }
    }

    private func insightContent(_ insight: DashboardOverview.WeeklyInsight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(HeroIcon(systemName: insight.icon, size: 17).foregroundStyle(NightTheme.window))
            VStack(alignment: .leading, spacing: 4) {
                leadText(insight.headlineKey, insight.headlineArgs, strongFont: .body.weight(.semibold))
                    .font(.body)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(insight.caption)
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weeklyHighlightsSection(_ insights: [DashboardOverview.WeeklyInsight]) -> some View {
        let count = insights.count
        let index = insightIndex % count
        let current = insights[index]
        let rotates = autoRotates(count)
        let transition: AnyTransition = reduceMotion
            ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                          removal: .opacity.combined(with: .offset(y: -6)))

        return VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "dash_week_title".localized)

            VStack(alignment: .leading, spacing: 14) {
                // Every insight laid out hidden keeps the card at the tallest one's height,
                // so rotating never moves the page.
                ZStack(alignment: .topLeading) {
                    ForEach(insights) { insight in
                        insightContent(insight).hidden()
                    }
                    insightContent(current)
                        .id(current.id)
                        .transition(transition)
                }

                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { dot in
                            Capsule()
                                .fill(dot == index ? NightTheme.accent : NightTheme.secondaryLabel.opacity(0.35))
                                .frame(width: dot == index ? 16 : 6, height: 6)
                                .padding(.horizontal, 3)
                                .frame(height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture { showInsight(dot, count: count, manual: true) }
                        }
                    }
                    .padding(.leading, -3)
                    // 44 pt tall hit area without making the row taller
                    .padding(.vertical, -19)
                    .transaction { if reduceMotion { $0.animation = nil } }

                    Spacer(minLength: 8)

                    Text("dash_week_footnote".localized)
                        .font(.caption2)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .nightGroup()
            .contentShape(Rectangle())
            .onTapGesture { showInsight(index + 1, count: count, manual: true) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > 40, abs(dx) > abs(value.translation.height) else { return }
                    showInsight(index + (dx < 0 ? 1 : -1), count: count, manual: true)
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(leadString(current.headlineKey, current.headlineArgs) + ". " + current.caption)
            .accessibilityHint("dash_week_hint".localized)
            .accessibilityAdjustableAction { direction in
                let step: Int
                switch direction {
                case .increment: step = 1
                case .decrement: step = -1
                @unknown default: return
                }
                let next = ((index + step) % count + count) % count
                showInsight(next, count: count, manual: true)
                let insight = insights[next]
                AccessibilityNotification.Announcement(
                    leadString(insight.headlineKey, insight.headlineArgs) + ". " + insight.caption
                ).post()
            }
            .onScrollVisibilityChange(threshold: 0.4) { visible in
                insightsVisible = visible
            }
            .task(id: rotates ? insightTimerToken : -1) {
                guard rotates else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { break }
                    showInsight(insightIndex + 1, count: count, manual: false)
                }
            }
        }
    }

    // MARK: - Monthly history

    private var monthlyHistorySection: some View {
        let history = overview.monthlyHistory
        let previousNonZero = history.dropLast().map(\.amount).filter { $0 > 0 }
        let average = previousNonZero.isEmpty ? 0 : previousNonZero.reduce(0, +) / Double(previousNonZero.count)
        let forecast = max(overview.projectedMonthTotal, history.last?.amount ?? 0)
        let scale = max(history.map(\.amount).max() ?? 0, forecast, average, 1)
        let currentName = monthName(history.last?.month ?? Date())
        let leadKey = forecast - average <= 0 ? "dash_month_less_lead_format" : "dash_month_more_lead_format"
        let leadArgs = [currentName, compactMoney(abs(forecast - average))]
        // an empty month would read as "less than average", so no lead until something is spent
        let hasLead = average > 0 && hasMonthSpending
        let on = monthsShown || reduceMotion
        // fixed columns around the track, so the average line can be placed over all rows at once
        let nameWidth: CGFloat = 66
        let amountWidth: CGFloat = 70
        let columnSpacing: CGFloat = 10

        return VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "dash_last_six_months".localized)

            VStack(alignment: .leading, spacing: 0) {
                if hasLead {
                    leadText(leadKey, leadArgs)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }

                VStack(spacing: 9) {
                    ForEach(Array(history.enumerated()), id: \.element.month) { index, item in
                        let isNow = index == history.count - 1
                        HStack(alignment: .center, spacing: columnSpacing) {
                            Text(monthName(item.month, short: true))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(isNow ? AnyShapeStyle(.primary) : AnyShapeStyle(NightTheme.secondaryLabel))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: nameWidth, alignment: .leading)
                                .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - 4 }
                            GeometryReader { proxy in
                                let width = proxy.size.width
                                ZStack(alignment: .leading) {
                                    Capsule().fill(NightTheme.track)
                                    ZStack(alignment: .leading) {
                                        if isNow {
                                            DashedFill(color: NightTheme.accent.opacity(0.45))
                                                .frame(width: width * forecast / scale)
                                                .clipShape(Capsule())
                                        }
                                        Capsule()
                                            .fill(isNow ? NightTheme.accent : paceBarColor(today: true))
                                            .frame(width: max(width * item.amount / scale, item.amount > 0 ? 3 : 0))
                                    }
                                    .scaleEffect(x: on ? 1 : 0.001, y: 1, anchor: .leading)
                                    .animation(reduceMotion ? nil : growIn(delay: 0.1 + Double(index) * 0.06), value: on)
                                }
                            }
                            .frame(height: 10)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(compactNumber(item.amount))
                                    .font(.footnote.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(isNow ? AnyShapeStyle(.primary) : AnyShapeStyle(NightTheme.secondaryLabel))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if isNow, forecast > 0, compactNumber(forecast) != compactNumber(item.amount) {
                                    Text("\u{2192} " + compactNumber(forecast))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(NightTheme.secondaryLabel)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                            .frame(width: amountWidth, alignment: .trailing)
                            .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - 4 }
                        }
                        .background {
                            if isNow {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(NightTheme.iconFill)
                                    .padding(.horizontal, -8)
                                    .padding(.vertical, -6)
                            }
                        }
                    }
                }
                .overlay {
                    if average > 0 {
                        GeometryReader { proxy in
                            let trackX = nameWidth + columnSpacing
                            let trackWidth = max(proxy.size.width - trackX - columnSpacing - amountWidth, 0)
                            let x = trackX + trackWidth * average / scale
                            StraightLine(vertical: true)
                                .stroke(NightTheme.window.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 2, height: proxy.size.height + 2)
                                .position(x: x, y: proxy.size.height / 2 - 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

                HStack(spacing: 12) {
                    paceKey("dash_legend_spent".localized) {
                        RoundedRectangle(cornerRadius: 2).fill(NightTheme.accent).frame(width: 12, height: 8)
                    }
                    paceKey("dash_key_forecast".localized) {
                        DashedFill(color: NightTheme.accent.opacity(0.6)).frame(width: 12, height: 8)
                    }
                    if average > 0 {
                        paceKey(String(format: "dash_key_average_format".localized, compactMoney(average))) {
                            Rectangle()
                                .stroke(NightTheme.window.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                                .frame(width: 0.1, height: 10)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .nightGroup()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([hasLead ? leadString(leadKey, leadArgs) : ""] + history.map { "\(monthName($0.month)): \(fullMoney($0.amount))" })
                .filter { !$0.isEmpty }.joined(separator: ". "))
            .onScrollVisibilityChange(threshold: 0.4) { visible in
                if visible { monthsShown = true }
            }
        }
    }

    /// Wide month name, capitalised. `short` gives English "Jun"; other languages keep the wide
    /// name because their short forms read oddly (Uzbek).
    private func monthName(_ date: Date, short: Bool = false) -> String {
        let abbreviated = short && Locale.current.language.languageCode == .english
        let name = date.formatted(.dateTime.month(abbreviated ? .abbreviated : .wide))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Upcoming bills

    private var upcomingBillsSection: some View {
        let bills = Array(upcomingBills.prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            NightSectionHeader(title: "upcoming_bills".localized, actionTitle: "view_all".localized) {
                tabManager.selectedTab = 2
            }
            VStack(spacing: 0) {
                ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                    if index > 0 { rowDivider }
                    let category = dataManager.resolveCategory(id: bill.categoryId)
                    HStack(spacing: 12) {
                        rowIcon(HeroIcon(systemName: category.iconSystemName, size: 17))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bill.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(dueText(bill.nextDueDate))
                                .font(.caption)
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                        Spacer(minLength: 8)
                        Text(money(bill.amount))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(bill.title), \(dueText(bill.nextDueDate)), \(fullMoney(bill.amount))")
                }
            }
            .nightGroup()
        }
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Rectangle().fill(NightTheme.hair).frame(height: 1).padding(.leading, 60)
    }

    private func rowIcon<Icon: View>(_ icon: Icon) -> some View {
        icon
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
            .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private func dueText(_ date: Date) -> String {
        if calendar.isDateInToday(date) { return "due_today".localized }
        if calendar.isDateInTomorrow(date) { return "due_tomorrow".localized }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        return String(format: "due_in_days_format".localized, days)
    }
}

/// A somsa stand beside the hero amount (mockup v11): the buyer walks in, hands a warm bill
/// to the seller and gets a warm bag back, once each time the dashboard appears (~2.6 s).
/// After that both people keep moving gently: the buyer breathes and swings the bag, the
/// seller bobs and serves, and steam rises from the counter. Reduce Motion draws the end
/// state with nothing moving. Decoration only.
struct PayScene: View {
    static let size = CGSize(width: 96, height: 30)
    /// When the bill reaches the seller; the amount ticks down then.
    static let billLands = 1.85
    private static let duration = 2.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || start == nil)) { tl in
            let t = reduceMotion ? Self.duration : start.map { tl.date.timeIntervalSince($0) } ?? 0
            Canvas { ctx, _ in draw(ctx, t: min(t, Self.duration), idle: max(t - Self.duration, 0)) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if start == nil { start = .now } }
    }

    private static func progress(_ t: Double, from: Double, length: Double) -> Double {
        min(max((t - from) / length, 0), 1)
    }

    /// 0 at the start of the loop, rising to 1 and back over `period` seconds.
    private static func wave(_ idle: Double, period: Double, phase: Double = 0) -> Double {
        0.5 * (1 - cos(2 * .pi * (idle / period + phase)))
    }

    /// `t` drives the intro (clamped to its length); `idle` counts the seconds since it ended.
    private func draw(_ ctx: GraphicsContext, t: Double, idle: Double) {
        let ink = NightTheme.figure(colorScheme)
        let warm = NightTheme.window
        let dark = colorScheme == .dark
        let roof = dark ? NightTheme.silver : Color(red: 127 / 255, green: 138 / 255, blue: 160 / 255)
        let pole = Color(red: 127 / 255, green: 138 / 255, blue: 160 / 255)
        let counter = dark ? Color(red: 42 / 255, green: 51 / 255, blue: 80 / 255) : NightTheme.ink.opacity(0.75)

        // idle loop: eases in over 0.6 s so nothing jumps when the intro ends
        let ramp = min(idle / 0.6, 1)
        let buyerBob = 0.6 * Self.wave(idle, period: 2.4) * ramp
        let sellerBob = 0.6 * Self.wave(idle, period: 2.4, phase: 0.35) * ramp
        let bagSwing = sin(2 * .pi * idle / 1.6) * ramp
        let serve = Self.wave(idle, period: 1.8) * ramp

        // stand: striped awning, poles, seller behind the counter
        ctx.fill(Path(roundedRect: CGRect(x: 64, y: 4, width: 30, height: 4), cornerRadius: 1), with: .color(roof))
        for x in stride(from: 64.0, to: 94, by: 6) {
            ctx.fill(Path(CGRect(x: x, y: 7.5, width: 3, height: 1)), with: .color(NightTheme.ink))
        }
        ctx.fill(Path(CGRect(x: 66, y: 8, width: 1.6, height: 8)), with: .color(pole))
        ctx.fill(Path(CGRect(x: 90.4, y: 8, width: 1.6, height: 8)), with: .color(pole))
        ctx.fill(Path(ellipseIn: CGRect(x: 77.4, y: 8.4 - sellerBob, width: 5.2, height: 5.2)), with: .color(ink))
        ctx.fill(Path(CGRect(x: 77, y: 14 - sellerBob, width: 6, height: 4 + sellerBob)), with: .color(ink))
        ctx.fill(Path(roundedRect: CGRect(x: 63, y: 17, width: 32, height: 12), cornerRadius: 1.5), with: .color(counter))
        ctx.fill(Path(roundedRect: CGRect(x: 70, y: 20, width: 18, height: 2), cornerRadius: 1), with: .color(warm.opacity(0.85)))

        // seller's arm: rests on the counter, rises and falls as if serving
        var sellerArm = Path()
        sellerArm.move(to: CGPoint(x: 77.6, y: 14.8 - sellerBob))
        sellerArm.addLine(to: CGPoint(x: 74.6, y: 17 - 2.6 * serve))
        ctx.stroke(sellerArm, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        // steam: small warm dots rising 6 pt from the warm strip and fading, staggered
        if ramp > 0 {
            for (index, x) in [71.5, 75.0, 85.5].enumerated() {
                let p = (idle / 2 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let fade = p < 0.2 ? p / 0.2 : 1 - (p - 0.2) / 0.8
                let drift = sin(p * .pi * 2 + Double(index)) * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: x + drift - 0.9, y: 19 - 6 * p - 0.9, width: 1.8, height: 1.8)),
                         with: .color(warm.opacity(0.8 * fade * ramp)))
            }
        }

        // buyer walk-in progress (the bill travels with the buyer until it is handed over)
        let w = Self.progress(t, from: 0.4, length: 0.9)
        let we = 1 - pow(1 - w, 4)

        // bill: in the buyer's hand, slides 18 pt to the seller, gone once it lands
        let b = Self.progress(t, from: 1.3, length: 0.7)
        if b < 1 {
            let dx = (b < 0.75 ? 17 * (b / 0.75) : 17 + (b - 0.75) / 0.25) - 34 * (1 - we)
            let alpha = (b < 0.75 ? 1 : 1 - (b - 0.75) / 0.25) * we
            ctx.fill(Path(roundedRect: CGRect(x: 49 + dx, y: 13, width: 6, height: 3.6), cornerRadius: 0.6), with: .color(warm.opacity(alpha)))
        }

        // bag: on the counter, handed 20 pt to the buyer, then swings slightly in the hand
        let g = Self.progress(t, from: 2.0, length: 0.6)
        let ge = 1 - pow(1 - g, 4)
        ctx.fill(Path(roundedRect: CGRect(x: 68 - 20 * ge + bagSwing, y: 15 + 2 * ge - buyerBob, width: 5, height: 6), cornerRadius: 1), with: .color(warm))

        // buyer walks in 34 pt and fades in, then breathes (head, body and arm bob; feet stay)
        var buyer = ctx
        buyer.opacity = we
        buyer.translateBy(x: -34 * (1 - we), y: 0)
        let walking = w > 0 && w < 1
        let swing = walking ? sin(t * 14) * 1.5 : 0
        buyer.fill(Path(ellipseIn: CGRect(x: 41.4, y: 7.4 - buyerBob, width: 5.2, height: 5.2)), with: .color(ink))
        var body = Path()
        body.move(to: CGPoint(x: 42, y: 13 - buyerBob)); body.addLine(to: CGPoint(x: 46.5, y: 13 - buyerBob))
        body.addLine(to: CGPoint(x: 47.5, y: 21)); body.addLine(to: CGPoint(x: 41, y: 21)); body.closeSubpath()
        buyer.fill(body, with: .color(ink))
        var legs = Path()
        legs.move(to: CGPoint(x: 43, y: 21)); legs.addLine(to: CGPoint(x: 41 + swing, y: 29))
        legs.move(to: CGPoint(x: 46, y: 21)); legs.addLine(to: CGPoint(x: 48 - swing, y: 29))
        buyer.stroke(legs, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        var arm = Path()
        arm.move(to: CGPoint(x: 46, y: 14 - buyerBob)); arm.addLine(to: CGPoint(x: 50, y: 15 - buyerBob))
        buyer.stroke(arm, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }
}

/// A straight line through the middle of its frame, for dashed guide lines.
private struct StraightLine: Shape {
    var vertical = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if vertical {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        return path
    }
}

/// The bills share of the budget meter: short silver dashes.
private struct DashedFill: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            var x = 0.0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: min(4, size.width - x), height: size.height)), with: .color(color))
                x += 7
            }
        }
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
    /// Same window as `weekdayAverages`: weekday (1 = Sunday … 7 = Saturday) → category → total.
    let weekdayCategoryTotals: [Int: [UUID: Double]]
    /// Same window: number of distinct days each category had an expense.
    let categoryExpenseDays: [UUID: Int]
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

    /// One written line of the weekly highlights card. `headlineKey` is a lead format whose
    /// `**%@**` parts read bold.
    struct WeeklyInsight: Identifiable, Equatable {
        enum Kind: Hashable {
            case peakDay, lightestDay, weekendRatio, peakDayCategory, categoryWeekday
        }

        let kind: Kind
        /// SF Symbol or Heroicon name, resolved by `HeroIcon`.
        let icon: String
        let headlineKey: String
        let headlineArgs: [String]
        let caption: String
        var id: Kind { kind }
    }

    /// Written highlights from the weekday window, in display order; each one only when its
    /// data says something. `weekdayName` gets 1 = Sunday … 7 = Saturday and returns the
    /// plural form used in the sentences ("Saturdays").
    func weeklyInsights(
        weekdayName: (Int) -> String,
        money: (Double) -> String,
        category: (UUID) -> (name: String, icon: String)
    ) -> [WeeklyInsight] {
        var insights: [WeeklyInsight] = []
        let averages = Dictionary(uniqueKeysWithValues: weekdayAverages.map { ($0.weekday, $0.average) })
        func average(_ weekday: Int) -> Double { averages[weekday] ?? 0 }
        func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }
        func topCategory(_ totals: [UUID: Double]) -> (id: UUID, amount: Double)? {
            totals
                .filter { $0.value > 0 }
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString > $1.key.uuidString }
                .map { ($0.key, $0.value) }
        }

        // 1. Peak day
        let peak = peakWeekday
        if let peak {
            let others = (1...7).filter { $0 != peak.weekday }.map(average)
            let othersMean = others.reduce(0, +) / Double(others.count)
            let above = peak.average - othersMean
            if above > 0 {
                insights.append(WeeklyInsight(
                    kind: .peakDay,
                    icon: "flame.fill",
                    headlineKey: "dash_week_peak_format",
                    headlineArgs: [weekdayName(peak.weekday)],
                    caption: String(format: "dash_week_peak_caption_format".localized, money(peak.average), money(above))
                ))
            }
        }

        // 2. Lightest day: lowest non-zero average, not the peak
        if let peak, let light = weekdayAverages
            .filter({ $0.average > 0 && $0.weekday != peak.weekday && $0.average < peak.average })
            .min(by: { $0.average < $1.average }) {
            insights.append(WeeklyInsight(
                kind: .lightestDay,
                icon: "arrow-trending-down",
                headlineKey: "dash_week_light_format",
                headlineArgs: [weekdayName(light.weekday)],
                caption: String(format: "dash_week_light_caption_format".localized, money(light.average))
            ))
        }

        // 3. Weekends (Sat + Sun) against weekdays (Mon–Fri), per day
        let weekend = (average(7) + average(1)) / 2
        let workdays = (2...6).map(average).reduce(0, +) / 5
        if weekend > 0, workdays > 0 {
            let ratio = weekend / workdays
            if ratio < 0.9 || ratio > 1.1 {
                let more = ratio > 1
                let times = (more ? ratio : workdays / weekend).formatted(.number.precision(.fractionLength(1)))
                insights.append(WeeklyInsight(
                    kind: .weekendRatio,
                    icon: "calendar",
                    headlineKey: more ? "dash_week_weekend_more_format" : "dash_week_weekend_less_format",
                    headlineArgs: [String(format: "dash_week_times_format".localized, times)],
                    caption: String(format: "dash_week_weekend_caption_format".localized, money(weekend), money(workdays))
                ))
            }
        }

        // 4. The category that takes most of the peak day
        var peakPair: (category: UUID, weekday: Int)?
        if let peak, let totals = weekdayCategoryTotals[peak.weekday], let top = topCategory(totals) {
            let dayTotal = totals.values.reduce(0, +)
            let share = dayTotal > 0 ? top.amount / dayTotal : 0
            if share >= 0.25 {
                let info = category(top.id)
                peakPair = (top.id, peak.weekday)
                insights.append(WeeklyInsight(
                    kind: .peakDayCategory,
                    icon: info.icon,
                    headlineKey: "dash_week_day_category_format",
                    headlineArgs: [weekdayName(peak.weekday), info.name],
                    caption: String(format: "dash_week_day_category_caption_format".localized, percent(share))
                ))
            }
        }

        // 5. A category that leans on one weekday
        var best: (category: UUID, weekday: Int, share: Double)?
        for (categoryID, days) in categoryExpenseDays where days >= 4 {
            let byWeekday = (1...7).map { ($0, weekdayCategoryTotals[$0]?[categoryID] ?? 0) }
            let total = byWeekday.reduce(0) { $0 + $1.1 }
            guard total > 0, let top = byWeekday.max(by: { $0.1 < $1.1 }) else { continue }
            let share = top.1 / total
            if let current = best {
                let better = share > current.share
                    || (share == current.share && categoryID.uuidString < current.category.uuidString)
                if !better { continue }
            }
            best = (categoryID, top.0, share)
        }
        if let best, best.share >= 0.3,
           !(peakPair?.category == best.category && peakPair?.weekday == best.weekday) {
            let info = category(best.category)
            insights.append(WeeklyInsight(
                kind: .categoryWeekday,
                icon: info.icon,
                headlineKey: "dash_week_category_day_format",
                headlineArgs: [info.name, weekdayName(best.weekday)],
                caption: String(format: "dash_week_category_day_caption_format".localized, percent(best.share))
            ))
        }

        return insights
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
        // Same window, split by category, for the weekly highlights.
        var weekdayCategories = [Int: [UUID: Double]]()
        var categoryDays = [UUID: Set<Date>]()
        if let firstRecorded {
            for expense in past {
                let day = calendar.startOfDay(for: expense.date)
                guard day >= firstRecorded, day <= today else { continue }
                let weekday = calendar.component(.weekday, from: day)
                weekdayCategories[weekday, default: [:]][expense.categoryId, default: 0] += expense.amount
                categoryDays[expense.categoryId, default: []].insert(day)
            }
        }
        weekdayCategoryTotals = weekdayCategories
        categoryExpenseDays = categoryDays.mapValues(\.count)
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
            
            VStack(spacing: 12) {
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
