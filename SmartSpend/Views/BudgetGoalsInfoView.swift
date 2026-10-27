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
                    .fill(Color(.systemGray5))
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

/// Body of the Budget Goals info popup. Presented with `.infoPopup` from `BudgetSettingsView`,
/// which supplies the title, icon, backdrop, "Got it" button and animations; each section here
/// staggers in via `InfoPopupSection`.
struct BudgetGoalsInfoContent: View {
    /// Optional real example: a category name and its limit.
    var example: (name: String, limit: Double)?
    let currency: Currency

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            InfoPopupSection("budget_info_why_title".localized, index: 0) {
                Text("budget_info_why_body".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InfoPopupSection("budget_info_calc_title".localized, index: 1) {
                VStack(alignment: .leading, spacing: 12) {
                    bullet(icon: "calendar-days", text: "budget_info_calc_month".localized)
                    bullet(icon: "tag", text: "budget_info_calc_category".localized)
                    bullet(icon: "check-circle", text: "budget_info_calc_active".localized)
                }
            }

            InfoPopupSection("budget_info_states_title".localized, index: 2) {
                VStack(alignment: .leading, spacing: 0) {
                    statusRow(.onTrack, rule: "budget_info_state_on_track".localized, progress: 0.5)
                    Divider().padding(.leading, 26)
                    statusRow(.nearLimit, rule: "budget_info_state_near".localized, progress: 0.86)
                    Divider().padding(.leading, 26)
                    statusRow(.overBudget, rule: "budget_info_state_over".localized, progress: 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let example {
                exampleRow(example)
                    .infoPopupStaggered(3)
            }

            InfoPopupSection("budget_info_alerts_title".localized, index: 4) {
                Text("budget_info_alerts_body".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InfoPopupSection("budget_info_more_title".localized, index: 5) {
                VStack(alignment: .leading, spacing: 12) {
                    bullet(icon: "flag", text: "budget_info_more_goals".localized)
                    bullet(icon: "sparkles", text: "budget_info_more_suggest".localized)
                }
            }
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HeroIcon(icon, size: 17)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Legend row: colored dot + status name, the rule, and a sample bar in that color.
    private func statusRow(_ status: BudgetGoalStatus, rule: String, progress: Double) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(status.color)
                    Spacer(minLength: 8)
                    BudgetProgressBar(progress: progress, tint: status.color, height: 6)
                        .frame(width: 56)
                }
                Text(rule)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// Worked example with one of the user's own budgets: where the 80% warning starts.
    private func exampleRow(_ example: (name: String, limit: Double)) -> some View {
        let limitText = CurrencyFormatter.format(example.limit, currency: currency)
        let warningText = CurrencyFormatter.format(example.limit * BudgetGoalStatus.warningThreshold, currency: currency)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HeroIcon("target", size: 15)
                    .foregroundStyle(Color(.systemOrange))
                    .accessibilityHidden(true)
                Text(example.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(limitText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            BudgetProgressBar(
                progress: BudgetGoalStatus.warningThreshold,
                tint: BudgetGoalStatus.nearLimit.color,
                height: 8
            )

            Text("budget_info_example".localized(with: example.name, limitText, warningText))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemOrange).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemOrange).opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
