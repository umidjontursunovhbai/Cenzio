import SwiftUI

struct MonthlySalaryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @State private var selectedYear: Int
    @State private var selectedMonth: Int
    @State private var salaryAmount: String = ""

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    init(year: Int? = nil, month: Int? = nil) {
        let cal = Calendar.current
        let now = Date()
        _selectedYear  = State(initialValue: year  ?? cal.component(.year,  from: now))
        _selectedMonth = State(initialValue: month ?? cal.component(.month, from: now))
    }

    // MARK: - Computed

    private var monthYearLabel: String {
        var c = DateComponents()
        c.year = selectedYear; c.month = selectedMonth; c.day = 1
        guard let date = Calendar.current.date(from: c) else { return "" }
        return Self.monthYearFormatter.string(from: date)
    }

    private var displayAmount: String {
        salaryAmount.isEmpty ? "0" : salaryAmount
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // Month navigator
                HStack {
                    Button { stepMonth(by: -1) } label: {
                        HeroIcon(systemName: "chevron.left")
                            .fontWeight(.semibold)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)

                    Spacer()

                    Text(monthYearLabel)
                        .font(.headline)

                    Spacer()

                    Button { stepMonth(by: 1) } label: {
                        HeroIcon(systemName: "chevron.right")
                            .fontWeight(.semibold)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Amount display
                VStack(spacing: 4) {
                    Text(dataManager.user.currency.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(displayAmount)
                        .font(.system(size: 48, weight: .light, design: .rounded))
                        .foregroundStyle(salaryAmount.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                Divider()

                // Built-in number pad — no system keyboard, sheet never expands
                SalaryNumberPad(amount: $salaryAmount)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appBackdrop()
            .navigationTitle("monthly_salary_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("save".localized) {
                        saveSalary()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(salaryAmount.isEmpty || AmountInputFormatter.parse(salaryAmount) == nil)
                }
            }
            .onAppear { loadExistingSalary() }
        }
    }

    // MARK: - Helpers

    private func stepMonth(by delta: Int) {
        var m = selectedMonth + delta
        var y = selectedYear
        if m > 12 { m = 1;  y += 1 }
        if m < 1  { m = 12; y -= 1 }
        selectedMonth = m
        selectedYear  = y
        loadExistingSalary()
    }

    private func loadExistingSalary() {
        if let existing = dataManager.monthlySalaries.first(where: {
            $0.year == selectedYear && $0.month == selectedMonth
        }) {
            salaryAmount = AmountInputFormatter.formatValue(existing.amount)
        } else {
            salaryAmount = ""
        }
    }

    private func saveSalary() {
        guard let amount = AmountInputFormatter.parse(salaryAmount) else { return }
        dataManager.setSalaryForMonth(year: selectedYear, month: selectedMonth, amount: amount)
    }
}

// MARK: - Number Pad

private struct SalaryNumberPad: View {
    @Binding var amount: String
    @Environment(\.colorScheme) private var colorScheme

    private let rows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0",  "⌫"]
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { key in
                        Button { tap(key) } label: {
                            Group {
                                if key == "⌫" {
                                    HeroIcon(systemName: "delete.left")
                                        .font(.title3)
                                } else {
                                    Text(key)
                                        .font(.title2)
                                        .fontWeight(.regular)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .modifier(SalaryKeySurface(isDark: colorScheme == .dark))
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func tap(_ key: String) {
        switch key {
        case "⌫":
            if !amount.isEmpty { amount.removeLast() }
        case ".":
            guard !amount.contains(".") else { return }
            amount = amount.isEmpty ? "0." : amount + "."
        default:
            // Block leading zeros
            if amount == "0" { amount = key; return }
            // Limit to 2 decimal places
            if let dot = amount.firstIndex(of: ".") {
                let decimals = amount.distance(from: amount.index(after: dot), to: amount.endIndex)
                guard decimals < 2 else { return }
            }
            amount += key
        }

        amount = AmountInputFormatter.formatEditingText(amount)
    }
}

/// Keys are interactive Liquid Glass on black in dark mode; light keeps the gray keys.
private struct SalaryKeySurface: ViewModifier {
    let isDark: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isDark {
            content
                .liquidGlassSurface(shape, interactive: true)
                .contentShape(shape)
        } else {
            content.background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
