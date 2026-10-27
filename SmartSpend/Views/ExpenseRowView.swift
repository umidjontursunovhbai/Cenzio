import SwiftUI

/// One expense in the Expenses list. Display only: the list owns taps,
/// swipe actions, context menus and the edit sheet.
struct ExpenseRowView: View {
    let expense: Expense
    let category: UserCategory
    let currency: Currency
    /// `nil` outside selection mode; otherwise whether this row is selected.
    var selection: Bool? = nil

    var body: some View {
        HStack(spacing: iOSDesignSystem.Spacing.medium) {
            if let isSelected = selection {
                selectionMark(isSelected)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            HeroIcon(systemName: category.iconSystemName, size: 20)
                .foregroundStyle(category.color)
                .frame(width: 40, height: 40)
                .background(category.color.opacity(0.13), in: RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: iOSDesignSystem.Spacing.small)

            Text(CurrencyFormatter.format(expense.amount, currency: currency))
                .font(.body.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 2)
        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection == true ? .isSelected : [])
    }

    private var displayTitle: String {
        let trimmed = expense.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exp_untitled".localized : trimmed
    }

    /// Category, plus the time when one was recorded (imports often land at midnight).
    private var subtitle: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: expense.date)
        guard parts.hour != 0 || parts.minute != 0 else { return category.name }
        return "\(category.name) · \(expense.date.formatted(date: .omitted, time: .shortened))"
    }

    private func selectionMark(_ isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color(.systemGray3), lineWidth: 1.5)
            if isSelected {
                Circle().fill(Color.accentColor)
                HeroIcon("check", size: 12)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

struct PressEffectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
