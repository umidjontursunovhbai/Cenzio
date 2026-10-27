import SwiftUI

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    private let focusCategoryID: UUID?

    @State private var showingAddGoal = false
    @State private var showingResetConfirmation = false
    @State private var showingInfo = false
    /// Drives the staggered reveal of the inline info sections after the card is inserted.
    @State private var infoContentVisible = false

    init(focusCategoryID: UUID? = nil) {
        self.focusCategoryID = focusCategoryID
    }

    private var canSuggestBudgets: Bool {
        dataManager.expenses.count >= 10
    }

    private var activeBudgets: [CategoryBudget] {
        dataManager.categoryBudgets.filter { $0.isEnabled && $0.amount > 0 }
    }

    private var currentMonth: DateInterval {
        BudgetPeriodCalculator.monthInterval(containing: Date())
    }

    private var currentMonthSpendingByCategory: [UUID: Double] {
        BudgetPeriodCalculator.totalsByCategory(for: dataManager.expenses, in: currentMonth)
    }

    private var totalBudget: Double {
        activeBudgets.reduce(0) { $0 + $1.amount }
    }

    /// Days left in the current month, including today.
    private var daysLeftInMonth: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return max(calendar.dateComponents([.day], from: today, to: currentMonth.end).day ?? 1, 1)
    }

    private func currentMonthSpent(using spendingByCategory: [UUID: Double]) -> Double {
        let activeCategoryIDs = Set(activeBudgets.map(\.categoryId))

        return spendingByCategory.reduce(into: 0) { total, entry in
            guard activeCategoryIDs.contains(entry.key) else { return }
            total += entry.value
        }
    }

    private func statusCounts(using spendingByCategory: [UUID: Double]) -> [BudgetGoalStatus: Int] {
        activeBudgets.reduce(into: [:]) { counts, budget in
            let status = BudgetGoalStatus.evaluate(
                spent: spendingByCategory[budget.categoryId, default: 0],
                limit: budget.amount,
                isEnabled: true
            )
            counts[status, default: 0] += 1
        }
    }

    /// A real category to use as the worked example in the info popup.
    private var infoExample: (name: String, limit: Double)? {
        guard let budget = activeBudgets.first else { return nil }
        return (dataManager.resolveCategory(id: budget.categoryId).name, budget.amount)
    }

    var body: some View {
        let spendingByCategory = currentMonthSpendingByCategory
        let spentThisMonth = currentMonthSpent(using: spendingByCategory)

        return NavigationStack {
            ZStack {
                iOSDesignSystem.appBackground.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 28) {
                            // Fixed scroll target above the animated info, so opening it never overshoots under the bar.
                            Color.clear.frame(height: 0).id(Self.pageTopID)
                            if showingInfo {
                                inlineInfoCard
                                    .id(Self.infoCardID)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                                    ))
                            }
                            monthlyOverview(
                                currentMonthSpent: spentThisMonth,
                                counts: statusCounts(using: spendingByCategory)
                            )
                            categoryBudgetsSection(spendingByCategory: spendingByCategory)
                            spendingGoalsSection
                            budgetToolsSection
                        }
                        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                        .padding(.top, 8)
                        .padding(.bottom, 36)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToFocusedCategory(using: proxy)
                    }
                    .onChange(of: showingInfo) { _, isShowing in
                        guard isShowing else { return }
                        withAnimation(.snappy(duration: 0.35)) {
                            proxy.scrollTo(Self.pageTopID, anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle("budget_goals".localized)
            .navigationBarTitleDisplayMode(.inline)
            // Default bar: on iOS 26 content scrolls under a soft, see-through top edge.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: presentInfo) {
                        HeroIcon(showingInfo ? "x-mark" : "information-circle", size: 23)
                            .foregroundStyle(Color.accentColor)
                            .frame(minWidth: iOSDesignSystem.Size.minimumTapTarget,
                                   minHeight: iOSDesignSystem.Size.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showingInfo ? "close".localized : "budget_info_title".localized)
                    .accessibilityIdentifier("budgetGoals.infoButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        dataManager.saveBudgets()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: iOSDesignSystem.Size.minimumTapTarget,
                           minHeight: iOSDesignSystem.Size.minimumTapTarget)
                }
            }
            .sheet(isPresented: $showingAddGoal) {
                AddSpendingGoalView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(iOSDesignSystem.appBackground)
            }
            .alert("budget_reset_title".localized, isPresented: $showingResetConfirmation) {
                Button("cancel".localized, role: .cancel) { }
                Button("reset".localized, role: .destructive, action: resetAllBudgets)
            } message: {
                Text("budget_reset_message".localized)
            }
            .onAppear {
                dataManager.updateSpendingGoalProgress()
            }
            .onDisappear {
                dataManager.saveBudgets()
            }
        }
    }

    private static let pageTopID = "page.top"
    private static let infoCardID = "budgetGoals.inlineInfo"

    /// Opens or closes the info card inside the page instead of a separate popup.
    private func presentInfo() {
        if showingInfo {
            infoContentVisible = false
            withAnimation(.snappy(duration: 0.3)) { showingInfo = false }
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showingInfo = true }
        }
    }

    private var inlineInfoCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                HeroIcon("chart-pie", size: 18)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text("budget_info_title".localized)
                    .font(.headline)
                Spacer()
                Button(action: presentInfo) {
                    HeroIcon("x-mark", size: 16)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.systemGray6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("close".localized)
            }

            BudgetGoalsInfoContent(
                example: infoExample,
                currency: dataManager.user.currency
            )
            .environment(\.infoPopupIsVisible, infoContentVisible)
        }
        // No card behind it: the glass background showed as a box while the sections animated in.
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .onAppear { infoContentVisible = true }
    }

    // MARK: - Overview

    private func monthlyOverview(currentMonthSpent: Double, counts: [BudgetGoalStatus: Int]) -> some View {
        let currency = dataManager.user.currency
        let hasBudgets = totalBudget > 0
        let status = BudgetGoalStatus.evaluate(spent: currentMonthSpent, limit: totalBudget, isEnabled: hasBudgets)
        let progress = hasBudgets ? currentMonthSpent / totalBudget : 0
        let remaining = totalBudget - currentMonthSpent
        let tint = status == .onTrack ? Color.accentColor : status.color

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Date().formatted(.dateTime.month(.wide).year()).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(hasBudgets
                         ? CurrencyFormatter.format(totalBudget, currency: currency)
                         : "budget_no_limits_title".localized)
                        .font(.title2.weight(.bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(hasBudgets
                         ? "budget_total_limits_caption".localized(with: activeBudgets.count)
                         : "budget_no_limits_message".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if hasBudgets {
                    ZStack {
                        Circle()
                            .stroke(Color(.systemGray5), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: min(progress, 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))

                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption.weight(.bold))
                            .fontDesign(.rounded)
                            .minimumScaleFactor(0.7)
                            .padding(6)
                    }
                    .frame(width: 58, height: 58)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("budget_used".localized)
                    .accessibilityValue("\(Int((progress * 100).rounded()))%")
                }
            }

            if hasBudgets {
                BudgetProgressBar(progress: progress, tint: tint)

                HStack(spacing: 12) {
                    overviewMetric(
                        label: "budget_spent_label".localized,
                        value: CurrencyFormatter.format(currentMonthSpent, currency: currency),
                        color: .primary
                    )

                    Divider().frame(height: 34)

                    overviewMetric(
                        label: remaining < 0 ? "budget_over_label".localized : "budget_left_label".localized,
                        value: CurrencyFormatter.format(abs(remaining), currency: currency),
                        color: remaining < 0 ? Color(.systemRed) : Color(.systemGreen)
                    )

                    Divider().frame(height: 34)

                    overviewMetric(
                        label: "budget_days_left_label".localized,
                        value: "\(daysLeftInMonth)",
                        color: .primary
                    )
                }

                statusSummary(counts)

                if remaining > 0 {
                    HStack(alignment: .top, spacing: 8) {
                        HeroIcon("calendar-days", size: 16)
                            .foregroundStyle(.secondary)
                        Text("budget_daily_pace".localized(with:
                            CurrencyFormatter.format(remaining / Double(daysLeftInMonth), currency: currency),
                            daysLeftInMonth
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if canSuggestBudgets {
                Button(action: suggestBudgets) {
                    HStack(spacing: 8) {
                        HeroIcon("sparkles", size: 17)
                        Text("budget_suggest_title".localized)
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button(action: presentInfo) {
                HStack(spacing: 6) {
                    HeroIcon("information-circle", size: 16)
                    Text("budget_how_calculated".localized)
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -10)
            .accessibilityIdentifier("budgetGoals.howCalculated")
        }
        .padding(20)
        .liquidGlassCard(cornerRadius: 22)
    }

    private func statusSummary(_ counts: [BudgetGoalStatus: Int]) -> some View {
        HStack(spacing: 8) {
            ForEach([BudgetGoalStatus.onTrack, .nearLimit, .overBudget], id: \.self) { status in
                let count = counts[status, default: 0]
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                    Text("\(count) \(status.title.lowercased())")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(status.color.opacity(count > 0 ? 0.12 : 0.05), in: Capsule())
                .opacity(count > 0 ? 1 : 0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func overviewMetric(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Category budgets

    private func categoryBudgetsSection(spendingByCategory: [UUID: Double]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeading(
                    title: "budget_category_section".localized,
                    detail: dataManager.userCategories.isEmpty
                        ? nil
                        : "budget_active_count".localized(with: activeBudgets.count, dataManager.userCategories.count)
                )
                Text("budget_category_section_caption".localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if dataManager.userCategories.isEmpty {
                BudgetEmptyState(
                    icon: "tag",
                    title: "budget_no_categories_title".localized,
                    message: "budget_no_categories_message".localized
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(dataManager.userCategories) { category in
                        CategoryBudgetSettingRow(
                            category: category,
                            budget: dataManager.categoryBudgets.first { $0.categoryId == category.id },
                            currentMonthSpent: spendingByCategory[category.id, default: 0],
                            currency: dataManager.user.currency,
                            onChange: { amount, isEnabled in
                                updateBudget(for: category.id, amount: amount, isEnabled: isEnabled)
                            }
                        )
                            .id(category.id)
                            .overlay {
                                if focusCategoryID == category.id {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(category.color.opacity(0.8), lineWidth: 2)
                                }
                            }
                    }
                }
            }
        }
    }

    private func scrollToFocusedCategory(using proxy: ScrollViewProxy) {
        guard let focusCategoryID else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(focusCategoryID, anchor: .center)
            }
        }
    }

    private func updateBudget(for categoryID: UUID, amount: Double, isEnabled: Bool) {
        if let index = dataManager.categoryBudgets.firstIndex(where: { $0.categoryId == categoryID }) {
            guard dataManager.categoryBudgets[index].amount != amount
                    || dataManager.categoryBudgets[index].isEnabled != isEnabled else { return }
            dataManager.categoryBudgets[index].amount = amount
            dataManager.categoryBudgets[index].isEnabled = isEnabled
        } else {
            dataManager.categoryBudgets.append(
                CategoryBudget(categoryId: categoryID, amount: amount, isEnabled: isEnabled)
            )
        }
    }

    // MARK: - Spending goals

    private var spendingGoalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeading(
                        title: "budget_goals_section".localized,
                        detail: dataManager.spendingGoals.isEmpty ? nil : "\(dataManager.spendingGoals.count)"
                    )
                    Text("budget_goals_section_caption".localized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showingAddGoal = true
                } label: {
                    HeroIcon("plus", size: 20)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: iOSDesignSystem.Size.minimumTapTarget,
                               height: iOSDesignSystem.Size.minimumTapTarget)
                        .liquidGlassSurface(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("budget_add_goal".localized)
            }

            if dataManager.spendingGoals.isEmpty {
                BudgetEmptyState(
                    icon: "flag",
                    title: "budget_no_goals_title".localized,
                    message: "budget_no_goals_message".localized,
                    actionTitle: "budget_add_goal".localized,
                    action: { showingAddGoal = true }
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(dataManager.spendingGoals) { goal in
                        SpendingGoalRow(goal: goal) {
                            dataManager.spendingGoals.removeAll { $0.id == goal.id }
                            dataManager.saveSpendingGoals()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var budgetToolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(title: "budget_tools_section".localized)

            VStack(spacing: 0) {
                Button(action: suggestBudgets) {
                    budgetToolRow(
                        icon: "sparkles",
                        title: "budget_suggest_title".localized,
                        detail: canSuggestBudgets
                            ? "budget_suggest_detail".localized
                            : "budget_suggest_locked".localized,
                        tint: Color(.systemIndigo)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSuggestBudgets)
                .opacity(canSuggestBudgets ? 1 : 0.48)

                Divider()
                    .padding(.leading, 52)

                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    budgetToolRow(
                        icon: "arrow-path",
                        title: "budget_reset_row_title".localized,
                        detail: "budget_reset_row_detail".localized,
                        tint: Color(.systemRed)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .liquidGlassCard(cornerRadius: 18)
        }
    }

    private func sectionHeading(title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private func budgetToolRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            HeroIcon(icon, size: 21)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint == Color(.systemRed) ? tint : Color.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HeroIcon("chevron-right", size: 16)
                .foregroundStyle(Color(.tertiaryLabel))
        }
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }

    private func resetAllBudgets() {
        for index in dataManager.categoryBudgets.indices {
            dataManager.categoryBudgets[index].amount = 0
            dataManager.categoryBudgets[index].isEnabled = false
        }
        dataManager.saveBudgets()
        dataManager.objectWillChange.send()
    }

    private func suggestBudgets() {
        let calendar = Calendar.current
        let now = Date()

        guard let twoMonthsAgo = calendar.date(byAdding: .month, value: -2, to: now) else { return }

        let recentExpenses = dataManager.expenses.filter { $0.date >= twoMonthsAgo }
        let groupedByMonth = Dictionary(grouping: recentExpenses) { expense in
            calendar.dateComponents([.year, .month], from: expense.date)
        }
        let monthCount = max(1, Double(groupedByMonth.count))

        for category in dataManager.userCategories {
            let categoryExpenses = recentExpenses.filter { $0.categoryId == category.id }
            guard !categoryExpenses.isEmpty else { continue }

            let total = categoryExpenses.reduce(0) { $0 + $1.amount }
            let suggested = ((total / monthCount) * 1.05).rounded()

            if let index = dataManager.categoryBudgets.firstIndex(where: { $0.categoryId == category.id }) {
                dataManager.categoryBudgets[index].amount = suggested
                dataManager.categoryBudgets[index].isEnabled = true
            } else {
                dataManager.categoryBudgets.append(
                    CategoryBudget(categoryId: category.id, amount: suggested, isEnabled: true)
                )
            }
        }

        dataManager.saveBudgets()
        dataManager.objectWillChange.send()
    }
}

struct CategoryBudgetSettingRow: View {
    let category: UserCategory
    let budget: CategoryBudget?
    let currentMonthSpent: Double
    let currency: Currency
    let onChange: (Double, Bool) -> Void

    @State private var budgetAmount = ""
    @State private var isEnabled = false

    init(
        category: UserCategory,
        budget: CategoryBudget?,
        currentMonthSpent: Double,
        currency: Currency,
        onChange: @escaping (Double, Bool) -> Void
    ) {
        self.category = category
        self.budget = budget
        self.currentMonthSpent = currentMonthSpent
        self.currency = currency
        self.onChange = onChange
        _budgetAmount = State(
            initialValue: budget.map { $0.amount > 0 ? AmountInputFormatter.formatValue($0.amount) : "" } ?? ""
        )
        _isEnabled = State(initialValue: budget?.isEnabled ?? false)
    }

    private var enteredAmount: Double {
        AmountInputFormatter.parse(budgetAmount) ?? 0
    }

    private var status: BudgetGoalStatus {
        BudgetGoalStatus.evaluate(spent: currentMonthSpent, limit: enteredAmount, isEnabled: isEnabled)
    }

    private var progress: Double {
        guard isEnabled, enteredAmount > 0 else { return 0 }
        return currentMonthSpent / enteredAmount
    }

    private var barTint: Color {
        status == .onTrack ? category.color : status.color
    }

    private var subtitle: String {
        if !isEnabled {
            return "budget_row_no_limit".localized(with: CurrencyFormatter.format(currentMonthSpent, currency: currency))
        }
        if enteredAmount <= 0 {
            return "budget_row_enter_limit".localized
        }
        return "budget_row_status".localized(with: status.title, Int((progress * 100).rounded()))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                HeroIcon(systemName: category.iconSystemName, size: 22)
                    .foregroundStyle(category.color)
                    .frame(width: 44, height: 44)
                    .background(category.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if status != .noLimit {
                            Circle()
                                .fill(status.color)
                                .frame(width: 7, height: 7)
                        }
                        Text(subtitle)
                            .font(.caption.weight(status == .noLimit ? .regular : .medium))
                            .foregroundStyle(status == .noLimit || status == .onTrack ? Color.secondary : status.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 8)

                Toggle("", isOn: $isEnabled.animation(.easeInOut(duration: 0.18)))
                    .labelsHidden()
                    .tint(category.color)
                    .accessibilityLabel("Budget for \(category.name)")
            }

            if isEnabled {
                Divider()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("budget_monthly_limit".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("0", text: $budgetAmount)
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.semibold))
                            .fontDesign(.rounded)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .accessibilityLabel("budget_monthly_limit".localized)
                    }

                    Text(currency.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 54)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if enteredAmount > 0 {
                    VStack(spacing: 8) {
                        BudgetProgressBar(progress: progress, tint: barTint)

                        HStack(alignment: .firstTextBaseline) {
                            Text("budget_row_spent_of".localized(with:
                                CurrencyFormatter.format(currentMonthSpent, currency: currency),
                                CurrencyFormatter.format(enteredAmount, currency: currency)
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                            Spacer(minLength: 8)

                            Text(status == .overBudget
                                 ? "budget_row_over".localized(with: CurrencyFormatter.format(currentMonthSpent - enteredAmount, currency: currency))
                                 : "budget_row_left".localized(with: CurrencyFormatter.format(enteredAmount - currentMonthSpent, currency: currency)))
                                .fontWeight(.semibold)
                                .foregroundStyle(status == .overBudget ? Color(.systemRed) : Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .budgetScrollCard(cornerRadius: 18)
        .onChange(of: isEnabled) { _, _ in
            updateBudget()
        }
        .onChange(of: budgetAmount) { old, _ in
            formatBudgetInput(previous: old)
            updateBudget()
        }
        .onChange(of: budget) { _, newBudget in
            updateLocalState(from: newBudget)
        }
    }

    private func updateBudget() {
        let amount = AmountInputFormatter.parse(budgetAmount) ?? 0
        guard budget?.amount != amount || budget?.isEnabled != isEnabled else { return }
        onChange(amount, isEnabled)
    }

    private func updateLocalState(from budget: CategoryBudget?) {
        guard let budget else {
            if !budgetAmount.isEmpty { budgetAmount = "" }
            if isEnabled { isEnabled = false }
            return
        }

        let formattedAmount = budget.amount > 0 ? AmountInputFormatter.formatValue(budget.amount) : ""
        if budgetAmount != formattedAmount { budgetAmount = formattedAmount }
        if isEnabled != budget.isEnabled { isEnabled = budget.isEnabled }
    }

    private func formatBudgetInput(previous: String) {
        let formatted = AmountInputFormatter.formatEditingText(budgetAmount, previous: previous)
        if formatted != budgetAmount {
            budgetAmount = formatted
        }
    }
}

struct SpendingGoalRow: View {
    let goal: SpendingGoal
    var onDelete: (() -> Void)?

    @ObservedObject private var dataManager = DataManager.shared
    @State private var showingCompletionAlert = false

    private var category: UserCategory {
        dataManager.resolveCategory(id: goal.categoryId)
    }

    private var deadlineText: String {
        goal.deadline.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                HeroIcon(systemName: category.iconSystemName, size: 21)
                    .foregroundStyle(category.color)
                    .frame(width: 42, height: 42)
                    .background(category.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(category.name)
                        .font(.caption)
                        .foregroundStyle(category.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        HeroIcon("trash", size: 19)
                            .foregroundStyle(Color(.systemRed))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(goal.title)")
                }
            }

            VStack(spacing: 8) {
                ProgressView(value: goal.progress)
                    .tint(goal.isCompleted ? Color(.systemGreen) : category.color)

                HStack(alignment: .firstTextBaseline) {
                    Text(CurrencyFormatter.format(goal.currentAmount, currency: dataManager.user.currency))
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                    Text("of \(CurrencyFormatter.format(goal.targetAmount, currency: dataManager.user.currency))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int((goal.progress * 100).rounded()))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(goal.isCompleted ? Color(.systemGreen) : category.color)
                }
            }

            HStack(spacing: 6) {
                HeroIcon("calendar", size: 14)
                Text("Due \(deadlineText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .budgetScrollCard(cornerRadius: 18)
        .onChange(of: goal.progress) { _, newProgress in
            if newProgress >= 1, !goal.isCompleted {
                showingCompletionAlert = true
            }
        }
        .alert("Goal completed", isPresented: $showingCompletionAlert) {
            Button("ok".localized) { }
        } message: {
            Text("You reached your goal: \(goal.title)")
        }
    }
}

private extension View {
    func budgetScrollCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(Color(.secondarySystemBackground), in: shape)
            .overlay(shape.stroke(iOSDesignSystem.layerStroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.035), radius: 5, x: 0, y: 2)
    }
}

struct AddSpendingGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    @State private var title = ""
    @State private var targetAmount = ""
    @State private var deadline = Date().addingTimeInterval(30 * 24 * 60 * 60)
    @State private var selectedCategory: UserCategory?

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let amount = AmountInputFormatter.parse(targetAmount),
              amount > 0,
              selectedCategory != nil else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                iOSDesignSystem.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        goalIntro
                        goalDetails

                        Button(action: saveGoal) {
                            HStack(spacing: 8) {
                                HeroIcon("plus", size: 18)
                                Text("Add goal")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .opacity(canSave ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave)
                    }
                    .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("New spending goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(iOSDesignSystem.appBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                }
            }
            .onAppear {
                if selectedCategory == nil {
                    selectedCategory = dataManager.userCategories.first
                }
            }
        }
    }

    private var goalIntro: some View {
        HStack(spacing: 14) {
            HeroIcon("flag", size: 25)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .liquidGlassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Set a clear target")
                    .font(.headline)
                Text("Choose a category, amount, and deadline. Progress updates from your expenses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlassCard(cornerRadius: 18)
    }

    private var goalDetails: some View {
        VStack(spacing: 0) {
            goalField(label: "Goal name") {
                TextField("e.g. Dining limit", text: $title)
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
            }

            Divider().padding(.leading, 16)

            goalField(label: "Target amount") {
                HStack(spacing: 8) {
                    TextField("0", text: $targetAmount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .fontDesign(.rounded)
                        .onChange(of: targetAmount) { old, _ in formatTargetAmountInput(previous: old) }
                    Text(dataManager.user.currency.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 180)
            }

            Divider().padding(.leading, 16)

            goalField(label: "Deadline") {
                DatePicker("", selection: $deadline, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
            }

            Divider().padding(.leading, 16)

            goalField(label: "Category") {
                if dataManager.userCategories.isEmpty {
                    Text("No categories")
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(dataManager.userCategories) { category in
                            Button {
                                selectedCategory = category
                            } label: {
                                Text(category.name)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if let selectedCategory {
                                HeroIcon(systemName: selectedCategory.iconSystemName, size: 17)
                                    .foregroundStyle(selectedCategory.color)
                                Text(selectedCategory.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            } else {
                                Text("Select category")
                                    .foregroundStyle(.secondary)
                            }
                            HeroIcon("chevron-right", size: 14)
                                .foregroundStyle(Color(.tertiaryLabel))
                        }
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .liquidGlassCard(cornerRadius: 18)
    }

    private func goalField<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    private func saveGoal() {
        guard canSave,
              let amount = AmountInputFormatter.parse(targetAmount),
              let categoryId = selectedCategory?.id else { return }

        let goal = SpendingGoal(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            targetAmount: amount,
            deadline: deadline,
            categoryId: categoryId
        )
        dataManager.spendingGoals.append(goal)
        dataManager.saveSpendingGoals()
        dismiss()
    }

    private func formatTargetAmountInput(previous: String) {
        let formatted = AmountInputFormatter.formatEditingText(targetAmount, previous: previous)
        if formatted != targetAmount {
            targetAmount = formatted
        }
    }
}

private struct BudgetEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            HeroIcon(icon, size: 26)
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 18)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .liquidGlassSurface(Capsule())
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .liquidGlassCard(cornerRadius: 18)
    }
}

#Preview {
    BudgetSettingsView()
}
