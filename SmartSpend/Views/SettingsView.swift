import SwiftUI
import StoreKit

/// Settings as a plain native grouped list over the still night city: account, money,
/// app preferences, the user's data, and help. Street figures stand on the account
/// card and on three section headers (up to 5 per screen, see DESIGN.md).
struct SettingsView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var appleAccount = AppleAccountStore.shared

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.requestReview) private var requestReview

    @State private var showingMonthlySalary = false
    @State private var showingCurrencySelection = false
    @State private var showingDeletedExpenses = false
    @State private var showingDataExport = false
    @State private var showingDataImport = false
    @State private var showingBudgetGoals = false
    @State private var showingAccount = false
    @State private var showingPrivacyPolicy = false
    @State private var showingClearData = false
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system

    private var currency: Currency { dataManager.user.currency }
    private var salary: Double { dataManager.getCurrentMonthSalary() }

    var body: some View {
        NavigationStack {
            List {
                Group {
                accountSection
                moneySection
                appSection
                dataSection
                clearDataSection
                helpSection
                }
                // over the flat dark ground a material reads gray, so dark mode uses the dashboard's clear glass
                .listRowBackground(Rectangle().fill(colorScheme == .dark ? AnyShapeStyle(NightTheme.glassFill) : AnyShapeStyle(.ultraThinMaterial)))
                .listRowSeparator(.hidden)
                versionFooter
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { cityBackground }
            .navigationTitle("settings".localized)
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showingPrivacyPolicy) { PrivacyPolicyView() }
            .sheet(isPresented: $showingAccount) { NavigationStack { AccountView() } }
            .sheet(isPresented: $showingMonthlySalary) {
                MonthlySalaryView()
                    .presentationDetents([.fraction(0.65), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingCurrencySelection) { CurrencySelectionView() }
            .sheet(isPresented: $showingDeletedExpenses) { DeletedExpensesView() }
            .sheet(isPresented: $showingDataExport) { DataExportView() }
            .sheet(isPresented: $showingDataImport) { DataImportView() }
            .sheet(isPresented: $showingBudgetGoals) { BudgetSettingsView() }
            .sheet(isPresented: $showingClearData) { ClearDataView() }
        }
    }

    /// The onboarding city, still and blurred, fixed behind the list: night in dark
    /// mode, day in light mode. It never animates, so it does not compete with the rows.
    /// Dark mode: the dashboard's flat ink ground (owner, 2026-11-26). Light mode: the blurred day city.
    @ViewBuilder
    private var cityBackground: some View {
        if colorScheme == .dark {
            NightGround()
                .accessibilityHidden(true)
        } else {
            lightCityBackground
        }
    }

    private var lightCityBackground: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground)
            NightCityView(page: colorScheme == .dark ? .smart : .privacy, reduceMotion: true, showsOverlay: false)
                .aspectRatio(City.W / City.H, contentMode: .fill)
                .blur(radius: 14)
                .opacity(colorScheme == .dark ? 0.8 : 0.55)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Account and iCloud

    private var accountSection: some View {
        let account = appleAccount.account
        let name = account?.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? account?.email

        return Section {
            Button { showingAccount = true } label: {
                HStack(spacing: 14) {
                    avatar(for: name)
                    Text(AppleAccountDisplay.title(for: account))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    NavigationChevron()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.account")
        }
    }

    private func avatar(for name: String?) -> some View {
        ZStack {
            Circle().fill(.white)
            if let photo = ProfilePhoto.image(from: dataManager.user.photo) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else if let initial = name?.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(OnboardingPalette.display(26))
                    .foregroundStyle(OnboardingPalette.ink)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(OnboardingPalette.ink)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    // MARK: - Money

    private var moneySection: some View {
        Section {
            moneySummary

            Button { showingMonthlySalary = true } label: {
                SettingsRow(symbol: "wallet.bifold", title: "monthly_salary".localized) {
                    Text(salary > 0 ? CurrencyFormatter.formatFull(salary, currency: currency) : "not_set".localized)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings.salary")

            Button { showingBudgetGoals = true } label: {
                SettingsRow(symbol: "chart.pie", title: "settings_budgets".localized) {
                    let active = dataManager.categoryBudgets.filter(\.isEnabled).count
                    if active > 0 {
                        Text(String(format: "settings_active_count".localized, active))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink(destination: CategoryManagementView()) {
                SettingsRow(symbol: "tag", title: "categories".localized, showsChevron: false) {
                    if !dataManager.userCategories.isEmpty {
                        Text("\(dataManager.userCategories.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button { showingCurrencySelection = true } label: {
                SettingsRow(symbol: "dollarsign.circle", title: "currency".localized) {
                    Text(currency.rawValue).foregroundStyle(.secondary)
                }
            }
        } header: {
            StreetSectionHeader(title: "settings_money".localized, figure: .cyclist, loops: true, lamp: true)
        }
    }

    /// This month at a glance: what is left of the income, a bar, and spent / income.
    /// Without an income it shows what was spent and asks for the income.
    private var moneySummary: some View {
        let spent = dataManager.getCurrentMonthExpensesTotal()
        let left = salary - spent
        return Button { showingMonthlySalary = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text((salary > 0 ? "settings_left_this_month" : "settings_spent_this_month").localized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(CurrencyFormatter.formatFull(salary > 0 ? left : spent, currency: currency))
                    .font(NightTheme.display(34))
                    .monospacedDigit()
                    .foregroundStyle(left < 0 && salary > 0 ? Color(.systemRed) : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if salary > 0 {
                    ProgressView(value: min(1, max(0, spent / salary)))
                        .tint(.primary)
                    HStack {
                        Text(String(format: "settings_spent_amount".localized, CurrencyFormatter.formatFull(spent, currency: currency)))
                        Spacer(minLength: 8)
                        Text(String(format: "settings_income_amount".localized, CurrencyFormatter.formatFull(salary, currency: currency)))
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                } else {
                    Text("settings_set_income_hint".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.moneySummary")
    }

    // MARK: - App

    private var appSection: some View {
        Section {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsRow(symbol: "globe", title: "language".localized) {
                    if let currentLanguageName {
                        Text(currentLanguageName).foregroundStyle(.secondary)
                    }
                }
            }

            Picker(selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsRow(symbol: "moon.stars", title: "appearance".localized, showsChevron: false)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.appearance")
        } header: {
            StreetSectionHeader(title: "settings_app".localized)
        }
    }

    private var currentLanguageName: String? {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized
    }

    // MARK: - Your data

    private var dataSection: some View {
        Section {
            Button { showingDataExport = true } label: {
                SettingsRow(symbol: "square.and.arrow.up", title: "settings_export".localized)
            }
            Button { showingDataImport = true } label: {
                SettingsRow(symbol: "square.and.arrow.down", title: "settings_import".localized)
            }
            Button { showingDeletedExpenses = true } label: {
                SettingsRow(symbol: "archivebox", title: "settings_recently_deleted".localized) {
                    if !dataManager.deletedExpenses.isEmpty {
                        Text("\(dataManager.deletedExpenses.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            StreetSectionHeader(title: "settings_your_data".localized, figure: .snacker, loops: true, reach: 0.45)
        }
    }

    private var clearDataSection: some View {
        Section {
            Button(role: .destructive) { showingClearData = true } label: {
                Text("clear_data_title".localized)
                    .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("clear_data_footer".localized)
        }
    }

    // MARK: - Help

    private var helpSection: some View {
        Section {
            Button {
                if let url = URL(string: "mailto:umidjon.muydinov@icloud.com") {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsRow(symbol: "envelope", title: "email_us".localized, showsChevron: false)
            }
            Button { requestReview() } label: {
                SettingsRow(symbol: "star", title: "settings_rate".localized, showsChevron: false)
            }
            Button { showingPrivacyPolicy = true } label: {
                SettingsRow(symbol: "hand.raised", title: "privacy_policy".localized)
            }
        } header: {
            StreetSectionHeader(title: "settings_help".localized)
        }
    }

    // MARK: - Footer

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
    }

    private var versionFooter: some View {
        Section {
        } footer: {
            Text("Cenzio \(appVersion)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Row

/// One native row: a plain SF Symbol (no tile), the title, an optional trailing
/// value, and a chevron for rows that open something.
private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var showsChevron = true
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, title: String, showsChevron: Bool = true,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.showsChevron = showsChevron
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
                .lineLimit(1)
            if showsChevron {
                NavigationChevron()
            }
        }
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, title: String, showsChevron: Bool = true) {
        self.init(symbol: symbol, title: title, showsChevron: showsChevron) { EmptyView() }
    }
}

/// The small gray chevron native lists show on rows that open a screen.
private struct NavigationChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
