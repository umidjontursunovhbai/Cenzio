import SwiftUI

// MARK: - Region grouping

private enum CurrencyRegion: String, CaseIterable {
    case major       = "Major"
    case asian       = "Asian"
    case middleEast  = "Middle East"
    case european    = "European"
    case african     = "African"
    case latinAmerica = "Latin America"
    case other       = "Other"

    var currencies: [Currency] {
        switch self {
        case .major:        return [.usd, .eur, .gbp, .jpy, .cny, .aud, .cad, .chf, .inr, .brl]
        case .asian:        return [.uzs, .krw, .sgd, .hkd, .twd, .thb, .myr, .idr, .php, .vnd]
        case .middleEast:   return [.aed, .sar, .ils, .try_, .egp, .irr]
        case .european:     return [.rub, .pln, .sek, .nok, .dkk, .czk, .huf, .ron, .bgn]
        case .african:      return [.zar, .ngn, .kes, .etb, .ghs]
        case .latinAmerica: return [.mxn, .ars, .clp, .cop, .pen]
        case .other:        return [.nzd]
        }
    }
}

// MARK: - Main View

struct CurrencySelectionView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCurrency: Currency
    @State private var searchText = ""

    init() {
        self._selectedCurrency = State(initialValue: DataManager.shared.user.currency)
    }

    private var searchResults: [Currency] {
        let query = searchText.lowercased()
        return Currency.allCases.filter {
            $0.rawValue.lowercased().contains(query) ||
            $0.name.lowercased().contains(query)
        }
    }

    private func select(_ currency: Currency) {
        selectedCurrency = currency
        dataManager.updateCurrency(currency)
        dismiss()
    }

    var body: some View {
        Group { // pushed from Settings: its stack gives the back button
            List {
                if searchText.isEmpty {
                    ForEach(CurrencyRegion.allCases, id: \.self) { region in
                        Section(region.rawValue) {
                            ForEach(region.currencies, id: \.self) { currency in
                                CurrencyRowView(
                                    currency: currency,
                                    isSelected: selectedCurrency == currency,
                                    onTap: { select(currency) }
                                )
                            }
                        }
                    }
                } else {
                    ForEach(searchResults, id: \.self) { currency in
                        CurrencyRowView(
                            currency: currency,
                            isSelected: selectedCurrency == currency,
                            onTap: { select(currency) }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .navigationTitle("currency".localized)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search currencies"
            )
        }
        .tint(NightTheme.accent)
    }
}

// MARK: - Row

struct CurrencyRowView: View {
    let currency: Currency
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(currency.flag)
                    .font(.title3)

                Text(currency.name)
                    .foregroundStyle(.primary)

                Spacer()

                Text(currency.rawValue)
                    .foregroundStyle(NightTheme.secondaryLabel)

                if isSelected {
                    HeroIcon(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(NightTheme.glassFill)
        .listRowSeparatorTint(NightTheme.hair)
    }
}

#Preview {
    CurrencySelectionView()
}
