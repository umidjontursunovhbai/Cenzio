import SwiftUI
import Charts

struct AnalyticsView: View {
    @ObservedObject private var dataManager = DataManager.shared

    @State private var selectedTimeframe: TimeFrame = .month
    @State private var periodOffset = 0
    @State private var showingAddExpense = false
    @State private var selectedTrendDate: Date?
    @State private var selectedMonthDate: Date?
    @State private var snapshot = AnalyticsSnapshot.empty

    enum TimeFrame: String, CaseIterable {
        case week
        case month
        case year

        var title: String {
            switch self {
            case .week: return "timeframe_week".localized
            case .month: return "timeframe_month".localized
            case .year: return "timeframe_year".localized
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 20) {
                    header
                    periodControls
                    summaryCard

                    if snapshot.currentExpenses.isEmpty {
                        emptyState
                    } else {
                        trendCard
                        categoryCard
                    }

                    if snapshot.months.contains(where: { $0.amount > 0 }) {
                        historyCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.white)
            .navigationBarHidden(true)
            .sheet(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .onAppear {
                refreshSnapshot(resetSelections: true)
            }
            .onChange(of: selectedTimeframe) { _, _ in
                periodOffset = 0
                refreshSnapshot(resetSelections: true)
            }
            .onChange(of: periodOffset) { _, _ in
                refreshSnapshot(resetSelections: true)
            }
            .onChange(of: dataManager.expenses) { _, _ in
                refreshSnapshot()
            }
        }
    }

    // MARK: - Header and period controls

    private var header: some View {
        AppScreenHeader("smartspend".localized) {
            ActionIconButton(icon: "plus", style: .primary) {
                showingAddExpense = true
            }
            .accessibilityLabel("add_expense".localized)
        }
        .padding(.horizontal, -16)
    }

    private var periodControls: some View {
        VStack(spacing: 10) {
            Picker("Time Frame", selection: $selectedTimeframe) {
                ForEach(TimeFrame.allCases, id: \.self) { timeframe in
                    Text(timeframe.title).tag(timeframe)
                }
            }
            .pickerStyle(.segmented)
            .frame(height: 44)
            .contentShape(Rectangle())

            HStack(spacing: 4) {
                periodButton(forward: false)

                Button {
                    guard periodOffset != 0 else { return }
                    periodOffset = 0
                } label: {
                    VStack(spacing: 2) {
                        Text(periodLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(.label))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        if periodOffset != 0 {
                            Text("tap_to_return_today".localized)
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                periodButton(forward: true)
            }
        }
        .padding(12)
        .liquidGlassCard(cornerRadius: 20)
    }

    private func periodButton(forward: Bool) -> some View {
        let enabled = !forward || periodOffset > 0

        return Button {
            periodOffset = max(periodOffset + (forward ? -1 : 1), 0)
        } label: {
            HeroIcon(forward ? "chevron-right" : "chevron-left", size: 18)
                .foregroundStyle(enabled ? Color.accentColor : Color(.tertiaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(forward ? "Next period" : "Previous period")
    }

    // MARK: - Summary

    private var summaryCard: some View {
        AnalyticsCard(title: periodLabel) {
            VStack(alignment: .leading, spacing: 18) {
                Text(CurrencyFormatter.format(snapshot.total, currency: dataManager.user.currency))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.46)
                    .accessibilityLabel(
                        "Spent \(CurrencyFormatter.formatFull(snapshot.total, currency: dataManager.user.currency))"
                    )

                comparisonLine

                HStack(spacing: 0) {
                    metric(
                        value: CurrencyFormatter.format(
                            snapshot.dailyAverage,
                            currency: dataManager.user.currency
                        ),
                        label: "daily_avg".localized
                    )

                    Divider().frame(height: 36)

                    metric(
                        value: "\(snapshot.currentExpenses.count)",
                        label: "Transactions"
                    )

                    Divider().frame(height: 36)

                    metric(value: budgetMetric.value, label: budgetMetric.label)
                }
                .padding(.vertical, 12)
                .background(
                    Color(.secondarySystemBackground).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }
    }

    @ViewBuilder
    private var comparisonLine: some View {
        if snapshot.previousTotal > 0 {
            let change = (snapshot.total - snapshot.previousTotal) / snapshot.previousTotal * 100
            let increased = change >= 0
            let tint = increased ? Color(.systemRed) : Color(.systemGreen)

            HStack(spacing: 9) {
                HeroIcon(increased ? "arrow-trending-up" : "arrow-trending-down", size: 16)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(formatPercentage(abs(change))) \(increased ? "more" : "less")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("Compared with the previous period")
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
        } else {
            Text("No spending in the previous period")
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabel))
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var budgetMetric: (value: String, label: String) {
        if selectedTimeframe == .month, periodOffset == 0, snapshot.salary > 0 {
            let spendable = dataManager.getSpendableTodaySnapshot()
            return (
                CurrencyFormatter.format(spendable.spendableToday, currency: dataManager.user.currency),
                "spendable_today".localized
            )
        }

        guard selectedTimeframe == .month, snapshot.salary > 0 else {
            return ("\(snapshot.categories.count)", "categories".localized)
        }

        let remaining = snapshot.salary - snapshot.total
        return (
            CurrencyFormatter.format(abs(remaining), currency: dataManager.user.currency),
            remaining >= 0 ? "Remaining" : "Over income"
        )
    }

    // MARK: - Spending trend

    private var trendCard: some View {
        let selection = selectedTrendPoint

        return AnalyticsCard(
            title: "spending_trends".localized,
            detail: selectedTimeframe == .year ? "Monthly totals" : "Daily totals"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ChartReadoutSlot(
                    label: selection.map { selectedDateLabel($0.date) },
                    amount: selection.map {
                        CurrencyFormatter.formatFull(
                            $0.amount,
                            currency: dataManager.user.currency
                        )
                    },
                    tint: Color.accentColor
                )

                Chart {
                    ForEach(snapshot.trend) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Amount", point.amount)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.08))
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Amount", point.amount)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.linear)
                    }

                    if let selection {
                        RuleMark(x: .value("Selected date", selection.date))
                            .foregroundStyle(Color.accentColor.opacity(0.34))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        PointMark(
                            x: .value("Selected date", selection.date),
                            y: .value("Selected amount", selection.amount)
                        )
                        .symbolSize(92)
                        .foregroundStyle(Color.white)

                        PointMark(
                            x: .value("Selected date", selection.date),
                            y: .value("Selected amount", selection.amount)
                        )
                        .symbolSize(34)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXSelection(value: $selectedTrendDate)
                .chartYScale(domain: 0...chartMaximum(snapshot.trend.map(\.amount).max() ?? 0))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: selectedTimeframe == .week ? 7 : 6)) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color(.systemGray4))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisDateLabel(date))
                                    .font(.caption2)
                                    .foregroundStyle(Color(.secondaryLabel))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color(.systemGray5))
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(
                                    CurrencyFormatter.formatChartCompact(
                                        amount,
                                        currency: dataManager.user.currency
                                    )
                                )
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(Color(.secondaryLabel))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 220)
                .animation(nil, value: selectedTrendDate)
                .accessibilityLabel("Spending trend for \(periodLabel)")
            }
        }
    }

    // MARK: - Categories

    private var categoryCard: some View {
        AnalyticsCard(
            title: "category_breakdown".localized,
            detail: "\(snapshot.categories.count) categories"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.categories.prefix(6)).indices, id: \.self) { index in
                    categoryRow(Array(snapshot.categories.prefix(6))[index])

                    if index < min(snapshot.categories.count, 6) - 1 {
                        Divider().padding(.leading, 54)
                    }
                }

                if snapshot.categories.count > 6 {
                    Text("+\(snapshot.categories.count - 6) more categories")
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 10)
                }
            }
        }
    }

    private func categoryRow(_ category: CategoryAmount) -> some View {
        let share = snapshot.total > 0 ? category.amount / snapshot.total : 0

        return HStack(spacing: 12) {
            HeroIcon(systemName: category.category.iconSystemName, size: 20)
                .foregroundStyle(category.category.color)
                .frame(width: 42, height: 42)
                .background(
                    category.category.color.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(category.category.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(CurrencyFormatter.format(category.amount, currency: dataManager.user.currency))
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }

                GeometryReader { geometry in
                    Capsule()
                        .fill(Color(.systemGray5))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(category.category.color)
                                .frame(
                                    width: max(
                                        4,
                                        geometry.size.width * CGFloat(min(max(share, 0), 1))
                                    )
                                )
                        }
                }
                .frame(height: 5)

                Text("\(formatPercentage(share * 100)) of this period")
                    .font(.caption2)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Twelve-month history

    private var historyCard: some View {
        let selection = selectedMonth

        return AnalyticsCard(
            title: "monthly_history".localized,
            detail: "Touch or drag"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ChartReadoutSlot(
                    label: selection?.date.formatted(.dateTime.month(.wide).year()),
                    amount: selection.map {
                        CurrencyFormatter.formatFull(
                            $0.amount,
                            currency: dataManager.user.currency
                        )
                    },
                    tint: Color(.systemTeal)
                )

                Chart {
                    ForEach(snapshot.months) { month in
                        BarMark(
                            x: .value("Month", month.date),
                            y: .value("Amount", month.amount)
                        )
                        .foregroundStyle(historyBarColor(month))
                        .cornerRadius(4)
                    }

                    if let selection {
                        RuleMark(x: .value("Selected month", selection.date))
                            .foregroundStyle(Color(.systemTeal).opacity(0.34))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartXSelection(value: $selectedMonthDate)
                .chartYScale(domain: 0...chartMaximum(snapshot.months.map(\.amount).max() ?? 0))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month, count: 2)) { value in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(.dateTime.month(.abbreviated)))
                                    .font(.caption2)
                                    .foregroundStyle(Color(.secondaryLabel))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color(.systemGray5))
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(
                                    CurrencyFormatter.formatChartCompact(
                                        amount,
                                        currency: dataManager.user.currency
                                    )
                                )
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(Color(.secondaryLabel))
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 196)
                .animation(nil, value: selectedMonthDate)
                .accessibilityLabel("Spending over the last twelve months")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            HeroIcon("chart-bar", size: 27)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.08), in: Circle())

            Text("No spending in this period")
                .font(.headline)
                .foregroundStyle(Color(.label))

            Text("Choose another period or add an expense to see trends and categories.")
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .analyticsCardSurface()
    }

    // MARK: - Snapshot calculation

    private func refreshSnapshot(resetSelections: Bool = false) {
        let next = makeSnapshot()
        snapshot = next

        if resetSelections || nearestTrendPoint(to: selectedTrendDate, in: next.trend) == nil {
            selectedTrendDate = next.trend.last(where: { $0.amount > 0 })?.date
                ?? next.trend.last?.date
        }

        if resetSelections || nearestMonth(to: selectedMonthDate, in: next.months) == nil {
            selectedMonthDate = next.months.last(where: { $0.amount > 0 })?.date
                ?? next.months.last?.date
        }
    }

    private func makeSnapshot() -> AnalyticsSnapshot {
        guard let interval = periodInterval(timeframe: selectedTimeframe, offset: periodOffset),
              let previous = previousInterval(for: interval) else {
            return .empty
        }

        let currentExpenses = dataManager.expenses.filter { interval.contains($0.date) }
        let comparisonExpenses = dataManager.expenses.filter { previous.contains($0.date) }
        let total = currentExpenses.reduce(0) { $0 + $1.amount }
        let previousTotal = comparisonExpenses.reduce(0) { $0 + $1.amount }

        return AnalyticsSnapshot(
            currentExpenses: currentExpenses,
            total: total,
            previousTotal: previousTotal,
            dailyAverage: dailyAverage(total: total, interval: interval),
            salary: selectedSalary,
            categories: categoryTotals(currentExpenses),
            trend: trendPoints(currentExpenses, interval: interval),
            months: lastTwelveMonths()
        )
    }

    private func periodInterval(timeframe: TimeFrame, offset: Int) -> DateInterval? {
        let calendar = Calendar.current

        switch timeframe {
        case .week:
            guard let date = calendar.date(byAdding: .weekOfYear, value: -offset, to: Date()) else {
                return nil
            }
            return calendar.dateInterval(of: .weekOfYear, for: date)

        case .month:
            guard let date = calendar.date(byAdding: .month, value: -offset, to: Date()) else {
                return nil
            }
            return calendar.dateInterval(of: .month, for: date)

        case .year:
            guard let date = calendar.date(byAdding: .year, value: -offset, to: Date()) else {
                return nil
            }
            return calendar.dateInterval(of: .year, for: date)
        }
    }

    private func previousInterval(for current: DateInterval) -> DateInterval? {
        guard let fullPrevious = periodInterval(
            timeframe: selectedTimeframe,
            offset: periodOffset + 1
        ) else {
            return nil
        }

        guard periodOffset == 0 else { return fullPrevious }

        let elapsed = max(0, min(Date(), current.end).timeIntervalSince(current.start))
        return DateInterval(
            start: fullPrevious.start,
            end: min(fullPrevious.end, fullPrevious.start.addingTimeInterval(elapsed))
        )
    }

    private var periodLabel: String {
        guard let interval = periodInterval(
            timeframe: selectedTimeframe,
            offset: periodOffset
        ) else {
            return "-"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current

        switch selectedTimeframe {
        case .week:
            formatter.dateFormat = "MMM d"
            let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end)
                ?? interval.end
            return "\(formatter.string(from: interval.start)) - \(formatter.string(from: end))"

        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: interval.start)

        case .year:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: interval.start)
        }
    }

    private func analysisEnd(_ interval: DateInterval) -> Date {
        let lastMoment = interval.end.addingTimeInterval(-1)
        return periodOffset == 0 ? min(Date(), lastMoment) : lastMoment
    }

    private func dailyAverage(total: Double, interval: DateInterval) -> Double {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: analysisEnd(interval))
        let dayCount = max(
            (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1,
            1
        )
        return total / Double(dayCount)
    }

    private var selectedSalary: Double {
        guard selectedTimeframe == .month,
              let date = periodInterval(timeframe: .month, offset: periodOffset)?.start else {
            return 0
        }

        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return 0 }
        return dataManager.getSalaryForMonth(month: month, year: year)
    }

    private func categoryTotals(_ expenses: [Expense]) -> [CategoryAmount] {
        let grouped = Dictionary(grouping: expenses, by: \.categoryId)

        return grouped.map { categoryID, values in
            CategoryAmount(
                category: dataManager.resolveCategory(id: categoryID),
                amount: values.reduce(0) { $0 + $1.amount }
            )
        }
        .sorted { $0.amount > $1.amount }
    }

    private func trendPoints(_ expenses: [Expense], interval: DateInterval) -> [SpendingPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: expenses) { expense in
            trendBucket(expense.date)
        }
        .mapValues { values in values.reduce(0) { $0 + $1.amount } }

        var points: [SpendingPoint] = []
        var cursor = trendBucket(interval.start)
        let end = analysisEnd(interval)
        let component: Calendar.Component = selectedTimeframe == .year ? .month : .day

        while cursor <= end {
            points.append(SpendingPoint(date: cursor, amount: grouped[cursor] ?? 0))
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor),
                  next > cursor else {
                break
            }
            cursor = next
        }

        return points
    }

    private func trendBucket(_ date: Date) -> Date {
        let calendar = Calendar.current
        if selectedTimeframe == .year {
            return calendar.date(
                from: calendar.dateComponents([.year, .month], from: date)
            ) ?? calendar.startOfDay(for: date)
        }
        return calendar.startOfDay(for: date)
    }

    private func lastTwelveMonths() -> [MonthAmount] {
        let calendar = Calendar.current
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else {
            return []
        }

        var totals: [Date: Double] = [:]
        for expense in dataManager.expenses {
            guard let month = calendar.date(
                from: calendar.dateComponents([.year, .month], from: expense.date)
            ) else {
                continue
            }
            totals[month, default: 0] += expense.amount
        }

        return (0..<12).reversed().compactMap { monthsBack in
            guard let date = calendar.date(
                byAdding: .month,
                value: -monthsBack,
                to: currentMonth
            ) else {
                return nil
            }
            return MonthAmount(date: date, amount: totals[date] ?? 0)
        }
    }

    // MARK: - Selection and formatting

    private var selectedTrendPoint: SpendingPoint? {
        nearestTrendPoint(to: selectedTrendDate, in: snapshot.trend)
    }

    private var selectedMonth: MonthAmount? {
        nearestMonth(to: selectedMonthDate, in: snapshot.months)
    }

    private func nearestTrendPoint(
        to date: Date?,
        in points: [SpendingPoint]
    ) -> SpendingPoint? {
        guard let date else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func nearestMonth(
        to date: Date?,
        in months: [MonthAmount]
    ) -> MonthAmount? {
        guard let date else { return nil }
        return months.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    private func selectedDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = selectedTimeframe == .year
            ? "MMMM yyyy"
            : "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }

    private func axisDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current

        switch selectedTimeframe {
        case .week: formatter.dateFormat = "EEE"
        case .month: formatter.dateFormat = "d"
        case .year: formatter.dateFormat = "MMM"
        }
        return formatter.string(from: date)
    }

    private func historyBarColor(_ month: MonthAmount) -> Color {
        selectedMonth?.date == month.date
            ? Color(.systemTeal)
            : Color(.systemTeal).opacity(0.25)
    }

    private func chartMaximum(_ value: Double) -> Double {
        guard value > 0 else { return 1 }

        let exponent = floor(log10(value))
        let magnitude = pow(10, exponent)
        let normalized = value / magnitude
        let rounded: Double

        switch normalized {
        case ...1: rounded = 1
        case ...2: rounded = 2
        case ...5: rounded = 5
        default: rounded = 10
        }

        return rounded * magnitude
    }

    private func formatPercentage(_ value: Double) -> String {
        let safe = value.isFinite ? value : 0
        return safe >= 100 || safe.rounded() == safe
            ? String(format: "%.0f%%", safe)
            : String(format: "%.1f%%", safe)
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsCardSurface()
    }
}

private struct ChartReadout: View {
    let label: String
    let amount: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(tint)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(2)

                Text(amount)
                    .font(.subheadline.weight(.bold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            tint.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChartReadoutSlot: View {
    let label: String?
    let amount: String?
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            if let label, let amount {
                ChartReadout(label: label, amount: amount, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 58)
        .clipped()
        .allowsHitTesting(false)
    }
}

private extension View {
    func analyticsCardSurface() -> some View {
        background(
            Color.white,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.055), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.035), radius: 12, x: 0, y: 6)
    }
}

private extension AnalyticsView {
    struct AnalyticsSnapshot {
        let currentExpenses: [Expense]
        let total: Double
        let previousTotal: Double
        let dailyAverage: Double
        let salary: Double
        let categories: [CategoryAmount]
        let trend: [SpendingPoint]
        let months: [MonthAmount]

        static let empty = AnalyticsSnapshot(
            currentExpenses: [],
            total: 0,
            previousTotal: 0,
            dailyAverage: 0,
            salary: 0,
            categories: [],
            trend: [],
            months: []
        )
    }

    struct CategoryAmount: Identifiable {
        var id: UUID { category.id }
        let category: UserCategory
        let amount: Double
    }

    struct SpendingPoint: Identifiable {
        var id: Date { date }
        let date: Date
        let amount: Double
    }

    struct MonthAmount: Identifiable {
        var id: Date { date }
        let date: Date
        let amount: Double
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

#Preview {
    AnalyticsView()
}
