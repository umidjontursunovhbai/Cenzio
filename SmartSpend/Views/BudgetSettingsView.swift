import SwiftUI

struct BudgetSettingsView: View {
    @ObservedObject private var dataManager = DataManager.shared

    private let focusCategoryID: UUID?

    @State private var showingAddGoal = false
    @State private var showingResetConfirmation = false
    @State private var showingInfo = false
    /// Drives the staggered reveal of the inline info sections after the card is inserted.
    @State private var infoContentVisible = false
    /// Category whose limit is being edited in the small sheet.
    @State private var editingCategory: UserCategory?

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

    private func currentMonthSpent(using spendingByCategory: [UUID: Double]) -> Double {
        let activeCategoryIDs = Set(activeBudgets.map(\.categoryId))

        return spendingByCategory.reduce(into: 0) { total, entry in
            guard activeCategoryIDs.contains(entry.key) else { return }
            total += entry.value
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

        // Pushed from Settings and the Dashboard: their stack gives the back button.
        return Group {
            ZStack {
                NightGround()

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
                            // The info replaces the page while open, so only the info is shown.
                            if !showingInfo {
                                monthlyOverview(currentMonthSpent: spentThisMonth)
                                categoryBudgetsSection(spendingByCategory: spendingByCategory)
                                spendingGoalsSection
                            }
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
                // Trailing: the leading side holds the system back button.
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: presentInfo) {
                        // The bar already draws the glass circle, so no extra circle here
                        // and a plain "i" instead of a circled one.
                        Group {
                            if showingInfo {
                                HeroIcon("x-mark", size: 20)
                            } else {
                                Image(systemName: "info")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                        .foregroundStyle(NightTheme.accent)
                        .frame(width: iOSDesignSystem.Size.minimumTapTarget,
                               height: iOSDesignSystem.Size.minimumTapTarget)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showingInfo ? "close".localized : "budget_info_title".localized)
                    .accessibilityIdentifier("budgetGoals.infoButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: suggestBudgets) {
                            Label("budget_suggest_title".localized, systemImage: "sparkles")
                        }
                        .disabled(!canSuggestBudgets)
                        Button(role: .destructive) {
                            showingResetConfirmation = true
                        } label: {
                            Label("budget_reset_row_title".localized, systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(NightTheme.accent)
                            .frame(width: iOSDesignSystem.Size.minimumTapTarget,
                                   height: iOSDesignSystem.Size.minimumTapTarget)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("budget_more_actions".localized)
                    .accessibilityIdentifier("budgetGoals.more")
                }
            }
            .sheet(isPresented: $showingAddGoal) {
                AddSpendingGoalView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground { NightGround() }
            }
            .sheet(item: $editingCategory) { category in
                CategoryBudgetEditSheet(category: category) { amount, isEnabled in
                    updateBudget(for: category.id, amount: amount, isEnabled: isEnabled)
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground { NightGround() }
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
        .tint(NightTheme.accent)
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
                    .foregroundStyle(NightTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(NightTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text("budget_info_title".localized)
                    .font(.headline)
                Spacer()
                Button(action: presentInfo) {
                    HeroIcon("x-mark", size: 16)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .frame(width: 30, height: 30)
                        .background(NightTheme.iconFill, in: Circle())
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

    private func monthlyOverview(currentMonthSpent: Double) -> some View {
        let currency = dataManager.user.currency
        let hasBudgets = totalBudget > 0
        let status = BudgetGoalStatus.evaluate(spent: currentMonthSpent, limit: totalBudget, isEnabled: hasBudgets)
        let progress = hasBudgets ? currentMonthSpent / totalBudget : 0
        let remaining = totalBudget - currentMonthSpent
        let tint = status == .onTrack ? NightTheme.accent : status.color

        return VStack(alignment: .leading, spacing: 12) {
            Text(Date().formatted(.dateTime.month(.wide).year()).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(NightTheme.secondaryLabel)

            if hasBudgets {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CurrencyFormatter.format(currentMonthSpent, currency: currency))
                        .font(.title2.weight(.bold))
                        .fontDesign(.rounded)
                    Text("/ \(CurrencyFormatter.format(totalBudget, currency: currency))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                BudgetProgressBar(progress: progress, tint: tint, showsThreshold: false)

                Text(remaining < 0
                     ? "budget_row_over".localized(with: CurrencyFormatter.format(-remaining, currency: currency))
                     : "budget_row_left".localized(with: CurrencyFormatter.format(remaining, currency: currency)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(remaining < 0 ? Color(.systemRed) : NightTheme.secondaryLabel)
            } else {
                Text("budget_no_limits_title".localized)
                    .font(.title3.weight(.bold))
                Text("budget_no_limits_message".localized)
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .budgetScrollCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Category budgets

    private func categoryBudgetsSection(spendingByCategory: [UUID: Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                title: "budget_category_section".localized,
                detail: dataManager.userCategories.isEmpty
                    ? nil
                    : "budget_active_count".localized(with: activeBudgets.count, dataManager.userCategories.count)
            )

            if dataManager.userCategories.isEmpty {
                BudgetEmptyState(
                    icon: "tag",
                    title: "budget_no_categories_title".localized,
                    message: "budget_no_categories_message".localized
                )
            } else {
                let limited = dataManager.userCategories.filter { limit(for: $0.id) > 0 }
                let unlimited = dataManager.userCategories.filter { limit(for: $0.id) <= 0 }

                if !limited.isEmpty {
                    categoryGroup(limited, spendingByCategory: spendingByCategory)
                }
                if !unlimited.isEmpty {
                    if !limited.isEmpty {
                        sectionHeading(title: "budget_no_limit_section".localized)
                            .padding(.top, 8)
                    }
                    categoryGroup(unlimited, spendingByCategory: spendingByCategory)
                }
            }
        }
    }

    private func limit(for categoryID: UUID) -> Double {
        guard let budget = dataManager.categoryBudgets.first(where: { $0.categoryId == categoryID }),
              budget.isEnabled else { return 0 }
        return budget.amount
    }

    /// One glass group of category rows. Tapping a row opens the small limit editor.
    private func categoryGroup(_ categories: [UserCategory], spendingByCategory: [UUID: Double]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                if index > 0 {
                    Rectangle().fill(NightTheme.hair).frame(height: 1).padding(.leading, 70)
                }
                Button {
                    editingCategory = category
                } label: {
                    CategoryBudgetLine(
                        category: category,
                        limit: limit(for: category.id),
                        currentMonthSpent: spendingByCategory[category.id, default: 0],
                        currency: dataManager.user.currency,
                        isFocused: focusCategoryID == category.id
                    )
                }
                .buttonStyle(.plain)
                .id(category.id)
            }
        }
        .budgetScrollCard(cornerRadius: 22)
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
                sectionHeading(
                    title: "budget_goals_section".localized,
                    detail: dataManager.spendingGoals.isEmpty ? nil : "\(dataManager.spendingGoals.count)"
                )

                Button {
                    showingAddGoal = true
                } label: {
                    HeroIcon("plus", size: 20)
                        .foregroundStyle(NightTheme.accent)
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
                VStack(spacing: 0) {
                    ForEach(Array(dataManager.spendingGoals.enumerated()), id: \.element.id) { index, goal in
                        if index > 0 {
                            Rectangle().fill(NightTheme.hair).frame(height: 1).padding(.leading, 60)
                        }
                        SpendingGoalRow(goal: goal) {
                            dataManager.spendingGoals.removeAll { $0.id == goal.id }
                            dataManager.saveSpendingGoals()
                        }
                    }
                }
                .budgetScrollCard(cornerRadius: 18)
            }
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
                    .foregroundStyle(NightTheme.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
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
                            .foregroundStyle(status == .noLimit || status == .onTrack ? NightTheme.secondaryLabel : status.color)
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
                Divider().overlay(NightTheme.hair)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("budget_monthly_limit".localized)
                            .font(.caption)
                            .foregroundStyle(NightTheme.secondaryLabel)
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
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 54)
                .background(NightTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if enteredAmount > 0 {
                    VStack(spacing: 8) {
                        BudgetProgressBar(progress: progress, tint: barTint)

                        HStack(alignment: .firstTextBaseline) {
                            Text("budget_row_spent_of".localized(with:
                                CurrencyFormatter.format(currentMonthSpent, currency: currency),
                                CurrencyFormatter.format(enteredAmount, currency: currency)
                            ))
                            .foregroundStyle(NightTheme.secondaryLabel)
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

/// One category on the Budget goals page, complete without opening anything:
/// with a limit it shows what is left (or over), a bar, spent of limit and the percent used;
/// without one it shows this month's spending and a "Set limit" pill.
/// Tapping it opens `CategoryBudgetEditSheet`.
struct CategoryBudgetLine: View {
    let category: UserCategory
    let limit: Double
    let currentMonthSpent: Double
    let currency: Currency
    var isFocused = false

    private var status: BudgetGoalStatus {
        BudgetGoalStatus.evaluate(spent: currentMonthSpent, limit: limit, isEnabled: limit > 0)
    }

    private var progress: Double { limit > 0 ? currentMonthSpent / limit : 0 }

    var body: some View {
        HStack(alignment: limit > 0 ? .top : .center, spacing: 14) {
            HeroIcon(systemName: category.iconSystemName, size: 21)
                .foregroundStyle(category.color)
                .frame(width: 40, height: 40)
                .background(category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            if limit > 0 {
                limitedContent
            } else {
                unlimitedContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, limit > 0 ? 16 : 12)
        .contentShape(Rectangle())
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(category.color.opacity(0.8), lineWidth: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("budget_edit_limit".localized)
    }

    private var limitedContent: some View {
        let remaining = limit - currentMonthSpent
        let isOver = remaining < 0
        let tint = status == .onTrack ? category.color : status.color

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(category.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(CurrencyFormatter.format(abs(remaining), currency: currency))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text((isOver ? "budget_row_over_label" : "budget_row_left_label").localized)
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(isOver ? Color(.systemRed) : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            }

            BudgetProgressBar(progress: progress, tint: tint, height: 6, showsThreshold: false)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 5) {
                    Text("budget_row_spent_of".localized(with:
                        CurrencyFormatter.format(currentMonthSpent, currency: currency),
                        CurrencyFormatter.format(limit, currency: currency)
                    ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    HeroIcon("pencil", size: 11)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(NightTheme.secondaryLabel)
                Spacer(minLength: 8)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(status == .onTrack ? NightTheme.secondaryLabel : status.color)
            }
            .font(.footnote)
            .monospacedDigit()
        }
    }

    private var unlimitedContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(currentMonthSpent > 0
                     ? "budget_row_spent_this_month".localized(with: CurrencyFormatter.format(currentMonthSpent, currency: currency))
                     : "budget_row_nothing_spent".localized)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Text("budget_set_limit".localized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(NightTheme.iconFill, in: Capsule())
                .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Small sheet to switch a category's limit on or off and enter the amount.
struct CategoryBudgetEditSheet: View {
    let category: UserCategory
    let onChange: (Double, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        let spent = BudgetPeriodCalculator.totalsByCategory(
            for: dataManager.expenses,
            in: BudgetPeriodCalculator.monthInterval(containing: Date())
        )[category.id, default: 0]

        NavigationStack {
            ScrollView {
                CategoryBudgetSettingRow(
                    category: category,
                    budget: dataManager.categoryBudgets.first { $0.categoryId == category.id },
                    currentMonthSpent: spent,
                    currency: dataManager.user.currency,
                    onChange: onChange
                )
                .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) {
                        dataManager.saveBudgets()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .tint(NightTheme.accent)
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

    var body: some View {
        HStack(spacing: 12) {
            HeroIcon(systemName: category.iconSystemName, size: 19)
                .foregroundStyle(category.color)
                .frame(width: 36, height: 36)
                .background(category.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(goal.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("budget_row_spent_of".localized(with:
                        CurrencyFormatter.format(goal.currentAmount, currency: dataManager.user.currency),
                        CurrencyFormatter.format(goal.targetAmount, currency: dataManager.user.currency)
                    ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                BudgetProgressBar(
                    progress: goal.progress,
                    tint: goal.isCompleted ? Color(.systemGreen) : category.color,
                    height: 4,
                    showsThreshold: false
                )
            }

            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    HeroIcon("trash", size: 17)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(goal.title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
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
            .background(NightTheme.glassFill, in: shape)
            .overlay(shape.stroke(NightTheme.glassLine, lineWidth: 1))
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
                NightGround()

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
                .foregroundStyle(NightTheme.accent)
                .frame(width: 52, height: 52)
                .liquidGlassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Set a clear target")
                    .font(.headline)
                Text("Choose a category, amount, and deadline. Progress updates from your expenses.")
                    .font(.caption)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .budgetScrollCard(cornerRadius: 18)
    }

    private var goalDetails: some View {
        VStack(spacing: 0) {
            goalField(label: "Goal name") {
                TextField("e.g. Dining limit", text: $title)
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
            }

            Divider().overlay(NightTheme.hair).padding(.leading, 16)

            goalField(label: "Target amount") {
                HStack(spacing: 8) {
                    TextField("0", text: $targetAmount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .fontDesign(.rounded)
                        .onChange(of: targetAmount) { old, _ in formatTargetAmountInput(previous: old) }
                    Text(dataManager.user.currency.rawValue)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .frame(maxWidth: 180)
            }

            Divider().overlay(NightTheme.hair).padding(.leading, 16)

            goalField(label: "Deadline") {
                DatePicker("", selection: $deadline, in: Date()..., displayedComponents: .date)
                    .labelsHidden()
            }

            Divider().overlay(NightTheme.hair).padding(.leading, 16)

            goalField(label: "Category") {
                if dataManager.userCategories.isEmpty {
                    Text("No categories")
                        .foregroundStyle(NightTheme.secondaryLabel)
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
                                    .foregroundStyle(NightTheme.secondaryLabel)
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
        .budgetScrollCard(cornerRadius: 18)
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
                .foregroundStyle(NightTheme.accent)
                .frame(width: 52, height: 52)
                .background(NightTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NightTheme.accent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .liquidGlassSurface(Capsule())
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .budgetScrollCard(cornerRadius: 18)
    }
}

#Preview {
    BudgetSettingsView()
}
