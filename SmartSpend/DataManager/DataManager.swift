import Foundation
import SwiftUI
import WidgetKit

enum TimePeriod: String, CaseIterable {
    case today = "Today"
    case thisWeek = "This Week"
    case currentMonth = "This Month"
    case lastMonth = "Last Month"
    case all = "All Time"
    case customMonth = "Custom Month"
    
    var icon: String {
        switch self {
        case .today: return "calendar.day.timeline.left"
        case .thisWeek: return "calendar.badge.clock"
        case .currentMonth: return "calendar"
        case .lastMonth: return "calendar.badge.clock"
        case .all: return "infinity"
        case .customMonth: return "calendar.badge.exclamationmark"
        }
    }
    
    var localizedName: String {
        switch self {
        case .today: return "time_period_today".localized
        case .thisWeek: return "time_period_this_week".localized
        case .currentMonth: return "time_period_this_month".localized
        case .lastMonth: return "time_period_last_month".localized
        case .all: return "time_period_all".localized
        case .customMonth: return "time_period_custom".localized
        }
    }
}

class DataManager: ObservableObject {
    static let shared = DataManager()
    
    @Published var expenses: [Expense] = []
    @Published var user: User
    @Published var deletedExpenses: [ArchivedExpense] = []
    @Published var categoryBudgets: [CategoryBudget] = []
    @Published var spendingGoals: [SpendingGoal] = []
    @Published var monthlySalaries: [MonthlySalary] = []
    @Published var recurringExpenses: [RecurringExpense] = []
    @Published var learnedPatterns: [LearnedPattern] = []
    @Published var userCategories: [UserCategory] = []
    @Published var selectedTimePeriod: TimePeriod = .currentMonth
    @Published var customStartDate: Date = Date()
    @Published var customEndDate: Date = Date()

    private let sharedDefaults: UserDefaults
    private let activityManager: GamificationManager
    private let flushMCPStorage: () -> Bool
    private var dataLastChangedAt: Date = Date()
    private var isApplyingRemoteSnapshot = false
    /// Called after every local persist so iCloud sync can diff and upload (debounced there).
    var onLocalDataPersisted: (() -> Void)?

    private convenience init() {
        self.init(
            defaults: UserDefaults(suiteName: "group.ai.humblebee.smartspend") ?? .standard,
            activityManager: .shared,
            startBackgroundTasks: true
        )
    }

    // Isolated stores allow persistence tests without changing the installed app's data.
    init(defaults: UserDefaults, activityManager: GamificationManager, startBackgroundTasks: Bool = false,
         mcpStorageSync: (() -> Bool)? = nil) {
        self.sharedDefaults = defaults
        self.activityManager = activityManager
        self.flushMCPStorage = mcpStorageSync ?? { defaults.synchronize() }
        self.user = User(currency: .usd, language: .english)
        loadData()
        if startBackgroundTasks { startTimer() }
    }
    
    // MARK: - Data Persistence
    
    private func saveData() {
        do {
            let encoder = JSONEncoder()

            if !isApplyingRemoteSnapshot {
                dataLastChangedAt = Date()
            }
            
            // Save to local UserDefaults
            let expensesData = try encoder.encode(expenses)
            sharedDefaults.set(expensesData, forKey: "expenses")
            
            let userData = try encoder.encode(user)
            sharedDefaults.set(userData, forKey: "user")
            
            let deletedExpensesData = try encoder.encode(deletedExpenses)
            sharedDefaults.set(deletedExpensesData, forKey: "archivedExpenses")
            
            let categoryBudgetsData = try encoder.encode(categoryBudgets)
            sharedDefaults.set(categoryBudgetsData, forKey: "categoryBudgets")
            
            let spendingGoalsData = try encoder.encode(spendingGoals)
            sharedDefaults.set(spendingGoalsData, forKey: "spendingGoals")
            
            let monthlySalariesData = try encoder.encode(monthlySalaries)
            sharedDefaults.set(monthlySalariesData, forKey: "monthlySalaries")
            
            let recurringExpensesData = try encoder.encode(recurringExpenses)
            sharedDefaults.set(recurringExpensesData, forKey: "recurringExpenses")
            
            let learnedPatternsData = try encoder.encode(learnedPatterns)
            sharedDefaults.set(learnedPatternsData, forKey: "learnedPatterns")
            
            let userCategoriesData = try encoder.encode(userCategories)
            sharedDefaults.set(userCategoriesData, forKey: "userCategories")
            
            // Save custom date range
            sharedDefaults.set(customStartDate, forKey: "customStartDate")
            sharedDefaults.set(customEndDate, forKey: "customEndDate")
            sharedDefaults.set(dataLastChangedAt, forKey: "dataLastChangedAt")
            // A complete newer app save supersedes any interrupted bridge batch.
            // Never replay an older full-state journal over a later local edit.
            sharedDefaults.removeObject(forKey: "mcpPendingCommit")
            
        } catch {
            print("Error saving data: \(error)")
        }
        WidgetCenter.shared.reloadAllTimelines()
        if !isApplyingRemoteSnapshot { onLocalDataPersisted?() }
    }

    private func loadData() {
        let decoder = JSONDecoder()
        // Complete a user-confirmed bridge batch interrupted between its persisted
        // journal and the legacy app/widget keys. No automatic network writes.
        if let pending = sharedDefaults.data(forKey: "mcpPendingCommit"),
           let commit = try? decoder.decode(MCPExpenseCommit.self, from: pending) {
            try? persistMCPCommit(commit)
        }
        
        if let expensesData = sharedDefaults.data(forKey: "expenses"),
           let decodedExpenses = try? decoder.decode([Expense].self, from: expensesData) {
            self.expenses = decodedExpenses
        }
        
        if let userData = sharedDefaults.data(forKey: "user"),
           let decodedUser = try? decoder.decode(User.self, from: userData) {
            self.user = decodedUser
        }
        
        if let deletedExpensesData = sharedDefaults.data(forKey: "archivedExpenses"),
           let decodedDeletedExpenses = try? decoder.decode([ArchivedExpense].self, from: deletedExpensesData) {
            self.deletedExpenses = decodedDeletedExpenses
        }
        
        if let categoryBudgetsData = sharedDefaults.data(forKey: "categoryBudgets"),
           let decodedCategoryBudgets = try? decoder.decode([CategoryBudget].self, from: categoryBudgetsData) {
            self.categoryBudgets = decodedCategoryBudgets
        }
        
        if let spendingGoalsData = sharedDefaults.data(forKey: "spendingGoals"),
           let decodedSpendingGoals = try? decoder.decode([SpendingGoal].self, from: spendingGoalsData) {
            self.spendingGoals = decodedSpendingGoals
        }
        
        if let monthlySalariesData = sharedDefaults.data(forKey: "monthlySalaries"),
           let decodedMonthlySalaries = try? decoder.decode([MonthlySalary].self, from: monthlySalariesData) {
            self.monthlySalaries = decodedMonthlySalaries
        }
        
        if let recurringExpensesData = sharedDefaults.data(forKey: "recurringExpenses"),
           let decodedRecurringExpenses = try? decoder.decode([RecurringExpense].self, from: recurringExpensesData) {
            self.recurringExpenses = decodedRecurringExpenses
        }
        
        if let learnedPatternsData = sharedDefaults.data(forKey: "learnedPatterns"),
           let decodedLearnedPatterns = try? decoder.decode([LearnedPattern].self, from: learnedPatternsData) {
            self.learnedPatterns = decodedLearnedPatterns
        }
        
        if let userCategoriesData = sharedDefaults.data(forKey: "userCategories"),
           let decodedUserCategories = try? decoder.decode([UserCategory].self, from: userCategoriesData) {
            self.userCategories = decodedUserCategories
        }

        if let savedDataLastChangedAt = sharedDefaults.object(forKey: "dataLastChangedAt") as? Date {
            self.dataLastChangedAt = savedDataLastChangedAt
        }
        
        // No longer auto-creating default categories.
        // Categories must be explicitly created by the user or imported.
        
        // Load custom date range
        if let savedStartDate = sharedDefaults.object(forKey: "customStartDate") as? Date {
            self.customStartDate = savedStartDate
        }
        if let savedEndDate = sharedDefaults.object(forKey: "customEndDate") as? Date {
            self.customEndDate = savedEndDate
        }
        
        // Rebuild patterns from recent expenses on app launch
        rebuildLearnedPatternsFromRecentExpenses()
    }

    func reloadFromSharedStorage() {
        loadData()
        // Intents and the MCP bridge can write the shared keys outside saveData().
        onLocalDataPersisted?()
    }

    // MARK: - Explicit MCP file exchange

    private var mcpLedgerId: String {
        if let value = sharedDefaults.string(forKey: "mcpLedgerId"), UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        sharedDefaults.set(value, forKey: "mcpLedgerId")
        return value
    }

    private var mcpAppliedOperations: [String: String] {
        sharedDefaults.dictionary(forKey: "mcpAppliedOperations") as? [String: String] ?? [:]
    }

    private func mcpRecord(_ expense: Expense) throws -> MCPExpenseRecord {
        guard expense.amount.isFinite,
              let amount = Decimal(string: String(expense.amount), locale: MCPExpenseExchange.locale) else {
            throw MCPExpenseExchangeError.invalidRecord
        }
        return MCPExpenseRecord(
            id: expense.id.uuidString.lowercased(), title: expense.title,
            amount: MCPExpenseExchange.canonicalAmount(amount),
            categoryId: expense.categoryId.uuidString.lowercased(),
            date: MCPExpenseExchange.dateFormatter.string(from: expense.date)
        )
    }

    private func mcpRecord(_ archived: ArchivedExpense) throws -> MCPExpenseRecord {
        var expense = Expense(title: archived.title, amount: archived.amount,
                              categoryId: archived.categoryId, date: archived.date)
        expense.id = archived.id
        return try mcpRecord(expense)
    }

    @MainActor
    func exportMCPSnapshot() throws -> Data {
        reloadFromSharedStorage()
        let categories = userCategories.map {
            MCPExchangeCategory(id: $0.id.uuidString.lowercased(), name: $0.name,
                                iconSystemName: $0.iconSystemName, colorName: $0.colorName)
        }
        let ids = Set(categories.map(\.id))
        guard categories.count <= 1_000,
              ids.count == categories.count,
              categories.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.unicodeScalars.count <= 100 }),
              expenses.allSatisfy({ ids.contains($0.categoryId.uuidString.lowercased()) }),
              deletedExpenses.allSatisfy({ ids.contains($0.categoryId.uuidString.lowercased()) }) else {
            throw MCPExpenseExchangeError.missingCategory
        }
        let snapshot = MCPExchangeSnapshot(
            schemaVersion: 1, ledgerId: mcpLedgerId, currency: user.currency.rawValue,
            timeZone: TimeZone.current.identifier, categories: categories,
            expenses: try expenses.map { try mcpRecord($0).validated(categoryIds: ids) },
            archivedExpenses: try deletedExpenses.map { try mcpRecord($0).validated(categoryIds: ids) },
            appliedOperationIds: mcpAppliedOperations.keys.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    @MainActor
    func previewMCPChanges(_ document: MCPExpenseOperationsDocument) throws -> MCPExpenseExchangePlan {
        try MCPExpenseExchange.plan(
            document: document, ledgerId: mcpLedgerId, currency: user.currency.rawValue,
            categoryIds: Set(userCategories.map { $0.id.uuidString.lowercased() }),
            expenses: expenses.map { try mcpRecord($0) },
            archivedExpenses: deletedExpenses.map { try mcpRecord($0) },
            appliedOperations: mcpAppliedOperations
        )
    }

    @MainActor
    @discardableResult
    func applyMCPChanges(_ document: MCPExpenseOperationsDocument) throws -> Int {
        reloadFromSharedStorage()
        let plan = try previewMCPChanges(document)
        guard !plan.changes.isEmpty else { return 0 }
        let existing = Dictionary(expenses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func localExpense(_ record: MCPExpenseRecord) throws -> Expense {
            guard let id = UUID(uuidString: record.id), let category = UUID(uuidString: record.categoryId),
                  let amount = Double(record.amount),
                  let date = MCPExpenseExchange.dateFormatter.date(from: record.date) else {
                throw MCPExpenseExchangeError.invalidRecord
            }
            var expense = Expense(title: record.title, amount: amount, categoryId: category,
                                  date: date, notionId: existing[id]?.notionId)
            expense.id = id
            guard try mcpRecord(expense).amount == record.amount else { throw MCPExpenseExchangeError.invalidRecord }
            return expense
        }
        let updatedExpenses = try plan.expenses.map(localExpense)
        let updatedArchived = try plan.archivedExpenses.map { record -> ArchivedExpense in
            if let previous = deletedExpenses.first(where: { $0.id.uuidString.lowercased() == record.id }),
               try mcpRecord(previous) == record { return previous }
            return ArchivedExpense(from: try localExpense(record))
        }
        let commit = MCPExpenseCommit(ledgerId: mcpLedgerId, expenses: updatedExpenses,
                                     archivedExpenses: updatedArchived, appliedOperations: plan.appliedOperations)
        sharedDefaults.set(try JSONEncoder().encode(commit), forKey: "mcpPendingCommit")
        guard flushMCPStorage() else {
            sharedDefaults.removeObject(forKey: "mcpPendingCommit")
            throw MCPExpenseExchangeError.storageFailure
        }
        try persistMCPCommit(commit)
        expenses = updatedExpenses
        deletedExpenses = updatedArchived
        rebuildLearnedPatternsFromRecentExpenses()
        saveData()
        return plan.changes.count
    }

    private func persistMCPCommit(_ commit: MCPExpenseCommit) throws {
        // Values were encoded successfully before the journal was written.
        let encoder = JSONEncoder()
        guard let active = try? encoder.encode(commit.expenses),
              let archived = try? encoder.encode(commit.archivedExpenses) else { throw MCPExpenseExchangeError.storageFailure }
        sharedDefaults.set(active, forKey: "expenses")
        sharedDefaults.set(archived, forKey: "archivedExpenses")
        sharedDefaults.set(commit.ledgerId, forKey: "mcpLedgerId")
        sharedDefaults.set(commit.appliedOperations, forKey: "mcpAppliedOperations")
        sharedDefaults.set(Date(), forKey: "dataLastChangedAt")
        guard flushMCPStorage() else { throw MCPExpenseExchangeError.storageFailure }
        sharedDefaults.removeObject(forKey: "mcpPendingCommit")
    }

    // MARK: - iCloud Sync

    /// The synced subset of state (learned patterns and UI-only values stay local).
    var cloudSyncDataset: CloudSyncDataset {
        CloudSyncDataset(
            expenses: expenses,
            deletedExpenses: deletedExpenses,
            userCategories: userCategories,
            categoryBudgets: categoryBudgets,
            spendingGoals: spendingGoals,
            monthlySalaries: monthlySalaries,
            recurringExpenses: recurringExpenses,
            user: user
        )
    }

    /// Applies merged iCloud changes with one assignment per collection and one save, like
    /// `applyMCPChanges`. Observers (widget, Notion sync) see a single ordinary local change.
    /// No gamification, MCP receipts or recurring processing run here, and the save does
    /// not call back into iCloud sync, so remote changes are never echoed back.
    func applyCloudSyncDataset(_ dataset: CloudSyncDataset) {
        isApplyingRemoteSnapshot = true
        defer { isApplyingRemoteSnapshot = false }
        expenses = dataset.expenses
        deletedExpenses = dataset.deletedExpenses
        userCategories = dataset.userCategories
        categoryBudgets = dataset.categoryBudgets
        spendingGoals = dataset.spendingGoals
        monthlySalaries = dataset.monthlySalaries
        recurringExpenses = dataset.recurringExpenses
        user = dataset.user
        rebuildLearnedPatternsFromRecentExpenses()
        saveData()
    }

    // MARK: - Expense Management

    // Voice review must not claim success before the expense key is persisted.
    // Its stable draft UUID also makes repeated Save taps safe.
    func addReviewedVoiceExpense(_ expense: Expense, currency: String) throws {
        guard Thread.isMainThread, currency == user.currency.rawValue,
              expense.amount.isFinite, expense.amount > 0,
              !expense.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              userCategories.contains(where: { $0.id == expense.categoryId }) else {
            throw VoiceExpenseSaveError.invalidExpense
        }
        if let existing = expenses.first(where: { $0.id == expense.id }) {
            guard existing == expense else { throw VoiceExpenseSaveError.invalidExpense }
            return
        }
        let next = expenses + [expense]
        let encoded = try JSONEncoder().encode(next)
        let previous = sharedDefaults.data(forKey: "expenses")
        sharedDefaults.set(encoded, forKey: "expenses")
        guard flushMCPStorage() else {
            if let previous { sharedDefaults.set(previous, forKey: "expenses") }
            else { sharedDefaults.removeObject(forKey: "expenses") }
            _ = flushMCPStorage()
            throw VoiceExpenseSaveError.storageFailure
        }
        expenses = next
        dataLastChangedAt = Date()
        sharedDefaults.set(dataLastChangedAt, forKey: "dataLastChangedAt")
        // A later complete save will encode the same already-persisted expense.
        updateLearnedPatterns(for: expense)
        gamificationManager.recordExpense()
        WidgetCenter.shared.reloadAllTimelines()
        onLocalDataPersisted?()
    }
    
    func addExpense(_ expense: Expense) {
        // Ensure this runs on main thread to avoid SwiftUI threading issues
        if Thread.isMainThread {
            addExpenseInternal(expense)
        } else {
            DispatchQueue.main.async {
                self.addExpenseInternal(expense)
            }
        }
    }

    func addExpensesBatch(_ newExpenses: [Expense]) {
        expenses.append(contentsOf: newExpenses)
        saveData()
        rebuildLearnedPatternsFromRecentExpenses()
    }

    private func addExpenseInternal(_ expense: Expense) {
        expenses.append(expense)
        // updateLearnedPatterns persists everything (expense included); a second full
        // saveData() here re-encoded every collection twice per added expense.
        updateLearnedPatterns(for: expense)
        // Gamification tracking
        gamificationManager.recordExpense()
    }
    
    func updateExpense(_ expense: Expense) {
        if let index = expenses.firstIndex(where: { $0.id == expense.id }) {
            expenses[index] = expense
            saveData()
        }
    }
    
    func deleteExpense(_ expense: Expense) {
        expenses.removeAll { $0.id == expense.id }
        saveData()
    }
    
    func moveToDeletedExpenses(_ expense: Expense) {
        let deletedExpense = ArchivedExpense(from: expense)
        deletedExpenses.append(deletedExpense)
        expenses.removeAll { $0.id == expense.id }
        saveData()
    }
    
    /// Archives several expenses with a single save.
    func moveToDeletedExpenses(_ toArchive: [Expense]) {
        guard !toArchive.isEmpty else { return }
        let ids = Set(toArchive.map(\.id))
        deletedExpenses.append(contentsOf: toArchive.map { ArchivedExpense(from: $0) })
        expenses.removeAll { ids.contains($0.id) }
        saveData()
    }

    func restoreExpense(_ deletedExpense: ArchivedExpense) {
        restoreExpenses(ids: [deletedExpense.id])
    }

    /// Restores archived expenses (e.g. an undo after a bulk delete) with a single save.
    /// Keeps the original id and Notion link; ids that are already active are left archived.
    func restoreExpenses(ids: Set<UUID>) {
        let activeIds = Set(expenses.map(\.id))
        let toRestore = deletedExpenses.filter { ids.contains($0.id) && !activeIds.contains($0.id) }
        guard !toRestore.isEmpty else { return }
        let restoredIds = Set(toRestore.map(\.id))
        expenses.append(contentsOf: toRestore.map { archived in
            var expense = Expense(
                title: archived.title,
                amount: archived.amount,
                categoryId: archived.categoryId,
                date: archived.date,
                notionId: archived.notionId
            )
            expense.id = archived.id
            return expense
        })
        deletedExpenses.removeAll { restoredIds.contains($0.id) }
        saveData()
    }
    
    func permanentlyDeleteExpense(_ deletedExpense: ArchivedExpense) {
        deletedExpenses.removeAll { $0.id == deletedExpense.id }
        saveData()
    }
    
    // MARK: - Today's Expenses
    
    func getTodaysExpenses() -> [Expense] {
        let calendar = Calendar.current
        let today = Date()
        return expenses.filter { calendar.isDate($0.date, equalTo: today, toGranularity: .day) }
            .sorted { $0.date > $1.date }
    }
    
    func getTodaysExpensesTotal() -> Double {
        let todaysExpenses = getTodaysExpenses()
        return todaysExpenses.reduce(0) { $0 + $1.amount }
    }
    
    // MARK: - Other Methods (keeping existing functionality)
    
    func getTotalExpenses() -> Double {
        return expenses.reduce(0) { $0 + $1.amount }
    }

    func getCurrentMonthExpenses(on date: Date = Date()) -> [Expense] {
        let interval = BudgetPeriodCalculator.monthInterval(containing: date)
        return BudgetPeriodCalculator.expenses(expenses, in: interval)
    }

    func getCurrentMonthExpensesTotal(on date: Date = Date()) -> Double {
        let interval = BudgetPeriodCalculator.monthInterval(containing: date)
        return BudgetPeriodCalculator.total(for: expenses, in: interval)
    }
    
    func getCurrentMonthSalary() -> Double {
        let calendar = Calendar.current
        let currentDate = Date()
        let currentMonth = calendar.component(.month, from: currentDate)
        let currentYear = calendar.component(.year, from: currentDate)
        
        return getSalaryForMonth(month: currentMonth, year: currentYear)
    }
    
    func getSalaryForMonth(month: Int, year: Int) -> Double {
        if let salary = monthlySalaries.first(where: { $0.month == month && $0.year == year }) {
            return salary.amount
        }
        return 0.0
    }
    
    func getRemainingBudget() -> Double {
        let currentSalary = getCurrentMonthSalary()
        return currentSalary - getCurrentMonthExpensesTotal()
    }

    func getSpendableTodaySnapshot(on date: Date = Date()) -> SpendableTodaySnapshot {
        BudgetPeriodCalculator.spendableToday(
            monthlyIncome: getCurrentMonthSalary(),
            expenses: expenses,
            recurringExpenses: recurringExpenses,
            on: date
        )
    }
    
    func getExpensesByCategory() -> [UserCategory: Double] {
        var categoryTotals: [UserCategory: Double] = [:]
        
        for expense in expenses {
            let category = resolveCategory(id: expense.categoryId)
            if let existingTotal = categoryTotals[category] {
                categoryTotals[category] = existingTotal + expense.amount
            } else {
                categoryTotals[category] = expense.amount
            }
        }
        
        return categoryTotals
    }
    
    func updateUser(_ newUser: User) {
        self.user = newUser
        saveData()
    }
    
    func addCategoryBudget(_ budget: CategoryBudget) {
        categoryBudgets.append(budget)
        saveData()
    }
    
    func updateCategoryBudget(_ budget: CategoryBudget) {
        if let index = categoryBudgets.firstIndex(where: { $0.id == budget.id }) {
            categoryBudgets[index] = budget
            saveData()
        }
    }
    
    func deleteCategoryBudget(_ budget: CategoryBudget) {
        categoryBudgets.removeAll { $0.id == budget.id }
        saveData()
    }
    
    func addSpendingGoal(_ goal: SpendingGoal) {
        spendingGoals.append(goal)
        saveData()
    }
    
    func updateSpendingGoal(_ goal: SpendingGoal) {
        if let index = spendingGoals.firstIndex(where: { $0.id == goal.id }) {
            spendingGoals[index] = goal
            saveData()
        }
    }
    
    func deleteSpendingGoal(_ goal: SpendingGoal) {
        spendingGoals.removeAll { $0.id == goal.id }
        saveData()
    }
    
    func addMonthlySalary(_ salary: MonthlySalary) {
        if let existingIndex = monthlySalaries.firstIndex(where: { $0.month == salary.month && $0.year == salary.year }) {
            monthlySalaries[existingIndex] = salary
        } else {
            monthlySalaries.append(salary)
        }
        saveData()
    }
    
    func setSalaryForMonth(year: Int, month: Int, amount: Double) {
        // Remove existing salary for this month if it exists
        monthlySalaries.removeAll { $0.year == year && $0.month == month }
        
        // Add new salary
        let newSalary = MonthlySalary(year: year, month: month, amount: amount, currency: user.currency)
        monthlySalaries.append(newSalary)
        
        saveData()
    }
    
    func deleteMonthlySalary(_ salary: MonthlySalary) {
        monthlySalaries.removeAll { $0.id == salary.id }
        saveData()
    }
    
    func addRecurringExpense(_ expense: RecurringExpense) {
        recurringExpenses.append(expense)
        saveData()
        processRecurringExpenses()
    }
    
    func updateRecurringExpense(_ expense: RecurringExpense, resumedOn today: Date = Date(), calendar: Calendar = .current) {
        guard let index = recurringExpenses.firstIndex(where: { $0.id == expense.id }) else { return }
        let stored = recurringExpenses[index]
        var updated = expense
        // An edit sheet carries the cursor from when it opened; processing may have moved it since.
        updated.lastProcessedDate = [stored.lastProcessedDate, expense.lastProcessedDate].compactMap { $0 }.max()
        let isResuming = !stored.isActive && expense.isActive
        // A new start day or frequency on a bill that already charged applies from today;
        // otherwise past dates of the new schedule would be recorded as fresh charges.
        let scheduleChanged = stored.recurrenceType != expense.recurrenceType
            || calendar.startOfDay(for: stored.startDate) != calendar.startOfDay(for: expense.startDate)
        if isResuming || (scheduleChanged && updated.lastProcessedDate != nil),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: today)) {
            // Resuming continues from today instead of backfilling the paused period.
            updated.lastProcessedDate = max(updated.lastProcessedDate ?? yesterday, yesterday)
        }
        recurringExpenses[index] = updated
        saveData()
        processRecurringExpenses(through: today, calendar: calendar)
    }

    func deleteRecurringExpense(_ expense: RecurringExpense) {
        deleteRecurringExpenses(ids: [expense.id])
    }

    /// Removes the schedules only; expenses they already recorded stay in history.
    func deleteRecurringExpenses(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        recurringExpenses.removeAll { ids.contains($0.id) }
        saveData()
    }
    
    func updateLearnedPatterns(for expense: Expense) {
        // Only rebuild patterns periodically for performance
        // Check if we should rebuild (every 10 expenses or if patterns are empty)
        let shouldRebuild = learnedPatterns.isEmpty || expenses.count % 10 == 0
        
        if shouldRebuild {
            rebuildLearnedPatternsFromRecentExpenses()
        } else {
            // Quick update: just add to existing pattern or create new one
            quickUpdatePattern(for: expense)
        }
        
        saveData()
    }
    
    private func quickUpdatePattern(for expense: Expense) {
        // Check if expense is from last 3 months
        let calendar = Calendar.current
        let threeMonthsAgo = calendar.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        
        guard expense.date >= threeMonthsAgo else {
            return // Don't add patterns for old expenses
        }
        
        // Try to find existing pattern
        if let existingIndex = learnedPatterns.firstIndex(where: { 
            $0.title.lowercased() == expense.title.lowercased()
        }) {
            // Update existing pattern
            learnedPatterns[existingIndex].addCombination(price: expense.amount, categoryId: expense.categoryId)
        } else {
            // Check for similar patterns
            let similarPatterns = learnedPatterns
                .map { pattern in
                    (pattern: pattern, similarity: pattern.similarityScore(with: expense.title))
                }
                .filter { $0.similarity > 0.7 }
                .sorted { $0.similarity > $1.similarity }
            
            if let bestMatch = similarPatterns.first {
                // Update the most similar pattern
                if let index = learnedPatterns.firstIndex(where: { $0.id == bestMatch.pattern.id }) {
                    learnedPatterns[index].addCombination(price: expense.amount, categoryId: expense.categoryId)
                }
            } else {
                // Create new pattern
                let pattern = LearnedPattern(
                    title: expense.title,
                    price: expense.amount,
                    categoryId: expense.categoryId
                )
                learnedPatterns.append(pattern)
            }
        }
    }
    
    // Method to manually refresh patterns (can be called from settings)
    func refreshSmartLearningPatterns() {
        rebuildLearnedPatternsFromRecentExpenses()
        saveData()
    }
    
    private func rebuildLearnedPatternsFromRecentExpenses() {
        // Get expenses from last 3 months
        let calendar = Calendar.current
        let threeMonthsAgo = calendar.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        
        let recentExpenses = expenses.filter { expense in
            expense.date >= threeMonthsAgo
        }
        
        // Clear existing patterns and rebuild from recent expenses
        learnedPatterns.removeAll()
        
        // Group expenses by title (case-insensitive) and build patterns
        var expenseGroups: [String: [Expense]] = [:]
        
        for expense in recentExpenses {
            let normalizedTitle = expense.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            expenseGroups[normalizedTitle, default: []].append(expense)
        }
        
        // Create patterns from grouped expenses
        for (_, expensesForTitle) in expenseGroups {
            guard !expensesForTitle.isEmpty else { continue }
            
            // Use the original case from the most recent expense
            let mostRecentExpense = expensesForTitle.max(by: { $0.date < $1.date }) ?? expensesForTitle.first!
            
            // Create new pattern with the first expense
            var pattern = LearnedPattern(
                title: mostRecentExpense.title,
                price: mostRecentExpense.amount,
                categoryId: mostRecentExpense.categoryId
            )
            
            // Add all other expenses to the pattern
            for expense in expensesForTitle.dropFirst() {
                pattern.addCombination(price: expense.amount, categoryId: expense.categoryId)
            }
            
            learnedPatterns.append(pattern)
        }
        
        // Also check for similar patterns that should be merged
        mergeSimilarPatterns()
    }
    
    private func mergeSimilarPatterns() {
        var indicesToRemove: Set<Int> = []
        
        for i in 0..<learnedPatterns.count {
            guard !indicesToRemove.contains(i) else { continue }
            
            for j in (i+1)..<learnedPatterns.count {
                guard !indicesToRemove.contains(j) else { continue }
                
                let similarity = learnedPatterns[i].similarityScore(with: learnedPatterns[j].title)
                
                // Merge patterns with high similarity (>0.8)
                if similarity > 0.8 {
                    // Merge pattern j into pattern i, keeping real prices (merging with price 0
                    // made "0" the most-used price and the suggested amount).
                    for combination in learnedPatterns[j].combinations {
                        for _ in 0..<combination.frequency {
                            learnedPatterns[i].addCombination(price: combination.price, categoryId: combination.categoryId)
                        }
                    }
                    
                    // Mark pattern j for removal
                    indicesToRemove.insert(j)
                }
            }
        }
        
        // Remove merged patterns (in reverse order to maintain indices)
        for index in indicesToRemove.sorted(by: >) {
            learnedPatterns.remove(at: index)
        }
    }
    
    func getSmartSuggestions(for title: String) -> [LearnedPattern] {
        // Filter patterns by similarity score
        let similarPatterns = learnedPatterns
            .map { pattern in
                (pattern: pattern, similarity: pattern.similarityScore(with: title))
            }
            .filter { $0.similarity > 0.1 } // Lower threshold for more sensitive matching
            .sorted { $0.similarity > $1.similarity }
            .prefix(5)
            .map { $0.pattern }
        
        // If no similar patterns found, fall back to old method
        if similarPatterns.isEmpty {
            return learnedPatterns
                .filter { $0.title.lowercased().contains(title.lowercased()) || title.lowercased().contains($0.title.lowercased()) }
                .sorted { $0.totalFrequency > $1.totalFrequency }
                .prefix(3)
                .map { $0 }
        }
        
        return Array(similarPatterns)
    }
    
    // New method: Get category prediction for a title
    func getCategoryPrediction(for title: String) -> (category: UserCategory, confidence: Double)? {
        let suggestions = getSmartSuggestions(for: title)
        
        guard !suggestions.isEmpty else { return nil }
        
        // Calculate weighted category prediction
        var categoryScores: [UUID: Double] = [:]
        
        for suggestion in suggestions {
            let similarity = suggestion.similarityScore(with: title)
            let confidence = suggestion.categoryConfidence
            
            // Weight by similarity and confidence
            let weight = similarity * confidence
            
            for categoryFreq in suggestion.categoryFrequencies {
                let score = Double(categoryFreq.frequency) * weight
                categoryScores[categoryFreq.categoryId, default: 0.0] += score
            }
        }
        
        // Find the category with highest score
        guard let bestCategoryId = categoryScores.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        
        // Calculate overall confidence
        let totalScore = categoryScores.values.reduce(0, +)
        let confidence = totalScore > 0 ? categoryScores[bestCategoryId]! / totalScore : 0.0
        
        let category = resolveCategory(id: bestCategoryId)
        return (category: category, confidence: min(confidence, 1.0))
    }
    
    // New method: Get top category suggestions for a title
    func getTopCategorySuggestions(for title: String, limit: Int = 3) -> [(category: UserCategory, confidence: Double)] {
        let suggestions = getSmartSuggestions(for: title)
        
        guard !suggestions.isEmpty else { return [] }
        
        // Calculate weighted category scores
        var categoryScores: [UUID: Double] = [:]
        
        for suggestion in suggestions {
            let similarity = suggestion.similarityScore(with: title)
            let confidence = suggestion.categoryConfidence
            
            let weight = similarity * confidence
            
            for categoryFreq in suggestion.categoryFrequencies {
                let score = Double(categoryFreq.frequency) * weight
                categoryScores[categoryFreq.categoryId, default: 0.0] += score
            }
        }
        
        // Sort by score and return top categories
        let totalScore = categoryScores.values.reduce(0, +)
        
        // Patterns can still reference a deleted category; resolveCategory would hand back a fresh
        // "Other" with a new id that the Add Expense form could select and save as an orphan.
        return categoryScores
            .compactMap { (id, score) -> (category: UserCategory, confidence: Double)? in
                guard let category = getCategory(id: id) else { return nil }
                let confidence = totalScore > 0 ? score / totalScore : 0.0
                return (category: category, confidence: min(confidence, 1.0))
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(limit)
            .map { (category: $0.category, confidence: $0.confidence) }
    }
    
    // Enhanced method: Get smart suggestions with category focus
    func getCategoryFocusedSuggestions(for title: String) -> [LearnedPattern] {
        let suggestions = getSmartSuggestions(for: title)
        
        // Sort by category confidence and similarity
        return suggestions.sorted { pattern1, pattern2 in
            let similarity1 = pattern1.similarityScore(with: title)
            let similarity2 = pattern2.similarityScore(with: title)
            
            let score1 = similarity1 * pattern1.categoryConfidence
            let score2 = similarity2 * pattern2.categoryConfidence
            
            if abs(score1 - score2) < 0.1 {
                // If scores are close, prefer more recent patterns
                return pattern1.lastUsed > pattern2.lastUsed
            }
            
            return score1 > score2
        }
    }
    
    func clearAllData() {
        expenses.removeAll()
        user = User(currency: .usd)
        deletedExpenses.removeAll()
        categoryBudgets.removeAll()
        spendingGoals.removeAll()
        monthlySalaries.removeAll()
        recurringExpenses.removeAll()
        learnedPatterns.removeAll()
        userCategories.removeAll()
        selectedTimePeriod = .currentMonth
        customStartDate = Date()
        customEndDate = customStartDate
        sharedDefaults.removeObject(forKey: "openAddExpense")
        sharedDefaults.removeObject(forKey: "mcpPendingCommit")
        sharedDefaults.removeObject(forKey: "mcpAppliedOperations")
        sharedDefaults.removeObject(forKey: "mcpLedgerId")
        activityManager.reset()
        saveData()
    }
    
    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            self.cleanupExpiredDeletedExpenses()
            self.processRecurringExpenses()
        }
        // The hourly timer can lag a new day by up to an hour, and it does not fire while the app is
        // suspended; MainTabView also processes on every scenePhase `.active`.
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.processRecurringExpenses()
        }
    }

    private func cleanupExpiredDeletedExpenses() {
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        
        deletedExpenses.removeAll { deletedExpense in
            calendar.isDate(deletedExpense.archivedDate, inSameDayAs: thirtyDaysAgo) ||
            deletedExpense.archivedDate < thirtyDaysAgo
        }
        saveData()
    }
    
    func processRecurringExpenses(through date: Date = Date(), calendar: Calendar = .current) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.processRecurringExpenses(through: date, calendar: calendar)
            }
            return
        }

        var generated: [Expense] = []
        var cursorMoved = false
        // Occurrence ids are deterministic, so a charge another device already recorded
        // (and iCloud delivered, active or Deleted) is not recorded a second time.
        var knownIds = Set(expenses.map(\.id)).union(deletedExpenses.map(\.id))
        for index in recurringExpenses.indices {
            let recurring = recurringExpenses[index]
            let dueDates = recurring.dueDates(through: date, calendar: calendar)
            guard let lastDueDate = dueDates.last else { continue }
            for dueDate in dueDates {
                var expense = Expense(title: recurring.title, amount: recurring.amount,
                                      categoryId: recurring.categoryId, date: dueDate)
                expense.id = recurring.occurrenceExpenseID(for: dueDate, calendar: calendar)
                if knownIds.insert(expense.id).inserted { generated.append(expense) }
            }
            recurringExpenses[index].lastProcessedDate = lastDueDate
            cursorMoved = true
        }
        guard !generated.isEmpty else {
            if cursorMoved { saveData() }
            return
        }
        // Persist the occurrence cursors and their records together, before another refresh.
        addExpensesBatch(generated)
    }
    
    // MARK: - Manager Access
    
    var deleteButtonManager: DeleteButtonManager {
        return DeleteButtonManager.shared
    }
    
    var tabManager: TabManager {
        return TabManager.shared
    }
    
    var gamificationManager: GamificationManager {
        return activityManager
    }
    
    // MARK: - Deleted Expenses Helper
    
    func getDaysRemainingForExpense(_ deletedExpense: ArchivedExpense) -> Int {
        let calendar = Calendar.current
        let thirtyDaysAfterArchiving = calendar.date(byAdding: .day, value: 30, to: deletedExpense.archivedDate) ?? Date()
        let today = Date()
        
        let daysRemaining = calendar.dateComponents([.day], from: today, to: thirtyDaysAfterArchiving).day ?? 0
        return max(0, daysRemaining)
    }
    
    func checkBudgetAlerts() -> [String] {
        var alerts: [String] = []
        let currentMonthExpenses = getCurrentMonthExpenses()
        
        for budget in categoryBudgets where budget.isEnabled && budget.amount > 0 {
            let categoryExpenses = currentMonthExpenses.filter { $0.categoryId == budget.categoryId }
            let totalSpent = categoryExpenses.reduce(0) { $0 + $1.amount }
            
            let category = resolveCategory(id: budget.categoryId)
            
            if totalSpent > budget.amount {
                let overspent = totalSpent - budget.amount
                alerts.append("Over budget for \(category.name) by \(CurrencyFormatter.format(overspent, currency: user.currency))")
            } else if totalSpent > budget.amount * 0.8 {
                let remaining = budget.amount - totalSpent
                alerts.append("Close to budget limit for \(category.name). \(CurrencyFormatter.format(remaining, currency: user.currency)) remaining")
            }
        }
        
        return alerts
    }
    
    func updateSpendingGoalProgress() {
        guard !spendingGoals.isEmpty else { return }

        let totalsByCategory = expenses.reduce(into: [UUID: Double]()) { totals, expense in
            totals[expense.categoryId, default: 0] += expense.amount
        }
        var updatedGoals = spendingGoals
        var didChange = false

        for index in updatedGoals.indices {
            let goal = updatedGoals[index]
            let totalSpent = totalsByCategory[goal.categoryId, default: 0]
            guard updatedGoals[index].currentAmount != totalSpent else { continue }
            updatedGoals[index].currentAmount = totalSpent
            didChange = true
        }

        if didChange {
            spendingGoals = updatedGoals
            saveData()
        }
    }
    
    func getRecurringExpenseNotifications() -> [RecurringExpenseNotification] {
        // Overdue (missed a past day) first, then oldest pending charge first.
        recurringExpenses
            .filter { $0.shouldCreateExpense(on: Date()) }
            .sorted { $0.nextDueDate < $1.nextDueDate }
            .map { RecurringExpenseNotification(recurringExpense: $0, type: $0.isOverdue ? .overdue : .due) }
    }
    
    func saveBudgets() {
        saveData()
    }
    
    func saveSpendingGoals() {
        saveData()
    }
    
    func updateCurrency(_ currency: Currency) {
        user.currency = currency
        saveData()
    }
    
    func updateLanguage(_ language: Language) {
        user.language = language
        saveData()
    }
    
    // MARK: - User Categories
    func addUserCategory(_ category: UserCategory) {
        // Prevent duplicates by name (case-insensitive)
        if !userCategories.contains(where: { $0.name.lowercased() == category.name.lowercased() }) {
            userCategories.append(category)
            saveData()
        }
    }
    
    func updateUserCategory(_ category: UserCategory) {
        if let index = userCategories.firstIndex(where: { $0.id == category.id }) {
            userCategories[index] = category
            saveData()
        }
    }
    
    func deleteUserCategory(_ category: UserCategory) {
        userCategories.removeAll { $0.id == category.id }
        saveData()
    }
    
    func renameUserCategory(_ category: UserCategory, to newName: String) {
        guard let index = userCategories.firstIndex(where: { $0.id == category.id }) else { return }
        userCategories[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        saveData()
    }
    
    func updateUserCategoryIcon(_ category: UserCategory, to systemName: String) {
        guard let index = userCategories.firstIndex(where: { $0.id == category.id }) else { return }
        userCategories[index].iconSystemName = systemName
        saveData()
    }
    
    func updateUserCategoryColor(_ category: UserCategory, to colorName: String) {
        guard let index = userCategories.firstIndex(where: { $0.id == category.id }) else { return }
        userCategories[index].colorName = colorName
        saveData()
    }

    func getCategory(id: UUID) -> UserCategory? {
        return userCategories.first(where: { $0.id == id })
    }
    
    func resolveCategory(id: UUID) -> UserCategory {
        if let category = getCategory(id: id) {
            return category
        }

        return UserCategory.createDefault()
    }
    
    func updateCustomDateRange(startDate: Date, endDate: Date) {
        customStartDate = startDate
        customEndDate = endDate
        saveData()
    }
    
    // MARK: - Time Period Filtering
    
    func getFilteredExpenses() -> [Expense] {
        let calendar = Calendar.current
        let now = Date()
        
        switch selectedTimePeriod {
        case .today:
            return expenses.filter { calendar.isDateInToday($0.date) }
        case .thisWeek:
            guard let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) else { return [] }
            return expenses.filter { $0.date >= weekStart && $0.date <= now }
        case .all:
            return expenses
        case .currentMonth:
            return expenses.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
        case .lastMonth:
            guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) else { return [] }
            return expenses.filter { calendar.isDate($0.date, equalTo: lastMonth, toGranularity: .month) }
        case .customMonth:
            return expenses.filter { expense in
                expense.date >= customStartDate && expense.date <= customEndDate
            }
        }
    }
    
    func getTotalExpensesForPeriod() -> Double {
        let filteredExpenses = getFilteredExpenses()
        return filteredExpenses.reduce(0) { $0 + $1.amount }
    }
    
    // MARK: - AI Coach Intelligence
    
    func getUpcomingBillReminders() -> [String] {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysFromNow = calendar.date(byAdding: .day, value: 2, to: now)!
        
        var reminders: [String] = []
        let salary = getCurrentSalaryForPeriod()
        let spent = getTotalExpensesForPeriod()
        let remainingBudget = max(0, salary - spent)
        
        let today = calendar.startOfDay(for: now)
        for bill in recurringExpenses where bill.isActive && !bill.isExpired {
            // Due dates are start-of-day, so compare whole days: a bill due today is not "in the past".
            let nextDate = bill.nextDueDate
            let daysUntil = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: nextDate)).day ?? -1
            guard (0...1).contains(daysUntil), nextDate <= twoDaysFromNow else { continue }

            let budgetAfterBill = remainingBudget - bill.amount
            let format = daysUntil == 0 ? "recurring_reminder_today_format" : "recurring_reminder_tomorrow_format"
            let formattedRemainder = CurrencyFormatter.format(budgetAfterBill, currency: user.currency)
            reminders.append(String(format: format.localized, bill.title, formattedRemainder))
        }
        
        return reminders
    }
    
    func getRemainingBudgetForPeriod() -> Double {
        let salary = getCurrentSalaryForPeriod()
        return max(0, salary - getTotalExpensesForPeriod())
    }
    
    func getCurrentSalaryForPeriod() -> Double {
        switch selectedTimePeriod {
        case .today:
            let monthSalary = getCurrentMonthSalary()
            let daysInMonth = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
            return monthSalary / Double(daysInMonth)
        case .thisWeek:
            let monthSalary = getCurrentMonthSalary()
            let daysInMonth = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30
            return (monthSalary / Double(daysInMonth)) * 7.0
        case .all:
            return monthlySalaries.reduce(0) { $0 + $1.amount }
        case .currentMonth:
            return getCurrentMonthSalary()
        case .lastMonth:
            let calendar = Calendar.current
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
            let year = calendar.component(.year, from: lastMonth)
            let month = calendar.component(.month, from: lastMonth)
            return getSalaryForMonth(month: month, year: year)
        case .customMonth:
            // For custom month, calculate salary based on the date range
            let calendar = Calendar.current
            let startYear = calendar.component(.year, from: customStartDate)
            let startMonth = calendar.component(.month, from: customStartDate)
            let endYear = calendar.component(.year, from: customEndDate)
            let endMonth = calendar.component(.month, from: customEndDate)
            
            // If the range spans multiple months, sum up the salaries
            if startYear == endYear && startMonth == endMonth {
                return getSalaryForMonth(month: startMonth, year: startYear)
            } else {
                // For multi-month ranges, calculate proportional salary
                let daysInRange = calendar.dateComponents([.day], from: customStartDate, to: customEndDate).day ?? 1
                let totalDaysInStartMonth = calendar.range(of: .day, in: .month, for: customStartDate)?.count ?? 30
                let startMonthSalary = getSalaryForMonth(month: startMonth, year: startYear)
                return (startMonthSalary / Double(totalDaysInStartMonth)) * Double(daysInRange)
            }
        }
    }
    
    // Return (Category Name, Amount, Color, Icon)
    // Supports User Categories
    func getCategoryBreakdownForPeriod() -> [(name: String, amount: Double, color: Color, icon: String)] {
        let filteredExpenses = getFilteredExpenses()
        var categoryTotals: [UserCategory: Double] = [:]
        
        for expense in filteredExpenses {
            let category = resolveCategory(id: expense.categoryId)
            categoryTotals[category, default: 0] += expense.amount
        }
        
        return categoryTotals.map { category, amount in
            (name: category.name, amount: amount, color: category.color, icon: category.iconSystemName)
        }.sorted { $0.amount > $1.amount }
    }
    
    func getDailyAverageForPeriod() -> Double {
        let filteredExpenses = getFilteredExpenses()
        guard !filteredExpenses.isEmpty else { return 0 }
        let total = filteredExpenses.reduce(0) { $0 + $1.amount }
        // Average per distinct calendar day that has spending.
        let calendar = Calendar.current
        let distinctDays = Set(filteredExpenses.map { calendar.startOfDay(for: $0.date) }).count
        return total / Double(max(1, distinctDays))
    }

    func getWeeklyAverageForPeriod() -> Double {
        let filteredExpenses = getFilteredExpenses()
        guard !filteredExpenses.isEmpty else { return 0 }
        let total = filteredExpenses.reduce(0) { $0 + $1.amount }
        // Average per distinct calendar week that has spending.
        let calendar = Calendar.current
        let distinctWeeks = Set(filteredExpenses.map { expense -> DateComponents in
            calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: expense.date)
        }).count
        return total / Double(max(1, distinctWeeks))
    }
    
    func getProgressPercentageForPeriod() -> Double {
        let salary = getCurrentSalaryForPeriod()
        guard salary > 0 else { return 0 }
        return min(getTotalExpensesForPeriod() / salary, 1.0)
    }
}
