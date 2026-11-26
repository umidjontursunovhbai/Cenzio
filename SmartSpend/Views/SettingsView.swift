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
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
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
    private var cityBackground: some View {
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
        } header: {
            accountFigures
        }
    }

    /// A walker and a street lamp standing on the account card's top edge, under the title.
    private var accountFigures: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize {
                StreetFigureView(figure: .walker, height: 26)
                StreetFigureView(figure: .lamp, height: 40)
            }
        }
        .padding(.trailing, 8)
        .padding(.bottom, -4)
        .accessibilityHidden(true)
    }

    private func avatar(for name: String?) -> some View {
        ZStack {
            Circle().fill(.white)
            if let initial = name?.trimmingCharacters(in: .whitespaces).first {
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
            Button { showingMonthlySalary = true } label: {
                SettingsRow(symbol: "wallet.bifold", title: "monthly_salary".localized) {
                    if salary > 0 {
                        Text(salary.formatted(.number.precision(.fractionLength(0...2))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("not_set".localized).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("settings.salary")

            Button { showingCurrencySelection = true } label: {
                SettingsRow(symbol: "banknote", title: "currency".localized) {
                    Text(currency.rawValue).foregroundStyle(.secondary)
                }
            }

            Button { showingBudgetGoals = true } label: {
                SettingsRow(symbol: "flag", title: "budget_goals".localized)
            }

            NavigationLink(destination: CategoryManagementView()) {
                SettingsRow(symbol: "tag", title: "categories".localized, showsChevron: false)
            }
        } header: {
            StreetSectionHeader(title: "settings_money".localized, figure: .shopper)
        }
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
                SettingsRow(symbol: "moon", title: "appearance".localized, showsChevron: false)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.appearance")
        } header: {
            StreetSectionHeader(title: "settings_app".localized, figure: .cyclist)
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
            StreetSectionHeader(title: "settings_your_data".localized, figure: .snacker)
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
            VStack(spacing: 4) {
                Text("Cenzio \(appVersion)")
                Text("settings_privacy_line".localized)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Row

/// One native row: a quiet gray tile with an SF Symbol, the title, an optional
/// trailing value, and a chevron for rows that open something.
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 29, height: 29)
                .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
