import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Lightweight mirror types for decoding app data

private let appGroupID = "group.ai.humblebee.smartspend"

private struct WExpense: Codable {
    let amount: Double
    let categoryId: UUID
    let date: Date
}

private struct WUser: Codable {
    let currency: String
}

private struct WCategory: Codable {
    let id: UUID
    let name: String
    let iconSystemName: String
    let colorName: String
}

private struct WMonthlySalary: Codable {
    let month: Int
    let year: Int
    let amount: Double
}

// MARK: - Timeline Entry

struct SmartSpendEntry: TimelineEntry {
    let date: Date
    let todayTotal: Double
    let monthTotal: Double
    let monthlySalary: Double
    let currencyCode: String
    let topCategories: [CategoryRow]

    struct CategoryRow: Identifiable {
        let id: UUID
        let name: String
        let icon: String
        let colorName: String
        let amount: Double
    }

    static var placeholder: SmartSpendEntry {
        SmartSpendEntry(
            date: .now,
            todayTotal: 42.50,
            monthTotal: 350.00,
            monthlySalary: 1200.00,
            currencyCode: "USD",
            topCategories: [
                CategoryRow(id: UUID(), name: "Food", icon: "fork.knife", colorName: "systemGreen", amount: 120),
                CategoryRow(id: UUID(), name: "Transport", icon: "car.fill", colorName: "systemBlue", amount: 80),
                CategoryRow(id: UUID(), name: "Shopping", icon: "bag.fill", colorName: "systemPurple", amount: 65),
            ]
        )
    }
}

// MARK: - Timeline Provider

struct SmartSpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> SmartSpendEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (SmartSpendEntry) -> Void) {
        completion(context.isPreview ? .placeholder : loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SmartSpendEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadEntry() -> SmartSpendEntry {
        let defaults = UserDefaults(suiteName: appGroupID) ?? UserDefaults.standard
        let decoder = JSONDecoder()

        var expenses: [WExpense] = []
        if let data = defaults.data(forKey: "expenses"),
           let decoded = try? decoder.decode([WExpense].self, from: data) {
            expenses = decoded
        }

        var currencyCode = "USD"
        if let data = defaults.data(forKey: "user"),
           let decoded = try? decoder.decode(WUser.self, from: data) {
            currencyCode = decoded.currency
        }

        var categories: [WCategory] = []
        if let data = defaults.data(forKey: "userCategories"),
           let decoded = try? decoder.decode([WCategory].self, from: data) {
            categories = decoded
        }

        var salaries: [WMonthlySalary] = []
        if let data = defaults.data(forKey: "monthlySalaries"),
           let decoded = try? decoder.decode([WMonthlySalary].self, from: data) {
            salaries = decoded
        }

        let calendar = Calendar.current
        let now = Date()
        let nowComponents = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: nowComponents)!

        let todayTotal = expenses
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.amount }

        let monthTotal = expenses
            .filter { $0.date >= startOfMonth }
            .reduce(0) { $0 + $1.amount }

        let monthlySalary = salaries
            .first { $0.month == nowComponents.month! && $0.year == nowComponents.year! }?.amount ?? 0

        let categoryDict = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var catTotals: [UUID: Double] = [:]
        for expense in expenses where expense.date >= startOfMonth {
            catTotals[expense.categoryId, default: 0] += expense.amount
        }

        let topCategories = catTotals
            .sorted { $0.value > $1.value }
            .prefix(3)
            .compactMap { catId, amount -> SmartSpendEntry.CategoryRow? in
                guard let cat = categoryDict[catId] else { return nil }
                return SmartSpendEntry.CategoryRow(
                    id: cat.id, name: cat.name,
                    icon: cat.iconSystemName, colorName: cat.colorName, amount: amount
                )
            }

        return SmartSpendEntry(
            date: now,
            todayTotal: todayTotal,
            monthTotal: monthTotal,
            monthlySalary: monthlySalary,
            currencyCode: currencyCode,
            topCategories: topCategories
        )
    }
}

// MARK: - Root Entry View (dispatches by size)

struct SmartSpendWidgetView: View {
    let entry: SmartSpendEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:         SmallWidgetView(entry: entry)
        case .systemMedium:        MediumWidgetView(entry: entry)
        case .systemLarge:         LargeWidgetView(entry: entry)
        case .accessoryCircular:   AccessoryCircularView(entry: entry)
        case .accessoryRectangular:AccessoryRectangularView(entry: entry)
        case .accessoryInline:     AccessoryInlineView(entry: entry)
        default:                   SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Home Screen: Small

struct SmallWidgetView: View {
    let entry: SmartSpendEntry

    private var budgetProgress: Double {
        guard entry.monthlySalary > 0 else { return 0 }
        return min(entry.monthTotal / entry.monthlySalary, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetTopLine(title: "Today", icon: "wallet.pass.fill")

            Spacer(minLength: 0)

            Text(widgetAmount(entry.todayTotal, code: entry.currencyCode))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.55)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 6) {
                WidgetProgressBar(progress: budgetProgress)
                Text(entry.monthlySalary > 0 ? "\(Int(budgetProgress * 100))% of monthly budget" : "Monthly salary not set")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(16)
    }
}

// MARK: - Home Screen: Medium

struct MediumWidgetView: View {
    let entry: SmartSpendEntry

    private var budgetProgress: Double {
        guard entry.monthlySalary > 0 else { return 0 }
        return min(entry.monthTotal / entry.monthlySalary, 1.0)
    }

    private var remaining: Double {
        max(entry.monthlySalary - entry.monthTotal, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center) {
                WidgetTopLine(title: "Cenzio", icon: "wallet.pass.fill")
                Spacer()
                Text(monthYearShortString())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                WidgetValueBlock(title: "Today", value: widgetAmount(entry.todayTotal, code: entry.currencyCode))
                Divider().opacity(0.35)
                WidgetValueBlock(title: "Month", value: widgetAmount(entry.monthTotal, code: entry.currencyCode))
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetProgressBar(progress: budgetProgress)
                    Text(entry.monthlySalary > 0 ? "\(widgetAmount(remaining, code: entry.currencyCode)) left" : "Set monthly salary")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Button(intent: OpenAddExpenseIntent()) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }
}

// MARK: - Home Screen: Large

struct LargeWidgetView: View {
    let entry: SmartSpendEntry

    private var budgetProgress: Double {
        guard entry.monthlySalary > 0 else { return 0 }
        return min(entry.monthTotal / entry.monthlySalary, 1.0)
    }

    private var remaining: Double {
        max(entry.monthlySalary - entry.monthTotal, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    WidgetTopLine(title: "Cenzio", icon: "wallet.pass.fill")
                    Text(monthYearString())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: OpenAddExpenseIntent()) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 11)
                        .frame(height: 31)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                WidgetValueBlock(title: "Today", value: widgetAmount(entry.todayTotal, code: entry.currencyCode))
                Divider().opacity(0.35)
                WidgetValueBlock(title: "This month", value: widgetAmount(entry.monthTotal, code: entry.currencyCode))
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Budget")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(entry.monthlySalary > 0 ? "\(widgetAmount(remaining, code: entry.currencyCode)) left" : "Salary not set")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                WidgetProgressBar(progress: budgetProgress)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Top categories")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if entry.topCategories.isEmpty {
                    Text("Add expenses to see trends")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 7) {
                        ForEach(entry.topCategories.prefix(3)) { category in
                            WidgetCategoryLine(category: category, currencyCode: entry.currencyCode)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Home Screen Shared Components

private struct WidgetTopLine: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct WidgetValueBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WidgetProgressBar: View {
    let progress: Double

    private var safeProgress: Double {
        min(max(progress, 0), 1)
    }

    private var progressColor: Color {
        if safeProgress > 0.85 { return .red }
        if safeProgress > 0.65 { return .orange }
        return Color.accentColor
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(progressColor)
                    .frame(width: max(proxy.size.width * safeProgress, 5))
            }
        }
        .frame(height: 5)
    }
}

private struct WidgetCategoryLine: View {
    let category: SmartSpendEntry.CategoryRow
    let currencyCode: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colorFromName(category.colorName))
                .frame(width: 20)

            Text(category.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(widgetAmount(category.amount, code: currencyCode))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }
}

// MARK: - Lock Screen: Circular
// Ring gauge showing monthly budget used; today's spending in the centre.
// Falls back to a compact amount + icon when no salary is set.

struct AccessoryCircularView: View {
    let entry: SmartSpendEntry

    private var budgetProgress: Double {
        guard entry.monthlySalary > 0 else { return 0 }
        return min(entry.monthTotal / entry.monthlySalary, 1.0)
    }

    var body: some View {
        if entry.monthlySalary > 0 {
            Gauge(value: budgetProgress) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 9))
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text(compactAmount(entry.todayTotal))
                        .font(.system(size: 11, weight: .bold))
                        .minimumScaleFactor(0.5)
                    Text("today")
                        .font(.system(size: 7))
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(budgetProgress > 0.8 ? .red : budgetProgress > 0.6 ? .orange : .green)
        } else {
            // No salary set — show a simple open ring with today's spending
            Gauge(value: 1) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Image(systemName: "banknote.fill")
                        .font(.system(size: 9))
                    Text(compactAmount(entry.todayTotal))
                        .font(.system(size: 11, weight: .bold))
                        .minimumScaleFactor(0.5)
                }
            }
            .gaugeStyle(.accessoryCircular)
        }
    }
}

// MARK: - Lock Screen: Rectangular
// Header with branding, then Today / Month rows and an optional budget bar.

struct AccessoryRectangularView: View {
    let entry: SmartSpendEntry

    private var budgetProgress: Double {
        guard entry.monthlySalary > 0 else { return 0 }
        return min(entry.monthTotal / entry.monthlySalary, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Branding row
            HStack(spacing: 3) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Cenzio")
                    .font(.system(size: 10, weight: .semibold))
            }

            // Today row
            HStack {
                Text("Today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatAmount(entry.todayTotal, code: entry.currencyCode))
                    .font(.system(size: 11, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            // Month row
            HStack {
                Text("Month")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatAmount(entry.monthTotal, code: entry.currencyCode))
                    .font(.system(size: 11, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            // Budget progress bar (only when salary is set)
            if entry.monthlySalary > 0 {
                ProgressView(value: budgetProgress)
                    .progressViewStyle(.linear)
                    .tint(budgetProgress > 0.8 ? .red : budgetProgress > 0.6 ? .orange : .green)
            }
        }
    }
}

// MARK: - Lock Screen: Inline
// Single line above the clock

struct AccessoryInlineView: View {
    let entry: SmartSpendEntry

    var body: some View {
        Label {
            Text("Today: \(formatAmount(entry.todayTotal, code: entry.currencyCode))")
        } icon: {
            Image(systemName: "banknote.fill")
        }
    }
}

// MARK: - Helpers

private func formatAmount(_ amount: Double, code: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: amount)) ?? "\(code) \(String(format: "%.2f", amount))"
}

private func widgetAmount(_ amount: Double, code: String) -> String {
    let compact = compactAmountWithDecimal(amount)
    if code == "UZS" {
        return "\(compact) so'm"
    }
    return "\(currencySymbol(for: code))\(compact)"
}

private func compactAmount(_ amount: Double) -> String {
    if amount >= 1_000_000 { return String(format: "%.0fM", amount / 1_000_000) }
    if amount >= 1_000    { return String(format: "%.0fK", amount / 1_000) }
    return String(format: "%.0f", amount)
}

private func compactAmountWithDecimal(_ amount: Double) -> String {
    let absAmount = abs(amount)
    if absAmount >= 1_000_000 {
        return trimTrailingZero(String(format: "%.1fM", amount / 1_000_000))
    }
    if absAmount >= 1_000 {
        return trimTrailingZero(String(format: "%.1fK", amount / 1_000))
    }
    return trimTrailingZero(String(format: "%.0f", amount))
}

private func trimTrailingZero(_ value: String) -> String {
    value
        .replacingOccurrences(of: ".0M", with: "M")
        .replacingOccurrences(of: ".0K", with: "K")
}

private func currencySymbol(for code: String) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return formatter.currencySymbol ?? "\(code) "
}

private func monthYearString() -> String {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    return f.string(from: Date())
}

private func monthYearShortString() -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM yyyy"
    return f.string(from: Date())
}

private func colorFromName(_ name: String) -> Color {
    switch name {
    case "systemRed":    return .red
    case "systemOrange": return .orange
    case "systemYellow": return .yellow
    case "systemGreen":  return .green
    case "systemMint":   return Color(.systemMint)
    case "systemTeal":   return .teal
    case "systemCyan":   return .cyan
    case "systemBlue":   return .blue
    case "systemIndigo": return .indigo
    case "systemPurple": return .purple
    case "systemPink":   return .pink
    case "systemBrown":  return .brown
    default:             return .blue
    }
}

// MARK: - Widget Declaration

struct SmartSpendWidget: Widget {
    let kind = "SmartSpendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SmartSpendProvider()) { entry in
            SmartSpendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cenzio")
        .description("Track your spending at a glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}
