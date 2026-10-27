import Testing
@testable import SmartSpend

@Suite("Budget goal status")
struct BudgetGoalStatusTests {
    @Test("Disabled or zero limits are untracked")
    func untracked() {
        #expect(BudgetGoalStatus.evaluate(spent: 500, limit: 1000, isEnabled: false) == .noLimit)
        #expect(BudgetGoalStatus.evaluate(spent: 500, limit: 0, isEnabled: true) == .noLimit)
    }

    @Test("Under 80% is on track")
    func onTrack() {
        #expect(BudgetGoalStatus.evaluate(spent: 0, limit: 1000, isEnabled: true) == .onTrack)
        #expect(BudgetGoalStatus.evaluate(spent: 799, limit: 1000, isEnabled: true) == .onTrack)
    }

    @Test("80% up to and including the limit is near limit")
    func nearLimit() {
        #expect(BudgetGoalStatus.evaluate(spent: 800, limit: 1000, isEnabled: true) == .nearLimit)
        #expect(BudgetGoalStatus.evaluate(spent: 1000, limit: 1000, isEnabled: true) == .nearLimit)
    }

    @Test("More than the limit is over budget")
    func overBudget() {
        #expect(BudgetGoalStatus.evaluate(spent: 1000.01, limit: 1000, isEnabled: true) == .overBudget)
    }
}
