import SwiftUI

/// Budget state for one category this month. Mirrors the thresholds the app uses for
/// Dashboard budget alerts and Insights: 80% of the limit is "near", more than the limit is "over".
enum BudgetGoalStatus: Equatable {
    case noLimit
    case onTrack
    case nearLimit
    case overBudget

    /// Share of the monthly limit at which a category is flagged as close to its limit.
    static let warningThreshold: Double = 0.8

    static func evaluate(spent: Double, limit: Double, isEnabled: Bool) -> BudgetGoalStatus {
        guard isEnabled, limit > 0 else { return .noLimit }
        if spent > limit { return .overBudget }
        if spent >= limit * warningThreshold { return .nearLimit }
        return .onTrack
    }

    var title: String {
        switch self {
        case .noLimit: return "budget_status_no_limit".localized
        case .onTrack: return "budget_status_on_track".localized
        case .nearLimit: return "near_limit".localized
        case .overBudget: return "over_budget".localized
        }
    }

    var color: Color {
        switch self {
        case .noLimit: return Color(.systemGray)
        case .onTrack: return Color(.systemGreen)
        case .nearLimit: return Color(.systemOrange)
        case .overBudget: return Color(.systemRed)
        }
    }
}

/// Thin progress bar with a tick at the 80% warning threshold.
struct BudgetProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 8
    var showsThreshold = true

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(NightTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: clamped > 0 ? max(proxy.size.width * clamped, height) : 0)
                if showsThreshold {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2, height: height + 2)
                        .offset(x: proxy.size.width * BudgetGoalStatus.warningThreshold - 1)
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: progress)
        .accessibilityHidden(true)
    }
}

/// "How budget goals work", pushed from the Budget goals info button.
struct BudgetGoalsInfoPage: View {
    /// Optional real example: a category name and its limit.
    var example: (name: String, limit: Double)?
    let currency: Currency

    /// The meter runs from 0 to 120% so the over-budget zone has room.
    private let meterSpan = 1.2

    var body: some View {
        InfoPage(title: "budget_info_title".localized, lead: "budget_info_why_body".localized) {
            InfoPageSection("budget_info_states_title".localized) {
                VStack(spacing: 0) {
                    meter
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .padding(.bottom, 10)
                    Divider().overlay(NightTheme.hair)
                    statusRow(.onTrack, rule: "budget_info_state_on_track".localized)
                    Divider().overlay(NightTheme.hair).padding(.leading, 36)
                    statusRow(.nearLimit, rule: "budget_info_state_near".localized)
                    Divider().overlay(NightTheme.hair).padding(.leading, 36)
                    statusRow(.overBudget, rule: "budget_info_state_over".localized)
                }
                .nightGroup()
            }

            if let example {
                InfoPageSection("example_header".localized) {
                    exampleCard(example)
                }
            }

            InfoPageSection("budget_info_calc_title".localized) {
                InfoPageList(rows: [
                    ("calendar-days", "budget_info_calc_month".localized),
                    ("tag", "budget_info_calc_category".localized),
                    ("check-circle", "budget_info_calc_active".localized)
                ])
            }

            InfoPageSection("budget_info_alerts_title".localized) {
                Text("budget_info_alerts_body".localized)
                    .font(.subheadline)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .nightGroup()
            }

            InfoPageSection("budget_info_more_title".localized) {
                InfoPageList(rows: [
                    ("flag", "budget_info_more_goals".localized),
                    ("sparkles", "budget_info_more_suggest".localized)
                ])
            }
        }
    }

    /// One bar with the three zones and marks at 80% and 100%.
    private var meter: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        BudgetGoalStatus.onTrack.color
                            .frame(width: width * BudgetGoalStatus.warningThreshold / meterSpan)
                        BudgetGoalStatus.nearLimit.color
                            .frame(width: width * (1 - BudgetGoalStatus.warningThreshold) / meterSpan)
                        BudgetGoalStatus.overBudget.color
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())
                    ForEach([BudgetGoalStatus.warningThreshold, 1.0], id: \.self) { mark in
                        Capsule()
                            .fill(NightTheme.accent)
                            .frame(width: 2, height: 22)
                            .offset(x: width * mark / meterSpan - 1)
                    }
                }
                .frame(height: 22)
            }
            .frame(height: 22)

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Text(0.0.formatted(.percent))
                    ForEach([BudgetGoalStatus.warningThreshold, 1.0], id: \.self) { mark in
                        Text(mark.formatted(.percent))
                            .fixedSize()
                            .position(x: proxy.size.width * mark / meterSpan, y: 7)
                    }
                }
            }
            .frame(height: 14)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(NightTheme.secondaryLabel)
        }
        .accessibilityHidden(true)
    }

    private func statusRow(_ status: BudgetGoalStatus, rule: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.color)
                Text(rule)
                    .font(.footnote)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// Worked example with one of the user's own budgets: where the 80% warning starts.
    private func exampleCard(_ example: (name: String, limit: Double)) -> some View {
        let limitText = CurrencyFormatter.format(example.limit, currency: currency)
        let warningText = CurrencyFormatter.format(example.limit * BudgetGoalStatus.warningThreshold, currency: currency)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(example.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(limitText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .lineLimit(1)
            }
            BudgetProgressBar(
                progress: BudgetGoalStatus.warningThreshold,
                tint: BudgetGoalStatus.nearLimit.color,
                height: 8
            )
            Text("budget_info_example".localized(with: example.name, limitText, warningText))
                .font(.footnote)
                .foregroundStyle(NightTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .nightGroup()
        .accessibilityElement(children: .combine)
    }
}
