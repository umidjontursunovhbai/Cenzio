import Foundation
import SwiftUI

// MARK: - Achievement System
struct Achievement: Identifiable, Codable {
    let id: UUID
    let title: String
    let description: String
    let icon: String
    let category: AchievementCategory
    let requirement: AchievementRequirement
    var isUnlocked: Bool
    var unlockedDate: Date?
    var progress: Double
    
    enum AchievementCategory: String, CaseIterable, Codable {
        case spending = "Spending"
        case saving = "Saving"
        case budgeting = "Budgeting"
        case consistency = "Consistency"
        case milestones = "Milestones"
        
        var color: Color {
            switch self {
            case .spending:
                return .red
            case .saving:
                return .green
            case .budgeting:
                return .blue
            case .consistency:
                return .orange
            case .milestones:
                return .purple
            }
        }
    }
    
    enum AchievementRequirement: Codable {
        case totalExpenses(Int)
        case monthlyExpenses(Int, months: Int)
        case categoriesUsed(Int)
        case savingsGoalReached(Int)
        case budgetStayedUnder(Int, months: Int)
        case expenseStreak(Int) // days
        case recurringExpensesSet(Int)
        case dataExported(Int)
        
        var progressDescription: String {
            switch self {
            case .totalExpenses(let count):
                return "Add \(count) total expenses"
            case .monthlyExpenses(let count, let months):
                return "Add \(count) expenses for \(months) months"
            case .categoriesUsed(let count):
                return "Use \(count) different categories"
            case .savingsGoalReached(let count):
                return "Reach \(count) savings goals"
            case .budgetStayedUnder(_, let months):
                return "Stay under budget for \(months) months"
            case .expenseStreak(let days):
                return "Track expenses for \(days) consecutive days"
            case .recurringExpensesSet(let count):
                return "Set up \(count) recurring expenses"
            case .dataExported(let count):
                return "Export data \(count) times"
            }
        }
    }
    
    init(title: String, description: String, icon: String, category: AchievementCategory, requirement: AchievementRequirement) {
        self.id = UUID()
        self.title = title
        self.description = description
        self.icon = icon
        self.category = category
        self.requirement = requirement
        self.isUnlocked = false
        self.progress = 0.0
    }
    
    mutating func unlock() {
        guard !isUnlocked else { return }
        isUnlocked = true
        unlockedDate = Date()
        progress = 1.0
    }
    
    mutating func updateProgress(_ newProgress: Double) {
        progress = min(1.0, max(0.0, newProgress))
        if progress >= 1.0 && !isUnlocked {
            unlock()
        }
    }
}

// MARK: - Level System
struct UserLevel: Codable {
    var currentLevel: Int = 1
    var currentXP: Int = 0
    var totalXP: Int = 0
    
    var xpForNextLevel: Int {
        return xpRequiredForLevel(currentLevel + 1)
    }
    
    var progressToNextLevel: Double {
        let currentLevelXP = xpRequiredForLevel(currentLevel)
        let nextLevelXP = xpRequiredForLevel(currentLevel + 1)
        let progressXP = totalXP - currentLevelXP
        let requiredXP = nextLevelXP - currentLevelXP
        
        return requiredXP > 0 ? Double(progressXP) / Double(requiredXP) : 0.0
    }
    
    var levelTitle: String {
        switch currentLevel {
        case 1...5:
            return "Expense Tracker"
        case 6...10:
            return "Budget Planner"
        case 11...20:
            return "Savings Expert"
        case 21...35:
            return "Financial Guru"
        case 36...50:
            return "Money Master"
        default:
            return "Finance Legend"
        }
    }
    
    var levelIcon: String {
        switch currentLevel {
        case 1...5:
            return "leaf.fill"
        case 6...10:
            return "chart.line.uptrend.xyaxis"
        case 11...20:
            return "star.fill"
        case 21...35:
            return "crown.fill"
        case 36...50:
            return "diamond.fill"
        default:
            return "trophy.fill"
        }
    }
    
    private func xpRequiredForLevel(_ level: Int) -> Int {
        // Exponential XP curve: each level requires more XP
        return (level - 1) * 100 + (level - 1) * (level - 1) * 25
    }
    
    mutating func addXP(_ amount: Int) {
        currentXP += amount
        totalXP += amount
        
        // Check for level ups
        while currentXP >= xpForNextLevel - xpRequiredForLevel(currentLevel) {
            let overflow = currentXP - (xpForNextLevel - xpRequiredForLevel(currentLevel))
            currentLevel += 1
            currentXP = overflow
        }
    }
}

// MARK: - Streak System
struct ExpenseStreak: Codable {
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var lastExpenseDate: Date?
    
    mutating func recordExpense(on date: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)

        if let lastDate = lastExpenseDate {
            let lastDay = calendar.startOfDay(for: lastDate)
            let daysBetween = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0

            if daysBetween == 1 {
                // Consecutive day
                currentStreak += 1
            } else if daysBetween == 0 {
                // Same calendar day, no change to streak
                return
            } else {
                // Streak broken
                currentStreak = 1
            }
        } else {
            // First expense
            currentStreak = 1
        }

        lastExpenseDate = today
        longestStreak = max(longestStreak, currentStreak)
    }

    mutating func checkStreakValidity() {
        guard let lastDate = lastExpenseDate else { return }

        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: lastDate)
        let today = calendar.startOfDay(for: Date())
        let daysSinceLastExpense = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0

        if daysSinceLastExpense > 1 {
            currentStreak = 0
        }
    }
}

// MARK: - Gamification Manager
class GamificationManager: ObservableObject {
    static let shared = GamificationManager()
    
    @Published var achievements: [Achievement] = []
    @Published var userLevel: UserLevel = UserLevel()
    @Published var expenseStreak: ExpenseStreak = ExpenseStreak()
    @Published var recentUnlocks: [Achievement] = []
    
    private let achievementsKey = "achievements"
    private let userLevelKey = "userLevel"
    private let expenseStreakKey = "expenseStreak"
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadData()
        setupDefaultAchievements()
    }

    /// Clear earned progress in memory and on disk without removing app preferences.
    func reset() {
        achievements = []
        recentUnlocks = []
        userLevel = UserLevel()
        expenseStreak = ExpenseStreak()
        setupDefaultAchievements()
        saveUserLevel()
        saveExpenseStreak()
    }
    
    private func loadData() {
        loadAchievements()
        loadUserLevel()
        loadExpenseStreak()
    }
    
    private func loadAchievements() {
        if let data = defaults.data(forKey: achievementsKey),
           let decoded = try? JSONDecoder().decode([Achievement].self, from: data) {
            achievements = decoded
        }
    }
    
    private func saveAchievements() {
        if let encoded = try? JSONEncoder().encode(achievements) {
            defaults.set(encoded, forKey: achievementsKey)
        }
    }
    
    private func loadUserLevel() {
        if let data = defaults.data(forKey: userLevelKey),
           let decoded = try? JSONDecoder().decode(UserLevel.self, from: data) {
            userLevel = decoded
        }
    }
    
    private func saveUserLevel() {
        if let encoded = try? JSONEncoder().encode(userLevel) {
            defaults.set(encoded, forKey: userLevelKey)
        }
    }
    
    private func loadExpenseStreak() {
        if let data = defaults.data(forKey: expenseStreakKey),
           let decoded = try? JSONDecoder().decode(ExpenseStreak.self, from: data) {
            expenseStreak = decoded
        }
    }
    
    private func saveExpenseStreak() {
        if let encoded = try? JSONEncoder().encode(expenseStreak) {
            defaults.set(encoded, forKey: expenseStreakKey)
        }
    }
    
    // MARK: - Achievement Setup
    
    private func setupDefaultAchievements() {
        guard achievements.isEmpty else { return }
        
        achievements = [
            // Spending Achievements
            Achievement(title: "First Steps", description: "Add your first expense", icon: "1.circle.fill", category: .spending, requirement: .totalExpenses(1)),
            Achievement(title: "Getting Started", description: "Add 10 expenses", icon: "10.circle.fill", category: .spending, requirement: .totalExpenses(10)),
            Achievement(title: "Expense Tracker", description: "Add 50 expenses", icon: "50.circle.fill", category: .spending, requirement: .totalExpenses(50)),
            Achievement(title: "Dedicated User", description: "Add 100 expenses", icon: "100.circle.fill", category: .spending, requirement: .totalExpenses(100)),
            Achievement(title: "Power User", description: "Add 500 expenses", icon: "500.circle.fill", category: .spending, requirement: .totalExpenses(500)),
            
            // Saving Achievements
            Achievement(title: "Goal Setter", description: "Create your first savings goal", icon: "flag.fill", category: .saving, requirement: .savingsGoalReached(1)),
            Achievement(title: "Goal Achiever", description: "Reach 3 savings goals", icon: "target", category: .saving, requirement: .savingsGoalReached(3)),
            Achievement(title: "Savings Master", description: "Reach 10 savings goals", icon: "star.circle.fill", category: .saving, requirement: .savingsGoalReached(10)),
            
            // Budgeting Achievements
            Achievement(title: "Budget Conscious", description: "Stay under budget for 1 month", icon: "checkmark.shield.fill", category: .budgeting, requirement: .budgetStayedUnder(1, months: 1)),
            Achievement(title: "Budget Master", description: "Stay under budget for 3 months", icon: "shield.fill", category: .budgeting, requirement: .budgetStayedUnder(1, months: 3)),
            Achievement(title: "Financial Discipline", description: "Stay under budget for 6 months", icon: "crown.fill", category: .budgeting, requirement: .budgetStayedUnder(1, months: 6)),
            
            // Consistency Achievements
            Achievement(title: "Consistent Tracker", description: "Track expenses for 7 consecutive days", icon: "calendar.badge.checkmark", category: .consistency, requirement: .expenseStreak(7)),
            Achievement(title: "Habit Former", description: "Track expenses for 30 consecutive days", icon: "flame.fill", category: .consistency, requirement: .expenseStreak(30)),
            Achievement(title: "Dedication", description: "Track expenses for 100 consecutive days", icon: "diamond.fill", category: .consistency, requirement: .expenseStreak(100)),
            
            // Milestone Achievements
            Achievement(title: "Category Explorer", description: "Use 5 different expense categories", icon: "tag.circle.fill", category: .milestones, requirement: .categoriesUsed(5)),
            Achievement(title: "Category Master", description: "Use all expense categories", icon: "tags.fill", category: .milestones, requirement: .categoriesUsed(8)),
            Achievement(title: "Automation Expert", description: "Set up 5 recurring expenses", icon: "repeat.circle.fill", category: .milestones, requirement: .recurringExpensesSet(5)),
            Achievement(title: "Data Analyst", description: "Export your data 3 times", icon: "chart.bar.doc.horizontal.fill", category: .milestones, requirement: .dataExported(3)),
        ]
        
        saveAchievements()
    }
    
    // MARK: - Progress Tracking
    
    func recordExpense() {
        expenseStreak.recordExpense()
        saveExpenseStreak()
        
        userLevel.addXP(10) // 10 XP per expense
        saveUserLevel()
        
        checkAchievements()
    }
    
    func recordGoalReached() {
        userLevel.addXP(100) // 100 XP for reaching a goal
        saveUserLevel()
        
        checkAchievements()
    }
    
    func recordBudgetCompliance() {
        userLevel.addXP(50) // 50 XP for staying under budget
        saveUserLevel()
        
        checkAchievements()
    }
    
    func recordRecurringExpenseCreated() {
        userLevel.addXP(25) // 25 XP for setting up recurring expense
        saveUserLevel()
        
        checkAchievements()
    }
    
    func recordDataExport() {
        userLevel.addXP(30) // 30 XP for data export
        saveUserLevel()
        
        checkAchievements()
    }
    
    private func checkAchievements() {
        let dataManager = DataManager.shared
        expenseStreak.checkStreakValidity()
        
        for i in 0..<achievements.count {
            guard !achievements[i].isUnlocked else { continue }
            
            let progress = calculateAchievementProgress(achievements[i].requirement, dataManager: dataManager)
            achievements[i].updateProgress(progress)
            
            if achievements[i].isUnlocked && !recentUnlocks.contains(where: { $0.id == achievements[i].id }) {
                recentUnlocks.append(achievements[i])
                userLevel.addXP(50) // Bonus XP for achievement
            }
        }
        
        saveAchievements()
        saveUserLevel()
    }
    
    private func calculateAchievementProgress(_ requirement: Achievement.AchievementRequirement, dataManager: DataManager) -> Double {
        switch requirement {
        case .totalExpenses(let target):
            return Double(dataManager.expenses.count) / Double(target)
            
        case .monthlyExpenses(let target, _):
            // This would need more complex logic to track monthly consistency
            return Double(dataManager.expenses.count) / Double(target)
            
        case .categoriesUsed(let target):
            let uniqueCategories = Set(dataManager.expenses.map { $0.categoryId })
            return Double(uniqueCategories.count) / Double(target)
            
        case .savingsGoalReached(let target):
            let completedGoals = dataManager.spendingGoals.filter { $0.isCompleted }
            return Double(completedGoals.count) / Double(target)
            
        case .budgetStayedUnder(_, _):
            // Simplified: assume current compliance
            return 0.5 // This would need more complex tracking
            
        case .expenseStreak(let target):
            return Double(expenseStreak.currentStreak) / Double(target)
            
        case .recurringExpensesSet(let target):
            return Double(dataManager.recurringExpenses.count) / Double(target)
            
        case .dataExported(_):
            // This would need to be tracked separately
            return 0.0 // For now, manual tracking required
        }
    }
    
    func dismissRecentUnlocks() {
        recentUnlocks.removeAll()
    }
}
