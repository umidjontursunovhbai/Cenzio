import SwiftUI

struct SpendingGoalsView: View {
    let goals: [SpendingGoal]
    @ObservedObject private var dataManager = DataManager.shared
    @State private var showingBudgetSettings = false
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HeroIconLabel(title: "Spending Goals", systemName: "target")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Button(action: { showingBudgetSettings = true }) {
                    HeroIcon(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .iOSMinimumTapTarget()
                }
                .liquidGlassButtonStyle()
            }
            
            VStack(spacing: 12) {
                ForEach(goals.prefix(3)) { goal in
                    GoalProgressRow(goal: goal)
                }
                
                if goals.count > 3 {
                    Button(action: { showingBudgetSettings = true }) {
                        HStack {
                            Text("View All Goals (\(goals.count))")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.tint)
                            Spacer()
                            HeroIcon(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
                        .liquidGlassSurface(RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.small, style: .continuous))
                    }
                    .liquidGlassButtonStyle()
                }
            }
        }
        .padding(.vertical, iOSDesignSystem.Spacing.large)
        .padding(.horizontal, iOSDesignSystem.Spacing.screenMargin)
        .liquidGlassCard()
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        .sheet(isPresented: $showingBudgetSettings) {
            BudgetSettingsView()
        }
    }
}

struct GoalProgressRow: View {
    let goal: SpendingGoal
    @ObservedObject private var dataManager = DataManager.shared
    
    private var category: UserCategory {
        dataManager.resolveCategory(id: goal.categoryId)
    }

    private func dashboardAmount(_ amount: Double) -> String {
        let currency = dataManager.user.currency
        if currency == .uzs {
            return CurrencyFormatter.formatCompact(amount, currency: currency)
        }
        return CurrencyFormatter.format(amount, currency: currency)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Category Icon
                HeroIcon(systemName: category.iconSystemName)
                    .font(.caption)
                    .foregroundStyle(category.color)
                    .frame(width: 24, height: 24)
                    .background(category.color.opacity(0.1), in: Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    
                    Text("\(category.name) • Target: \(dashboardAmount(goal.targetAmount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(dashboardAmount(goal.currentAmount))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(goal.isCompleted ? .green : .primary)
                    
                    Text("\(Int(goal.progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(goal.isCompleted ? .green : .blue)
                }
            }
            
            ProgressView(value: goal.progress)
                .progressViewStyle(LinearProgressViewStyle(tint: goal.isCompleted ? .green : .blue))
                .scaleEffect(x: 1, y: 1.5, anchor: .center)
        }
        .padding(.vertical, 4)
    }
}
