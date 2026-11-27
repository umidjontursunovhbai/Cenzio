import SwiftUI

struct RecurringExpensesView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    @Environment(\.colorScheme) private var colorScheme

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

    /// The list is split by when the next charge comes; order inside each part is unchanged.
    private enum RecurringGroup: CaseIterable, Identifiable {
        case thisWeek, later, paused

        var id: Self { self }

        var title: String {
            switch self {
            case .thisWeek: return "recurring_group_this_week".localized
            case .later: return "recurring_group_later".localized
            case .paused: return "recurring_group_paused".localized
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

    private var currency: Currency { dataManager.user.currency }

    private func group(for recurring: RecurringExpense) -> RecurringGroup {
        guard recurring.isActive, !recurring.isExpired else { return .paused }
        let calendar = Calendar.current
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: Date())) ?? Date()
        return recurring.nextDueDate < weekEnd ? .thisWeek : .later
    }

    private var groupedRecurring: [(group: RecurringGroup, items: [RecurringExpense])] {
        let sorted = sortedRecurringExpenses
        return RecurringGroup.allCases.compactMap { group in
            let items = sorted.filter { self.group(for: $0) == group }
            return items.isEmpty ? nil : (group, items)
        }
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
                    filterChips
                    recurringContent
                }
            }
            .background(NightGround())
            .tint(NightTheme.accent)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showingAddRecurring) {
                AddRecurringExpenseView()
            }
            .fullScreenCover(item: $selectedRecurring) { recurring in
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
            .overlay(alignment: .bottom) {
                if isSelectionMode {
                    selectionBar
                        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                        .padding(.bottom, 12 + tabBarClearance)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                dataManager.processRecurringExpenses()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("recurring".localized)
                    .font(NightTheme.display(46))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .capFigure(isSelectionMode ? nil : .cyclist, fontSize: 46, relativeTo: .largeTitle)
                    .accessibilityAddTraits(.isHeader)
                headerSubtitle
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if isSelectionMode {
                    Button("cancel".localized) {
                        endSelectionMode()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(NightTheme.accent)
                    .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                    .accessibilityIdentifier("recurringCancelSelectionButton")
                } else {
                    if !dataManager.recurringExpenses.isEmpty {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                isSelectionMode = true
                            }
                        } label: {
                            headerCircle(filled: false) { HeroIcon("check-circle", size: 20) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("recurring_select".localized)
                        .accessibilityIdentifier("recurringSelectButton")
                    }

                    Button {
                        showingAddRecurring = true
                    } label: {
                        headerCircle(filled: true) { HeroIcon("plus", size: 20) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("add_recurring_expense".localized)
                    .accessibilityIdentifier("addRecurringButton")
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    /// "3 670 000 so'm a month · 6 active"; "N selected" while selecting.
    @ViewBuilder
    private var headerSubtitle: some View {
        if isSelectionMode {
            Text(String(format: "selected_count".localized, selectedRecurringExpenses.count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NightTheme.secondaryLabel)
        } else if !runningRecurringExpenses.isEmpty {
            let running = runningRecurringExpenses
            let monthly = running.reduce(0) { $0 + $1.monthlyEquivalentAmount }
            let total = Text(CurrencyFormatter.format(monthly, currency: currency)).foregroundStyle(.primary)
            let parts = "recurring_header_monthly_format".localized.components(separatedBy: "%@")
            let suffix = (parts.count > 1 ? parts[1] : "") + " · " + String(format: "recurring_active_count_format".localized, running.count)
            Text("\(parts[0])\(total)\(suffix)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .accessibilityIdentifier("recurringMonthlyTotal")
        }
    }

    /// A 44 pt header circle: glass, or filled with the accent for the main action.
    private func headerCircle<Content: View>(filled: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(filled ? (colorScheme == .dark ? NightTheme.ink : Color.white) : NightTheme.accent)
            .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
            .background(filled ? NightTheme.accent : NightTheme.glassFill, in: Circle())
            .overlay(Circle().stroke(filled ? Color.clear : NightTheme.glassLine, lineWidth: 1))
            .contentShape(Circle())
    }

    // MARK: - Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RecurringFilter.allCases) { item in
                    chip(item)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 4)
    }

    private func chip(_ item: RecurringFilter) -> some View {
        let isOn = filter == item
        let count = recurringCount(for: item)
        return Button {
            withAnimation(.snappy(duration: 0.24)) {
                filter = item
            }
        } label: {
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(isOn ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .opacity(0.7)
            }
            .foregroundStyle(isOn ? (colorScheme == .dark ? NightTheme.ink : Color.white) : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isOn ? NightTheme.accent : NightTheme.glassFill, in: Capsule())
            .overlay(Capsule().stroke(isOn ? Color.clear : NightTheme.glassLine, lineWidth: 1))
            .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - List

    @ViewBuilder
    private var recurringContent: some View {
        if sortedRecurringExpenses.isEmpty {
            ScrollView {
                if !notifications.isEmpty, !isSelectionMode {
                    attentionRow
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                filteredEmptyState
            }
            .scrollIndicators(.hidden)
        } else {
            recurringList
        }
    }

    private var recurringList: some View {
        List {
            if !notifications.isEmpty, !isSelectionMode {
                Section {
                    attentionRow
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            ForEach(groupedRecurring, id: \.group) { entry in
                Section {
                    ForEach(entry.items) { recurring in
                        row(recurring)
                    }
                } header: {
                    groupHeader(entry.group, items: entry.items)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(12)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, isSelectionMode ? 88 : 12, for: .scrollContent)
        .animation(.snappy(duration: 0.28), value: sortedRecurringExpenses.map(\.id))
        .animation(.snappy(duration: 0.25), value: isSelectionMode)
    }

    private func groupHeader(_ group: RecurringGroup, items: [RecurringExpense]) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(group.title)
                .font(NightTheme.display(21, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(group == .paused
                 ? String(format: "recurring_count_format".localized, items.count)
                 : CurrencyFormatter.format(items.reduce(0) { $0 + $1.amount }, currency: currency))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(NightTheme.secondaryLabel)
                .lineLimit(1)
        }
        .textCase(nil)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ recurring: RecurringExpense) -> some View {
        let isSelected = selectedRecurringExpenses.contains(recurring.id)
        return Button {
            if isSelectionMode {
                toggleSelection(recurring)
            } else {
                selectedRecurring = recurring
            }
        } label: {
            RecurringRowView(
                recurringExpense: recurring,
                category: dataManager.resolveCategory(id: recurring.categoryId),
                currency: currency,
                selection: isSelectionMode ? isSelected : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recurringExpenseCard")
        .listRowBackground(isSelectionMode && isSelected ? NightTheme.accent.opacity(0.14) : NightTheme.glassFill)
        .listRowSeparatorTint(NightTheme.hair)
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

    /// One row for bills waiting to be recorded: red when one is overdue, amber when only due.
    private var attentionRow: some View {
        let hasOverdue = notifications.contains { if case .overdue = $0.type { return true } else { return false } }
        let tint = hasOverdue ? RecurringStatusColor.overdue : RecurringStatusColor.due(colorScheme)
        let first = notifications.first?.recurringExpense
        let title: String = {
            guard let first else { return "upcoming_bills".localized }
            return notifications.count > 1
                ? String(format: "recurring_attention_more_format".localized, first.title, notifications.count - 1)
                : first.title
        }()

        return HStack(spacing: 12) {
            HeroIcon(hasOverdue ? "exclamation-triangle" : "bell", size: 18)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(first.map { relativeDueText(for: $0.nextDueDate) } ?? "")
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("recurring_record".localized) {
                dataManager.processRecurringExpenses()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? NightTheme.ink : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(NightTheme.accent, in: Capsule())
            .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
            .contentShape(Capsule())
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(tint.opacity(0.28), lineWidth: 1))
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Text((filter == .inactive ? "recurring_empty_inactive_title" : "recurring_empty_active_title").localized)
                .font(NightTheme.display(30))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text((filter == .inactive ? "recurring_empty_inactive_message" : "recurring_empty_active_message").localized)
                .font(.subheadline)
                .foregroundStyle(NightTheme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 54)
    }

    private var selectionBar: some View {
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "selected_count".localized, selectedRecurringExpenses.count))
                    .font(.subheadline.weight(.semibold))
                Text("recurring_expenses_title".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                deleteSelectedRecurring()
            } label: {
                Label("delete".localized, systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Color(.systemRed).opacity(selectedRecurringExpenses.isEmpty ? 0.35 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedRecurringExpenses.isEmpty)
            .accessibilityIdentifier("recurringDeleteSelectedButton")
        }
        .padding(.leading, iOSDesignSystem.Spacing.large)
        .padding(.trailing, iOSDesignSystem.Spacing.small)
        .padding(.vertical, iOSDesignSystem.Spacing.small)
        .liquidGlassSurface(Capsule())
    }

    // MARK: - Actions

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

/// Status colors: red for a missed charge, lamp amber (orange by day) for one due today.
/// Everything else stays silver, like the rest of the night street.
enum RecurringStatusColor {
    static let overdue = Color(.systemRed)

    static func due(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? NightTheme.window : Color(.systemOrange)
    }
}

/// One recurring bill: white icon on a glass tile, title, "Monthly · due", amount.
/// Paused and ended bills are dimmed.
private struct RecurringRowView: View {
    let recurringExpense: RecurringExpense
    let category: UserCategory
    let currency: Currency
    /// `nil` outside selection mode; otherwise whether this row is selected.
    var selection: Bool?

    @Environment(\.colorScheme) private var colorScheme

    private var isRunning: Bool { recurringExpense.isActive && !recurringExpense.isExpired }

    var body: some View {
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            HeroIcon(systemName: category.iconSystemName, size: 18)
                .foregroundStyle(isRunning ? NightTheme.accent : NightTheme.secondaryLabel)
                .frame(width: 34, height: 34)
                .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(recurringExpense.title.isEmpty ? category.name : recurringExpense.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isRunning ? Color.primary : NightTheme.secondaryLabel)
                    .lineLimit(1)
                (Text(recurringExpense.recurrenceType.localizedName + " · ")
                    + Text(scheduleText).foregroundStyle(statusTint ?? NightTheme.secondaryLabel))
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: iOSDesignSystem.Spacing.small)

            Text(CurrencyFormatter.format(recurringExpense.amount, currency: currency))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isRunning ? Color.primary : NightTheme.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let isSelected = selection {
                selectionMark(isSelected)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.vertical, 2)
        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == true ? .isSelected : [])
    }

    /// Paused and ended bills have no real "next due", so say what state they are in instead.
    private var scheduleText: String {
        if recurringExpense.isExpired, let endDate = recurringExpense.endDate {
            return String(format: "recurring_ended_on_format".localized, exactDueDateText(for: endDate))
        } else if !recurringExpense.isActive {
            return "recurring_paused".localized
        }
        let due = recurringExpense.nextDueDate
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                   to: Calendar.current.startOfDay(for: due)).day ?? 0
        // Close charges read better as "Tomorrow"; later ones as a date.
        return days <= 1 ? relativeDueText(for: due) : exactDueDateText(for: due)
    }

    private var statusTint: Color? {
        guard isRunning else { return nil }
        if recurringExpense.isOverdue { return RecurringStatusColor.overdue }
        if recurringExpense.isDue { return RecurringStatusColor.due(colorScheme) }
        return nil
    }

    private func selectionMark(_ isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? NightTheme.accent : NightTheme.secondaryLabel.opacity(0.6), lineWidth: 1.5)
            if isSelected {
                Circle().fill(NightTheme.accent)
                HeroIcon("check", size: 12)
                    .foregroundStyle(colorScheme == .dark ? NightTheme.ink : .white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

/// No recurring bills yet: the small dark street with the cyclist and one Add button.
struct EmptyRecurringExpensesView: View {
    let addAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EmptyStreetView(figure: .cyclist)
            Text("no_recurring_expenses".localized)
                .font(NightTheme.display(34))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
            Text("set_up_recurring_expenses".localized)
                .font(.subheadline)
                .foregroundStyle(NightTheme.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .padding(.top, 10)

            Button(action: addAction) {
                Label("add_recurring_expense".localized, systemImage: "plus")
                    .padding(.horizontal, 24)
            }
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .fixedSize()
            .padding(.top, 26)
            .accessibilityIdentifier("emptyAddRecurringButton")
        }
        .padding(.horizontal, 32)
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

#Preview {
    RecurringExpensesView()
}
