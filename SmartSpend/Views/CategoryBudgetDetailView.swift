import Charts
import SwiftUI

/// Days left in the month (today included) and how much of the month has passed.
struct BudgetMonthPace {
    let daysLeft: Int
    let elapsedFraction: Double

    init(date: Date = Date(), calendar: Calendar = .current) {
        let month = BudgetPeriodCalculator.monthInterval(containing: date, calendar: calendar)
        let totalDays = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        let today = calendar.component(.day, from: date)
        daysLeft = max(1, totalDays - today + 1)
        let elapsed = date.timeIntervalSince(month.start)
        elapsedFraction = month.duration > 0 ? min(max(elapsed / month.duration, 0), 1) : 0
    }

    /// What can still be spent per day, or nil when nothing is left.
    func dailyAllowance(remaining: Double) -> Double? {
        remaining > 0 ? remaining / Double(daysLeft) : nil
    }
}

/// Progress bar with a thin mark for today, so pace is visible at a glance.
struct BudgetPaceBar: View {
    let progress: Double
    let tint: Color
    let todayFraction: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(NightTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(progress > 0 ? height : 0, width * min(max(progress, 0), 1)))
                RoundedRectangle(cornerRadius: 1)
                    .fill(NightTheme.accent.opacity(0.75))
                    .frame(width: 2, height: height + 8)
                    .offset(x: min(max(width * todayFraction - 1, 0), width - 2))
            }
        }
        .frame(height: height + 8)
        .accessibilityHidden(true)
    }
}

/// Small colored pill that names a budget state.
struct BudgetStatusPill: View {
    let status: BudgetGoalStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// Labeled "Spent | Budget" pair under a hairline.
struct BudgetSpentLimitSplit: View {
    let spent: Double
    let limit: Double
    let limitLabel: String
    let currency: Currency

    var body: some View {
        VStack(spacing: 12) {
            Rectangle().fill(NightTheme.hair).frame(height: 1)
            HStack(spacing: 14) {
                column("budget_label_spent".localized, spent)
                Rectangle().fill(NightTheme.hair).frame(width: 1)
                column(limitLabel, limit)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(NightTheme.secondaryLabel)
            Text(CurrencyFormatter.format(amount, currency: currency))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Full page for one category budget: this month's state, the limit editor,
/// the last six months and this month's expenses. Pushed, never a sheet.
struct CategoryBudgetDetailView: View {
    let categoryID: UUID

    @ObservedObject private var dataManager = DataManager.shared

    @State private var isEditing = false
    @State private var draftAmount = ""
    @State private var showsAllExpenses = false
    @FocusState private var amountFocused: Bool

    private var category: UserCategory { dataManager.resolveCategory(id: categoryID) }
    private var currency: Currency { dataManager.user.currency }

    private var limit: Double {
        guard let budget = dataManager.categoryBudgets.first(where: { $0.categoryId == categoryID }),
              budget.isEnabled else { return 0 }
        return budget.amount
    }

    private var monthExpenses: [Expense] {
        let month = BudgetPeriodCalculator.monthInterval(containing: Date())
        return dataManager.expenses
            .filter { $0.categoryId == categoryID && month.contains($0.date) }
            .sorted { $0.date > $1.date }
    }

    /// Totals for this month and the five before it, oldest first.
    private var monthlyTotals: [(month: Date, total: Double)] {
        let calendar = Calendar.current
        let thisMonth = BudgetPeriodCalculator.monthInterval(containing: Date()).start
        let categoryExpenses = dataManager.expenses.filter { $0.categoryId == categoryID }
        return (0..<6).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { return nil }
            let interval = BudgetPeriodCalculator.monthInterval(containing: start)
            let total = categoryExpenses.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.amount }
            return (start, total)
        }
    }

    var body: some View {
        let expenses = monthExpenses
        let spent = expenses.reduce(0) { $0 + $1.amount }
        let totals = monthlyTotals

        ZStack {
            NightGround()

            ScrollView {
                VStack(spacing: 28) {
                    heroCard(spent: spent)
                    limitCard(totals: totals)
                    historySection(totals: totals)
                    expensesSection(expenses)
                }
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(NightTheme.accent)
        .onDisappear { dataManager.saveBudgets() }
    }

    // MARK: - Hero

    private func heroCard(spent: Double) -> some View {
        let pace = BudgetMonthPace()
        let status = BudgetGoalStatus.evaluate(spent: spent, limit: limit, isEnabled: limit > 0)
        let remaining = limit - spent
        let tint = status == .onTrack ? category.color : status.color

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HeroIcon(systemName: category.iconSystemName, size: 21)
                    .foregroundStyle(category.color)
                    .frame(width: 40, height: 40)
                    .background(category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text("budget_this_month".localized)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if status != .noLimit {
                    BudgetStatusPill(status: status)
                }
            }

            if limit > 0 {
                Text((remaining < 0 ? "budget_row_over" : "budget_row_left")
                    .localized(with: CurrencyFormatter.format(abs(remaining), currency: currency)))
                    .font(.title.weight(.bold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(remaining < 0 ? Color(.systemRed) : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                BudgetPaceBar(progress: spent / limit, tint: tint, todayFraction: pace.elapsedFraction)

                BudgetSpentLimitSplit(spent: spent, limit: limit,
                                      limitLabel: "budget_label_limit".localized, currency: currency)

                if let daily = pace.dailyAllowance(remaining: remaining) {
                    Text("budget_daily_allowance_days".localized(with:
                        CurrencyFormatter.format(daily, currency: currency), pace.daysLeft))
                        .font(.footnote)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(CurrencyFormatter.format(spent, currency: currency))
                    .font(.title.weight(.bold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("budget_detail_no_limit".localized)
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .budgetDetailCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Limit

    private func limitCard(totals: [(month: Date, total: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("budget_monthly_limit".localized)
                        .font(.footnote)
                        .foregroundStyle(NightTheme.secondaryLabel)
                    Text(limit > 0 ? CurrencyFormatter.format(limit, currency: currency) : "budget_no_limit_value".localized)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 8)
                if !isEditing {
                    Button(limit > 0 ? "edit".localized : "budget_set_limit".localized, action: startEditing)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                        .background(NightTheme.iconFill, in: Capsule())
                        .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("budgetDetail.edit")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isEditing {
                editor(totals: totals)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .budgetDetailCard()
    }

    private func editor(totals: [(month: Date, total: Double)]) -> some View {
        let past = totals.dropLast().map(\.total)
        let lastThree = past.suffix(3).filter { $0 > 0 }
        let average = lastThree.isEmpty ? 0 : (lastThree.reduce(0, +) / Double(lastThree.count)).rounded()
        let lastMonth = past.last ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("0", text: $draftAmount)
                    .keyboardType(.decimalPad)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .focused($amountFocused)
                    .accessibilityLabel("budget_monthly_limit".localized)
                    .onChange(of: draftAmount) { old, _ in
                        let formatted = AmountInputFormatter.formatEditingText(draftAmount, previous: old)
                        if formatted != draftAmount { draftAmount = formatted }
                    }
                Text(currency.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(NightTheme.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(NightTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NightTheme.accent.opacity(0.6), lineWidth: 1))

            if average > 0 || lastMonth > 0 {
                HStack(spacing: 8) {
                    if average > 0 {
                        suggestionChip("budget_suggest_average".localized(with: CurrencyFormatter.format(average, currency: currency)), average)
                    }
                    if lastMonth > 0 {
                        suggestionChip("budget_suggest_last_month".localized(with: CurrencyFormatter.format(lastMonth, currency: currency)), lastMonth)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("cancel".localized) { withAnimation(.easeInOut(duration: 0.2)) { isEditing = false; amountFocused = false } }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(NightTheme.iconFill, in: Capsule())
                    .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
                Button("save".localized, action: saveLimit)
                    .fontWeight(.semibold)
                    .foregroundStyle(NightTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(NightTheme.fg, in: Capsule())
                    .opacity((AmountInputFormatter.parse(draftAmount) ?? 0) > 0 ? 1 : 0.4)
                    .disabled((AmountInputFormatter.parse(draftAmount) ?? 0) <= 0)
                    .accessibilityIdentifier("budgetDetail.save")
            }
            .font(.body)
            .buttonStyle(.plain)

            if limit > 0 {
                Button("budget_remove_limit".localized, role: .destructive, action: removeLimit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.systemRed))
                    .frame(maxWidth: .infinity, minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .buttonStyle(.plain)
            }
        }
    }

    private func suggestionChip(_ title: String, _ amount: Double) -> some View {
        Button {
            draftAmount = AmountInputFormatter.formatValue(amount)
        } label: {
            Text(title)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(NightTheme.body)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(NightTheme.glassFill, in: Capsule())
                .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func startEditing() {
        draftAmount = limit > 0 ? AmountInputFormatter.formatValue(limit) : ""
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = true }
        amountFocused = true
    }

    private func saveLimit() {
        guard let amount = AmountInputFormatter.parse(draftAmount), amount > 0 else { return }
        setBudget(amount: amount, isEnabled: true)
        amountFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }

    private func removeLimit() {
        setBudget(amount: 0, isEnabled: false)
        amountFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }

    private func setBudget(amount: Double, isEnabled: Bool) {
        if let index = dataManager.categoryBudgets.firstIndex(where: { $0.categoryId == categoryID }) {
            dataManager.categoryBudgets[index].amount = amount
            dataManager.categoryBudgets[index].isEnabled = isEnabled
        } else {
            dataManager.categoryBudgets.append(CategoryBudget(categoryId: categoryID, amount: amount, isEnabled: isEnabled))
        }
        dataManager.saveBudgets()
    }

    // MARK: - History

    private func historySection(totals: [(month: Date, total: Double)]) -> some View {
        let nonZero = totals.map(\.total).filter { $0 > 0 }
        let average = nonZero.isEmpty ? 0 : nonZero.reduce(0, +) / Double(nonZero.count)

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeading("budget_last_six_months".localized,
                           detail: average > 0 ? "budget_average_short".localized(with: CurrencyFormatter.format(average, currency: currency)) : nil)

            Chart {
                ForEach(Array(totals.enumerated()), id: \.offset) { index, item in
                    let isCurrent = index == totals.count - 1
                    let isOver = limit > 0 && item.total > limit
                    BarMark(
                        x: .value("Month", item.month, unit: .month),
                        y: .value("Amount", item.total),
                        width: .ratio(0.6)
                    )
                    .foregroundStyle(isOver ? Color(.systemRed) : category.color.opacity(isCurrent ? 1 : 0.55))
                    .cornerRadius(5)
                }
                if limit > 0 {
                    RuleMark(y: .value("Limit", limit))
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("budget_limit_short".localized(with: CurrencyFormatter.format(limit, currency: currency)))
                                .font(.caption2)
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
            }
            .frame(height: 150)
            .padding(16)
            .budgetDetailCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("budget_last_six_months".localized)
            .accessibilityValue(totals.map {
                "\($0.month.formatted(.dateTime.month(.wide))): \(CurrencyFormatter.format($0.total, currency: currency))"
            }.joined(separator: ", "))
        }
    }

    // MARK: - Expenses

    private func expensesSection(_ expenses: [Expense]) -> some View {
        let shown = showsAllExpenses ? expenses : Array(expenses.prefix(5))

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeading("budget_this_month".localized,
                           detail: expenses.isEmpty ? nil : "budget_expense_count".localized(with: expenses.count))

            if expenses.isEmpty {
                Text("budget_row_nothing_spent".localized)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .budgetDetailCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, expense in
                        if index > 0 {
                            Rectangle().fill(NightTheme.hair).frame(height: 1).padding(.leading, 62)
                        }
                        ExpenseRowView(expense: expense, category: category, currency: currency)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    if expenses.count > 5 {
                        Rectangle().fill(NightTheme.hair).frame(height: 1)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showsAllExpenses.toggle() }
                        } label: {
                            Text(showsAllExpenses ? "budget_show_less".localized : "budget_show_all".localized(with: expenses.count))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: iOSDesignSystem.Size.minimumTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .budgetDetailCard()
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

private extension View {
    func budgetDetailCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .background(NightTheme.glassFill, in: shape)
            .overlay(shape.stroke(NightTheme.glassLine, lineWidth: 1))
    }
}
