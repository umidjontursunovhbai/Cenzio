import SwiftUI

struct SupportChatView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationStack {
            List {
                // Summary section
                Section {
                    summaryRow("Spent this month", value: CurrencyFormatter.format(currentMonthTotal, currency: dataManager.user.currency))
                    summaryRow("Daily average", value: CurrencyFormatter.format(dailyAverage, currency: dataManager.user.currency))
                    summaryRow("Transactions", value: "\(currentMonthExpenses.count)")
                    if previousMonthTotal > 0 {
                        let change = ((currentMonthTotal - previousMonthTotal) / previousMonthTotal) * 100
                        let isUp = change >= 0
                        HStack {
                            Text("vs last month")
                                .foregroundStyle(.primary)
                            Spacer()
                            Label(
                                String(format: "%.1f%%", abs(change)),
                                systemImage: isUp ? "arrow.up.right" : "arrow.down.right"
                            )
                            .font(.subheadline)
                            .foregroundStyle(isUp ? Color.green : Color.red)
                        }
                    }
                } header: {
                    Text("This Month")
                }

                // Insights
                Section("Insights") {
                    ForEach(insights) { insight in
                        HStack(alignment: .top, spacing: 12) {
                            HeroIcon(systemName: insight.icon)
                                .foregroundStyle(insight.iconColor)
                                .frame(width: 24)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.title)
                                    .fontWeight(.medium)
                                Text(insight.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }


    // MARK: - Insights

    private var insights: [SpendingInsight] {
        var results: [SpendingInsight] = []

        // 1. Budget alerts — most urgent, shown first
        for budget in dataManager.categoryBudgets.filter({ $0.isEnabled && $0.amount > 0 }) {
            let spent = currentMonthExpenses
                .filter { $0.categoryId == budget.categoryId }
                .reduce(0) { $0 + $1.amount }
            let cat = dataManager.resolveCategory(id: budget.categoryId)
            let fmt = dataManager.user.currency
            if spent > budget.amount {
                results.append(SpendingInsight(
                    id: "over_\(budget.id)",
                    icon: "exclamationmark.circle.fill",
                    iconColor: .red,
                    title: "\(cat.name) is over budget",
                    detail: "Spent \(CurrencyFormatter.format(spent, currency: fmt)) of your \(CurrencyFormatter.format(budget.amount, currency: fmt)) limit",
                    type: .warning
                ))
            } else if spent > budget.amount * 0.8 {
                let remaining = budget.amount - spent
                results.append(SpendingInsight(
                    id: "near_\(budget.id)",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    title: "\(cat.name) is nearing its limit",
                    detail: "\(CurrencyFormatter.format(remaining, currency: fmt)) remaining of \(CurrencyFormatter.format(budget.amount, currency: fmt)) budget",
                    type: .warning
                ))
            }
        }

        // 2. Upcoming recurring bills
        if !upcomingBills.isEmpty {
            let total = upcomingBills.reduce(0) { $0 + $1.amount }
            let names = upcomingBills.prefix(2).map { $0.title }.joined(separator: ", ")
            let extra = upcomingBills.count > 2 ? " +\(upcomingBills.count - 2) more" : ""
            results.append(SpendingInsight(
                id: "bills",
                icon: "calendar.badge.exclamationmark",
                iconColor: .orange,
                title: "Bills due this week",
                detail: "\(names)\(extra) — \(CurrencyFormatter.format(total, currency: dataManager.user.currency)) total",
                type: .warning
            ))
        }

        // 3. Month-over-month trend
        if previousMonthTotal > 0 && currentMonthTotal > 0 {
            let change = ((currentMonthTotal - previousMonthTotal) / previousMonthTotal) * 100
            if change < -10 {
                results.append(SpendingInsight(
                    id: "good_trend",
                    icon: "arrow.down.circle.fill",
                    iconColor: .red,
                    title: "Spending down \(String(format: "%.0f%%", abs(change)))",
                    detail: "You're spending significantly less than last month.",
                    type: .info
                ))
            } else if change > 30 {
                results.append(SpendingInsight(
                    id: "up_trend",
                    icon: "arrow.up.circle.fill",
                    iconColor: .green,
                    title: "Spending up \(String(format: "%.0f%%", change)) this month",
                    detail: "You're spending considerably more than last month.",
                    type: .info
                ))
            }
        }

        // 4. Top category
        if let top = topCategory {
            let pct = currentMonthTotal > 0 ? Int((top.amount / currentMonthTotal) * 100) : 0
            results.append(SpendingInsight(
                id: "top_cat",
                icon: top.icon,
                iconColor: top.color,
                title: "Most spent: \(top.name)",
                detail: "\(CurrencyFormatter.format(top.amount, currency: dataManager.user.currency)) — \(pct)% of this month's total",
                type: .info
            ))
        }

        // 5. Biggest single expense
        if let biggest = currentMonthExpenses.max(by: { $0.amount < $1.amount }) {
            let cat = dataManager.resolveCategory(id: biggest.categoryId)
            let title = biggest.title.isEmpty ? "Unnamed expense" : biggest.title
            results.append(SpendingInsight(
                id: "biggest",
                icon: "dollarsign.circle.fill",
                iconColor: .purple,
                title: "Biggest expense: \(title)",
                detail: "\(CurrencyFormatter.format(biggest.amount, currency: dataManager.user.currency)) in \(cat.name) · \(biggest.date.formatted(date: .abbreviated, time: .omitted))",
                type: .info
            ))
        }

        // 6. Peak spending day of week (needs ≥3 data points per day to be meaningful)
        if let peak = peakDayOfWeek {
            results.append(SpendingInsight(
                id: "peak_day",
                icon: "calendar.badge.clock",
                iconColor: .teal,
                title: "\(peak.name)s are your busiest day",
                detail: "Average \(CurrencyFormatter.format(peak.average, currency: dataManager.user.currency)) per \(peak.name) based on all records",
                type: .info
            ))
        }

        // 7. Empty state
        if results.isEmpty {
            results.append(SpendingInsight(
                id: "empty",
                icon: "chart.bar.doc.horizontal",
                iconColor: Color(.systemGray),
                title: "No insights yet",
                detail: "Add expenses to get personalized spending insights here",
                type: .info
            ))
        }

        return results
    }

    // MARK: - Computed Properties

    private var currentMonthExpenses: [Expense] {
        let calendar = Calendar.current
        return dataManager.expenses.filter {
            calendar.isDate($0.date, equalTo: Date(), toGranularity: .month)
        }
    }

    private var currentMonthTotal: Double {
        currentMonthExpenses.reduce(0) { $0 + $1.amount }
    }

    private var previousMonthTotal: Double {
        let calendar = Calendar.current
        guard let lastMonth = calendar.date(byAdding: .month, value: -1, to: Date()) else { return 0 }
        return dataManager.expenses
            .filter { calendar.isDate($0.date, equalTo: lastMonth, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var dailyAverage: Double {
        let day = max(1, Calendar.current.component(.day, from: Date()))
        return currentMonthTotal / Double(day)
    }

    private var categoriesUsed: Int {
        Set(currentMonthExpenses.map { $0.categoryId }).count
    }

    private var topCategory: (name: String, amount: Double, icon: String, color: Color)? {
        var totals: [UUID: Double] = [:]
        for exp in currentMonthExpenses {
            totals[exp.categoryId, default: 0] += exp.amount
        }
        guard let top = totals.max(by: { $0.value < $1.value }) else { return nil }
        let cat = dataManager.resolveCategory(id: top.key)
        return (cat.name, top.value, cat.iconSystemName, cat.color)
    }

    private var peakDayOfWeek: (name: String, average: Double)? {
        let calendar = Calendar.current
        var dayAmounts: [Int: [Double]] = [:]
        for exp in dataManager.expenses {
            let weekday = calendar.component(.weekday, from: exp.date)
            dayAmounts[weekday, default: []].append(exp.amount)
        }
        guard let peak = dayAmounts.max(by: {
            ($0.value.reduce(0, +) / Double($0.value.count)) <
            ($1.value.reduce(0, +) / Double($1.value.count))
        }), peak.value.count >= 3 else { return nil }
        let avg = peak.value.reduce(0, +) / Double(peak.value.count)
        let names = DateFormatter().weekdaySymbols ?? ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
        return (names[peak.key - 1], avg)
    }

    private var upcomingBills: [RecurringExpense] {
        let now = Date()
        let sevenDaysLater = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return dataManager.recurringExpenses.filter {
            $0.isActive && !$0.isExpired && $0.nextDueDate >= now && $0.nextDueDate <= sevenDaysLater
        }
    }
}

// MARK: - Supporting Types

struct SpendingInsight: Identifiable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let type: InsightType

    enum InsightType {
        case warning, info, positive
    }
}

#Preview {
    SupportChatView()
}
