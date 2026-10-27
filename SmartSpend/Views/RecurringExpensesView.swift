import SwiftUI

struct RecurringExpensesView: View {
    @ObservedObject private var dataManager = DataManager.shared

    @State private var showingAddRecurring = false
    @State private var selectedRecurring: RecurringExpense?
    @State private var isSelectionMode = false
    @State private var selectedRecurringExpenses: Set<UUID> = []
    @State private var filter: RecurringFilter = .all
    @State private var pendingDeletion: Set<UUID> = []

    private enum RecurringFilter: CaseIterable, Identifiable {
        case all
        case active
        case inactive

        var id: Self { self }

        var title: String {
            switch self {
            case .all: return "all".localized
            case .active: return "active".localized
            case .inactive: return "inactive".localized
            }
        }
    }

    private var sortedRecurringExpenses: [RecurringExpense] {
        dataManager.recurringExpenses
            .filter { recurring in
                switch filter {
                case .all:
                    return true
                case .active:
                    return recurring.isActive && !recurring.isExpired
                case .inactive:
                    return !recurring.isActive || recurring.isExpired
                }
            }
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.isActive && !lhs.isExpired
                let rhsIsActive = rhs.isActive && !rhs.isExpired

                if lhsIsActive != rhsIsActive {
                    return lhsIsActive
                }
                // Active: soonest charge first. Paused/ended: their due date is meaningless, so by name.
                if lhsIsActive, lhs.nextDueDate != rhs.nextDueDate {
                    return lhs.nextDueDate < rhs.nextDueDate
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// Bills that will still charge: active and not past their end date.
    private var runningRecurringExpenses: [RecurringExpense] {
        dataManager.recurringExpenses.filter { $0.isActive && !$0.isExpired }
    }

    private var notifications: [RecurringExpenseNotification] {
        dataManager.getRecurringExpenseNotifications()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                if dataManager.recurringExpenses.isEmpty {
                    EmptyRecurringExpensesView {
                        showingAddRecurring = true
                    }
                } else {
                    recurringContent
                }
            }
            .background(iOSDesignSystem.appBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddRecurring) {
                AddRecurringExpenseView()
            }
            .sheet(item: $selectedRecurring) { recurring in
                EditRecurringExpenseView(recurringExpense: recurring)
            }
            .confirmationDialog(
                pendingDeletion.count > 1
                    ? String(format: "recurring_delete_selected_format".localized, pendingDeletion.count)
                    : "recurring_delete_title".localized,
                isPresented: Binding(
                    get: { !pendingDeletion.isEmpty },
                    set: { if !$0 { pendingDeletion.removeAll() } }
                ),
                titleVisibility: .visible
            ) {
                Button("delete".localized, role: .destructive) {
                    confirmDeletion()
                }
            } message: {
                Text("recurring_delete_message".localized)
            }
            .onChange(of: filter) { _, _ in
                // Never delete selected rows the new filter hides.
                let visible = Set(sortedRecurringExpenses.map(\.id))
                selectedRecurringExpenses.formIntersection(visible)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelectionMode {
                    selectionBar
                }
            }
            .onAppear {
                dataManager.processRecurringExpenses()
            }
        }
    }

    private var header: some View {
        AppScreenHeader("recurring".localized) {
            if isSelectionMode {
                Button("cancel".localized) {
                    endSelectionMode()
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                .accessibilityIdentifier("recurringCancelSelectionButton")
            } else {
                if !dataManager.recurringExpenses.isEmpty {
                    ActionIconButton(icon: "check-circle", style: .secondary) {
                        withAnimation(.snappy(duration: 0.25)) {
                            isSelectionMode = true
                        }
                    }
                    .accessibilityLabel("recurring_select".localized)
                    .accessibilityIdentifier("recurringSelectButton")
                }

                ActionIconButton(icon: "plus", style: .primary) {
                    showingAddRecurring = true
                }
                .accessibilityLabel("add_recurring_expense".localized)
                .accessibilityIdentifier("addRecurringButton")
            }
        }
    }

    private var recurringContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !runningRecurringExpenses.isEmpty {
                    RecurringSummaryCard(
                        running: runningRecurringExpenses,
                        currency: dataManager.user.currency
                    )
                }

                if !notifications.isEmpty {
                    RecurringAttentionCard(notifications: notifications) {
                        dataManager.processRecurringExpenses()
                    }
                }

                filterControl

                if sortedRecurringExpenses.isEmpty {
                    filteredEmptyState
                } else {
                    recurringList
                }
            }
            .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
            .padding(.top, 6)
            .padding(.bottom, iOSDesignSystem.Spacing.screenMargin)
        }
        .scrollIndicators(.hidden)
        .background(iOSDesignSystem.appBackground)
    }

    private var filterControl: some View {
        HStack(spacing: 5) {
            ForEach(RecurringFilter.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        filter = item
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Text("\(recurringCount(for: item))")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(filter == item ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 20)
                            .background(
                                filter == item
                                    ? Color.accentColor.opacity(0.09)
                                    : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(filter == item ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .background {
                        if filter == item {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.075))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.accentColor.opacity(0.13), lineWidth: 1)
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.title), \(recurringCount(for: item))")
            }
        }
        .padding(4)
        .liquidGlassSurface(Capsule())
    }

    private var recurringList: some View {
        LazyVStack(spacing: 12) {
            ForEach(sortedRecurringExpenses) { recurring in
                Button {
                    if isSelectionMode {
                        toggleSelection(recurring)
                    } else {
                        selectedRecurring = recurring
                    }
                } label: {
                    RecurringExpenseCard(
                        recurringExpense: recurring,
                        categoryInfo: categoryDisplayInfo(for: recurring),
                        currency: dataManager.user.currency,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedRecurringExpenses.contains(recurring.id)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recurringExpenseCard")
                .accessibilityAddTraits(isSelectionMode && selectedRecurringExpenses.contains(recurring.id) ? .isSelected : [])
                .contextMenu {
                    if !isSelectionMode {
                        Button {
                            selectedRecurring = recurring
                        } label: {
                            Label("edit".localized, systemImage: "pencil")
                        }

                        if !recurring.isExpired {
                            Button {
                                toggleActive(recurring)
                            } label: {
                                if recurring.isActive {
                                    Label("recurring_pause".localized, systemImage: "pause.circle")
                                } else {
                                    Label("recurring_resume".localized, systemImage: "play.circle")
                                }
                            }
                        }

                        Button(role: .destructive) {
                            pendingDeletion = [recurring.id]
                        } label: {
                            Label("delete".localized, systemImage: "trash")
                        }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: sortedRecurringExpenses.map(\.id))
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            HeroIcon(filter == .inactive ? "pause-circle" : "arrow-path", size: 27)
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, height: 54)
                .background(Color.accentColor.opacity(0.08), in: Circle())

            Text((filter == .inactive ? "recurring_empty_inactive_title" : "recurring_empty_active_title").localized)
                .font(.headline)

            Text((filter == .inactive ? "recurring_empty_inactive_message" : "recurring_empty_active_message").localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 54)
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "selected_count".localized, selectedRecurringExpenses.count))
                    .font(.headline)

                Text("recurring_expenses_title".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                deleteSelectedRecurring()
            } label: {
                HeroIcon("trash", size: 21)
                    .foregroundStyle(selectedRecurringExpenses.isEmpty ? Color(.systemGray3) : Color(.systemRed))
                    .frame(width: 44, height: 44)
                    .background(
                        Color(.systemRed).opacity(selectedRecurringExpenses.isEmpty ? 0.04 : 0.09),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedRecurringExpenses.isEmpty)
            .accessibilityLabel("delete".localized)
            .accessibilityIdentifier("recurringDeleteSelectedButton")
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .liquidGlassSurface(Capsule())
        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
        .padding(.bottom, iOSDesignSystem.Spacing.small)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func recurringCount(for filter: RecurringFilter) -> Int {
        dataManager.recurringExpenses.reduce(into: 0) { count, recurring in
            let isActive = recurring.isActive && !recurring.isExpired

            switch filter {
            case .all:
                count += 1
            case .active where isActive:
                count += 1
            case .inactive where !isActive:
                count += 1
            default:
                break
            }
        }
    }

    private func categoryDisplayInfo(for recurring: RecurringExpense) -> RecurringCategoryInfo {
        let category = dataManager.resolveCategory(id: recurring.categoryId)
        return RecurringCategoryInfo(
            name: category.name,
            icon: category.iconSystemName,
            color: category.color
        )
    }

    private func toggleSelection(_ recurring: RecurringExpense) {
        withAnimation(.snappy(duration: 0.2)) {
            if selectedRecurringExpenses.contains(recurring.id) {
                selectedRecurringExpenses.remove(recurring.id)
            } else {
                selectedRecurringExpenses.insert(recurring.id)
            }
        }
    }

    private func endSelectionMode() {
        withAnimation(.snappy(duration: 0.25)) {
            isSelectionMode = false
            selectedRecurringExpenses.removeAll()
        }
    }

    private func deleteSelectedRecurring() {
        guard !selectedRecurringExpenses.isEmpty else { return }
        pendingDeletion = selectedRecurringExpenses
    }

    private func confirmDeletion() {
        let ids = pendingDeletion
        withAnimation(.snappy(duration: 0.28)) {
            dataManager.deleteRecurringExpenses(ids: ids)
            selectedRecurringExpenses.subtract(ids)
            if isSelectionMode {
                isSelectionMode = false
                selectedRecurringExpenses.removeAll()
            }
        }
        pendingDeletion.removeAll()
    }

    /// Pause/resume goes through `updateRecurringExpense`, so resuming skips the paused period.
    private func toggleActive(_ recurring: RecurringExpense) {
        var updated = recurring
        updated.isActive.toggle()
        withAnimation(.snappy(duration: 0.25)) {
            dataManager.updateRecurringExpense(updated)
        }
    }
}

private struct RecurringCategoryInfo {
    let name: String
    let icon: String
    let color: Color
}

/// Monthly cost of everything still charging, with each frequency averaged to a month,
/// plus the next upcoming charge.
private struct RecurringSummaryCard: View {
    let running: [RecurringExpense]
    let currency: Currency

    private var monthlyTotal: Double {
        running.reduce(0) { $0 + $1.monthlyEquivalentAmount }
    }

    private var nextCharge: RecurringExpense? {
        running.min { $0.nextDueDate < $1.nextDueDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("recurring_per_month".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(String(format: "recurring_active_count_format".localized, running.count))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 24)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            Text(CurrencyFormatter.format(monthlyTotal, currency: currency))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .accessibilityIdentifier("recurringMonthlyTotal")

            if let nextCharge {
                Rectangle()
                    .fill(Color(.separator).opacity(0.5))
                    .frame(height: 1)

                HStack(spacing: 8) {
                    HeroIcon("calendar", size: 16)
                        .foregroundStyle(dueColor(for: nextCharge))
                    Text(String(
                        format: "recurring_next_charge_format".localized,
                        nextCharge.title,
                        relativeDueText(for: nextCharge.nextDueDate)
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(CurrencyFormatter.format(nextCharge.amount, currency: currency))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(iOSDesignSystem.Spacing.screenMargin)
        .liquidGlassCard()
        .accessibilityElement(children: .combine)
    }
}

private struct RecurringAttentionCard: View {
    let notifications: [RecurringExpenseNotification]
    let process: () -> Void

    private var primaryNotification: RecurringExpenseNotification? {
        notifications.first
    }

    private var hasOverdue: Bool {
        notifications.contains { notification in
            if case .overdue = notification.type { return true }
            return false
        }
    }

    private var tint: Color {
        hasOverdue ? Color(.systemRed) : Color(.systemOrange)
    }

    var body: some View {
        HStack(spacing: 12) {
            HeroIcon(hasOverdue ? "exclamation-triangle" : "bell", size: 20)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.09), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if notifications.count > 1 {
                        Text("\(notifications.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(tint, in: Circle())
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryNotification?.recurringExpense.title ?? "upcoming_bills".localized)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(primaryNotification.map { relativeDueText(for: $0.recurringExpense.nextDueDate) } ?? "")
                    .font(.caption)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("process".localized, action: process)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                .background(tint.opacity(0.08), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(iOSDesignSystem.elevatedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

private struct RecurringExpenseCard: View {
    let recurringExpense: RecurringExpense
    let categoryInfo: RecurringCategoryInfo
    let currency: Currency
    let isSelectionMode: Bool
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(categoryInfo.color.opacity(0.10))

                        HeroIcon(systemName: categoryInfo.icon, size: 22)
                            .foregroundStyle(categoryInfo.color)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(recurringExpense.title.isEmpty ? categoryInfo.name : recurringExpense.title)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            Text(categoryInfo.name)
                                .lineLimit(1)

                            Circle()
                                .fill(statusColor)
                                .frame(width: 5, height: 5)

                            Text(statusText)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Text(CurrencyFormatter.format(recurringExpense.amount, currency: currency))
                        .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .multilineTextAlignment(.trailing)
                }

                Divider()
                    .overlay(Color(.separator).opacity(0.16))

                HStack(spacing: 10) {
                    Capsule()
                        .fill(statusColor)
                        .frame(width: 3, height: 34)

                    HeroIcon(recurringExpense.isActive ? "calendar" : "pause-circle", size: 18)
                        .foregroundStyle(statusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(scheduleHeadline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)

                        if let scheduleDetail {
                            Text(scheduleDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        HeroIcon(systemName: recurringExpense.recurrenceType.icon, size: 13)
                        Text(recurringExpense.recurrenceType.localizedName)
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(categoryInfo.color)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 30)
                    .background(categoryInfo.color.opacity(0.075), in: Capsule())
                }
            }

            if isSelectionMode {
                selectionMark
                    .padding(.top, 11)
                    .padding(.trailing, iOSDesignSystem.Spacing.small)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .background(iOSDesignSystem.elevatedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.48) : Color(.separator).opacity(0.14),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(color: categoryInfo.color.opacity(0.035), radius: 12, x: 0, y: 6)
        .shadow(color: Color.black.opacity(0.025), radius: 3, x: 0, y: 1)
        .scaleEffect(isSelected ? 0.985 : 1)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityElement(children: .combine)
    }

    private var selectionMark: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? Color.accentColor : Color(.systemGray3), lineWidth: 2)
                .frame(width: 24, height: 24)

            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 24)

                HeroIcon("check", size: 12)
                    .foregroundStyle(.white)
            }
        }
    }

    private var statusColor: Color {
        dueColor(for: recurringExpense)
    }

    /// Paused and ended bills have no real "next due", so say what state they are in instead.
    private var scheduleHeadline: String {
        if recurringExpense.isExpired, let endDate = recurringExpense.endDate {
            return String(format: "recurring_ended_on_format".localized, exactDueDateText(for: endDate))
        } else if !recurringExpense.isActive {
            return "recurring_paused".localized
        }
        return relativeDueText(for: recurringExpense.nextDueDate)
    }

    private var scheduleDetail: String? {
        guard recurringExpense.isActive, !recurringExpense.isExpired else { return nil }
        let due = exactDueDateText(for: recurringExpense.nextDueDate)
        guard let endDate = recurringExpense.endDate else { return due }
        return "\(due) · " + String(format: "recurring_ends_on_format".localized, exactDueDateText(for: endDate))
    }

    private var statusText: String {
        if !recurringExpense.isActive {
            return "recurring_paused".localized
        } else if recurringExpense.isExpired {
            return "expired".localized
        } else if recurringExpense.isOverdue {
            return "overdue".localized
        } else if recurringExpense.isDue {
            return "due".localized
        } else {
            return "active".localized
        }
    }
}

struct EmptyRecurringExpensesView: View {
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 44)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 84, height: 84)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
                    .frame(width: 84, height: 84)

                HeroIcon("arrow-path", size: 34)
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 9) {
                Text("no_recurring_expenses".localized)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("set_up_recurring_expenses".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
            }

            Button(action: addAction) {
                HStack(spacing: 8) {
                    HeroIcon("plus", size: 18)
                    Text("add_recurring_expense".localized)
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .liquidGlassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, iOSDesignSystem.Spacing.large)
        .background(iOSDesignSystem.appBackground)
    }
}

private func relativeDueText(for date: Date) -> String {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let due = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0

    if days < 0 {
        return days == -1
            ? "recurring_overdue_one_day".localized
            : String(format: "recurring_overdue_days_format".localized, -days)
    } else if days == 0 {
        return "due_today".localized
    } else if days == 1 {
        return "due_tomorrow".localized
    } else {
        return String(format: "due_in_days_format".localized, days)
    }
}

private func exactDueDateText(for date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
}

private func dueColor(for recurring: RecurringExpense) -> Color {
    if !recurring.isActive || recurring.isExpired {
        return Color(.systemGray)
    } else if recurring.isOverdue {
        return Color(.systemRed)
    } else if recurring.isDue {
        return Color(.systemOrange)
    } else {
        return Color(.systemGreen)
    }
}

#Preview {
    RecurringExpensesView()
}
