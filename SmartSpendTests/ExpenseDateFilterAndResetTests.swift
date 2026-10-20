import Foundation
import Testing
@testable import SmartSpend

struct ExpenseDateFilterAndResetTests {
    private func calendar(timeZone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    @Test("This Month excludes both adjacent months, including the next month's boundary")
    func monthBoundaries() throws {
        let calendar = calendar()
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10)))
        let interval = try #require(calendar.dateInterval(of: .month, for: reference))
        #expect(!ExpenseDateFilter.contains(interval.start.addingTimeInterval(-1), in: .month, relativeTo: reference, calendar: calendar))
        #expect(ExpenseDateFilter.contains(interval.start, in: .month, relativeTo: reference, calendar: calendar))
        #expect(ExpenseDateFilter.contains(interval.end.addingTimeInterval(-1), in: .month, relativeTo: reference, calendar: calendar))
        #expect(!ExpenseDateFilter.contains(interval.end, in: .month, relativeTo: reference, calendar: calendar))
    }

    @Test("This Week respects local calendar boundaries across daylight saving")
    func weekBoundaries() throws {
        let calendar = calendar(timeZone: "America/New_York")
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let interval = try #require(calendar.dateInterval(of: .weekOfYear, for: reference))
        #expect(!ExpenseDateFilter.contains(interval.start.addingTimeInterval(-1), in: .weekOfYear, relativeTo: reference, calendar: calendar))
        #expect(ExpenseDateFilter.contains(interval.start, in: .weekOfYear, relativeTo: reference, calendar: calendar))
        #expect(ExpenseDateFilter.contains(interval.end.addingTimeInterval(-1), in: .weekOfYear, relativeTo: reference, calendar: calendar))
        #expect(!ExpenseDateFilter.contains(interval.end, in: .weekOfYear, relativeTo: reference, calendar: calendar))
    }

    @Test("Clear progress removes achievements, XP, streak and pending unlocks after relaunch")
    @MainActor
    func resetPersistsFreshProgress() throws {
        let suiteName = "SmartSpendTests.GamificationReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("uz", forKey: "language")
        var earned = Achievement(title: "Earned", description: "Test", icon: "star", category: .spending, requirement: .totalExpenses(1))
        earned.unlock()
        var level = UserLevel()
        level.addXP(700)
        var streak = ExpenseStreak()
        streak.recordExpense()
        defaults.set(try JSONEncoder().encode([earned]), forKey: "achievements")
        defaults.set(try JSONEncoder().encode(level), forKey: "userLevel")
        defaults.set(try JSONEncoder().encode(streak), forKey: "expenseStreak")
        let manager = GamificationManager(defaults: defaults)
        manager.recentUnlocks = [earned]
        #expect(manager.achievements.first?.isUnlocked == true)
        #expect(manager.userLevel.totalXP == 700)
        manager.reset()
        #expect(manager.recentUnlocks.isEmpty)
        #expect(manager.userLevel.totalXP == 0)
        #expect(manager.expenseStreak.lastExpenseDate == nil)

        let reloaded = GamificationManager(defaults: defaults)
        #expect(!reloaded.achievements.isEmpty)
        #expect(reloaded.achievements.allSatisfy { !$0.isUnlocked && $0.progress == 0 && $0.unlockedDate == nil })
        #expect(reloaded.userLevel.currentLevel == 1)
        #expect(reloaded.userLevel.currentXP == 0)
        #expect(reloaded.userLevel.totalXP == 0)
        #expect(reloaded.expenseStreak.currentStreak == 0)
        #expect(reloaded.expenseStreak.longestStreak == 0)
        #expect(reloaded.expenseStreak.lastExpenseDate == nil)
        #expect(defaults.string(forKey: "language") == "uz")
    }
}
