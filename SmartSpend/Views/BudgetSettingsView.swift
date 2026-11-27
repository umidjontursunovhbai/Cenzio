import SwiftUI

struct BudgetSettingsView: View {
    @ObservedObject private var dataManager = DataManager.shared

    private let focusCategoryID: UUID?

    @State private var showingAddGoal = false
    @State private var showingResetConfirmation = false
    @State private var showingInfo = false
    /// Category whose detail page is pushed.
    @State private var detailCategory: UserCategory?

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
                            monthlyOverview(currentMonthSpent: spentThisMonth)
                            categoryBudgetsSection(spendingByCategory: spendingByCategory)
                            spendingGoalsSection
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
                }
            }
            .navigationTitle("budget_goals".localized)
            .navigationBarTitleDisplayMode(.inline)
            // Default bar: on iOS 26 content scrolls under a soft, see-through top edge.
            .toolbar {
                // Trailing: the leading side holds the system back button.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingInfo = true } label: {
                        // The bar already draws the glass circle, so no extra circle here
                        // and a plain "i" instead of a circled one.
                        Image(systemName: "info")
                            .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NightTheme.accent)
                        .frame(width: iOSDesignSystem.Size.minimumTapTarget,
                               height: iOSDesignSystem.Size.minimumTapTarget)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("budget_info_title".localized)
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
            // Its own page in the same stack: back returns to Budget goals.
            .navigationDestination(isPresented: $showingInfo) {
                BudgetGoalsInfoPage(example: infoExample, currency: dataManager.user.currency)
            }
            .sheet(isPresented: $showingAddGoal) {
                AddSpendingGoalView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground { NightGround() }
            }
            .navigationDestination(item: $detailCategory) { category in
                CategoryBudgetDetailView(categoryID: category.id)
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

    // MARK: - Overview

    private func monthlyOverview(currentMonthSpent: Double) -> some View {
        let currency = dataManager.user.currency
        let hasBudgets = totalBudget > 0
        let status = BudgetGoalStatus.evaluate(spent: currentMonthSpent, limit: totalBudget, isEnabled: hasBudgets)
        let progress = hasBudgets ? currentMonthSpent / totalBudget : 0
        let remaining = totalBudget - currentMonthSpent
        let tint = status == .onTrack ? NightTheme.accent : status.color
        let pace = BudgetMonthPace()

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(hasBudgets
                     ? "budget_month_days_left".localized(with: Date().formatted(.dateTime.month(.wide).year()), pace.daysLeft).uppercased()
                     : Date().formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if hasBudgets {
                    BudgetStatusPill(status: status)
                }
            }

            if hasBudgets {
                VStack(alignment: .leading, spacing: 2) {
                    Text((remaining < 0 ? "budget_row_over" : "budget_row_left")
                        .localized(with: CurrencyFormatter.format(abs(remaining), currency: currency)))
                        .font(.title.weight(.bold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(remaining < 0 ? Color(.systemRed) : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("budget_total_used_percent".localized(with: Int((progress * 100).rounded())))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NightTheme.secondaryLabel)
                }

                BudgetPaceBar(progress: progress, tint: tint, todayFraction: pace.elapsedFraction)

                BudgetSpentLimitSplit(spent: currentMonthSpent, limit: totalBudget,
                                      limitLabel: "budget_label_budget".localized, currency: currency)

                if let daily = pace.dailyAllowance(remaining: remaining) {
                    Text("budget_daily_allowance".localized(with: CurrencyFormatter.format(daily, currency: currency)))
                        .font(.footnote)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// One glass group of category rows. Tapping a row pushes its detail page.
    private func categoryGroup(_ categories: [UserCategory], spendingByCategory: [UUID: Double]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                if index > 0 {
                    Rectangle().fill(NightTheme.hair).frame(height: 1).padding(.leading, 70)
                }
                Button {
                    detailCategory = category
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

/// One category on the Budget goals page, complete without opening anything:
/// with a limit it shows what is left (or over), a bar, spent of limit and the percent used;
/// without one it shows this month's spending and a "Set limit" pill.
/// Tapping it pushes `CategoryBudgetDetailView`.
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
        HStack(alignment: .center, spacing: 14) {
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

            HeroIcon("chevron-right", size: 13)
                .foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
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
        .accessibilityHint("budget_open_detail_hint".localized)
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
                Text("budget_row_spent_of".localized(with:
                    CurrencyFormatter.format(currentMonthSpent, currency: currency),
                    CurrencyFormatter.format(limit, currency: currency)
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
