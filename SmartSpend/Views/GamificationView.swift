import SwiftUI

struct GamificationView: View {
    @ObservedObject private var gamificationManager = GamificationManager.shared
    @State private var selectedCategory: Achievement.AchievementCategory?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // User Level Section
                    UserLevelCard(userLevel: gamificationManager.userLevel)
                    
                    // Streak Section
                    StreakCard(streak: gamificationManager.expenseStreak)
                    
                    // Recent Achievements
                    if !gamificationManager.recentUnlocks.isEmpty {
                        RecentAchievementsCard(achievements: gamificationManager.recentUnlocks) {
                            gamificationManager.dismissRecentUnlocks()
                        }
                    }
                    
                    // Achievements Section
                    AchievementsSection(
                        achievements: gamificationManager.achievements,
                        selectedCategory: $selectedCategory
                    )
                }
                .padding()
            }
            .appBackdrop()
            .navigationTitle("achievements_title".localized)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                // Update achievements when view appears
                gamificationManager.recordExpense() // This will trigger achievement check
            }
        }
    }
}

// MARK: - User Level Card
struct UserLevelCard: View {
    let userLevel: UserLevel
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "level_format".localized, userLevel.currentLevel))
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(userLevel.levelTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HeroIcon(systemName: userLevel.levelIcon)
                    .font(.system(size: 40))
                    .foregroundColor(.yellow)
            }
            
            VStack(spacing: 8) {
                HStack {
                    Text(String(format: "progress_to_level_format".localized, userLevel.currentLevel + 1))
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Spacer()
                    
                    Text("\(userLevel.currentXP) / \(userLevel.xpForNextLevel - userLevel.totalXP + userLevel.currentXP) XP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                ProgressView(value: userLevel.progressToNextLevel)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .scaleEffect(x: 1, y: 1.5, anchor: .center)
            }
            
            HStack {
                StatItem(title: "total_xp".localized, value: "\(userLevel.totalXP)")
                Spacer()
                StatItem(title: "current_level".localized, value: "\(userLevel.currentLevel)")
            }
        }
        .padding()
        .liquidGlassCard(cornerRadius: 16)
    }
}

// MARK: - Streak Card
struct StreakCard: View {
    let streak: ExpenseStreak
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                HeroIconLabel(title: "expense_streak".localized, systemName: "flame.fill")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                
                Spacer()
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(streak.currentStreak)")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                    
                    Text("current_streak".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(streak.longestStreak)")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("best_streak".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let lastDate = streak.lastExpenseDate {
                HStack {
                    Text("last_tracked".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(RelativeDateTimeFormatter().localizedString(for: lastDate, relativeTo: Date()))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .liquidGlassCard(cornerRadius: 16)
    }
}

// MARK: - Recent Achievements Card
struct RecentAchievementsCard: View {
    let achievements: [Achievement]
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeroIconLabel(title: "recently_unlocked".localized, systemName: "star.fill")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
                
                Spacer()
                
                Button("dismiss".localized, action: onDismiss)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            ForEach(achievements) { achievement in
                HStack {
                    HeroIcon(systemName: achievement.icon)
                        .font(.title2)
                        .foregroundColor(achievement.category.color)
                        .frame(width: 30)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(achievement.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text(achievement.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    HeroIcon(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.yellow.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Achievements Section
struct AchievementsSection: View {
    let achievements: [Achievement]
    @Binding var selectedCategory: Achievement.AchievementCategory?
    
    private var filteredAchievements: [Achievement] {
        if let category = selectedCategory {
            return achievements.filter { $0.category == category }
        }
        return achievements
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("achievements_title".localized)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Menu {
                    Button("all_categories".localized) {
                        selectedCategory = nil
                    }
                    
                    ForEach(Achievement.AchievementCategory.allCases, id: \.self) { category in
                        Button(category.rawValue) {
                            selectedCategory = category
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedCategory?.rawValue ?? "all".localized)
                            .font(.caption)
                        HeroIcon(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundColor(.blue)
                }
            }
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(filteredAchievements) { achievement in
                    AchievementCard(achievement: achievement)
                }
            }
        }
    }
}

// MARK: - Achievement Card
struct AchievementCard: View {
    let achievement: Achievement
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HeroIcon(systemName: achievement.icon)
                    .font(.title2)
                    .foregroundColor(achievement.isUnlocked ? achievement.category.color : .gray)
                
                Spacer()
                
                if achievement.isUnlocked {
                    HeroIcon(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(achievement.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(achievement.isUnlocked ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                
                Text(achievement.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                
                if !achievement.isUnlocked {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(achievement.requirement.progressDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        ProgressView(value: achievement.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: achievement.category.color))
                            .scaleEffect(x: 1, y: 0.8, anchor: .center)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(minHeight: 120)
        // Grid cells stay off glass (many of them): an opaque plate when unlocked,
        // a quieter well when locked.
        .background(
            achievement.isUnlocked ? iOSDesignSystem.elevatedBackground : iOSDesignSystem.insetFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(achievement.isUnlocked ? achievement.category.color.opacity(0.3) : iOSDesignSystem.layerStroke, lineWidth: 1)
        )
    }
}

// MARK: - Stat Item
struct StatItem: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    GamificationView()
}
