import SwiftUI
import Combine

struct MainTabView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var tabManager = TabManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddExpense = false

    var body: some View {
        TabView(selection: $tabManager.selectedTab) {
            Tab("dashboard", image: "hero-home", value: 0) {
                DashboardView()
            }
            Tab("expenses", image: "hero-list-bullet", value: 1) {
                ExpenseListView()
            }
            Tab("recurring", image: "hero-arrow-path", value: 2) {
                RecurringExpensesView()
            }
            Tab("settings", image: "hero-cog-6-tooth", value: 3) {
                SettingsView()
            }
        }
        .tint(Color(.systemBlue))
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView()
        }
        .onAppear {
            ExpenseSyncController.shared.foreground(true)
            dataManager.reloadFromSharedStorage()
            dataManager.processRecurringExpenses()
            checkAddExpenseIntent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartSpendOpenAddExpense)) { _ in
            checkAddExpenseIntent()
        }
        .onReceive(dataManager.$expenses.debounce(for: .milliseconds(800), scheduler: RunLoop.main)) { _ in
            if scenePhase == .active { ExpenseSyncController.shared.localDidChange() }
        }
        .onReceive(dataManager.$deletedExpenses.debounce(for: .milliseconds(800), scheduler: RunLoop.main)) { _ in
            if scenePhase == .active { ExpenseSyncController.shared.localDidChange() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            ExpenseSyncController.shared.foreground(newPhase == .active)
            if newPhase == .active {
                dataManager.reloadFromSharedStorage()
                dataManager.processRecurringExpenses()
                checkAddExpenseIntent()
            }
        }
    }

    private func checkAddExpenseIntent() {
        let defaults = UserDefaults(suiteName: "group.com.tursunov.SmartSpend") ?? UserDefaults.standard
        guard defaults.bool(forKey: "openAddExpense") else { return }
        defaults.removeObject(forKey: "openAddExpense")
        tabManager.switchToExpensesTab()
        DispatchQueue.main.async {
            showingAddExpense = true
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var dataManager = DataManager.shared

    @State private var showingMonthlySalary = false
    @State private var showingCurrencySelection = false
    @State private var showingDeletedExpenses = false
    @State private var showingDataExport = false
    @State private var showingDataImport = false
    @State private var showingIntegrations = false
    @State private var showingPrivacyPolicy = false
    @State private var showingAlert = false
    
    private var currentMonthSalaryText: String {
        let currentSalary = dataManager.getCurrentMonthSalary()
        return currentSalary > 0 ? formatCurrency(currentSalary, dataManager.user.currency) : "not_set".localized
    }
    
    private var currentMonthSalaryColor: Color {
        let currentSalary = dataManager.getCurrentMonthSalary()
        return currentSalary > 0 ? .secondary : .orange
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        return "SmartSpend v\(version) • Privacy First"
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.white
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    AppScreenHeader("settings".localized)

                    settingsContent
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)

            .sheet(isPresented: $showingPrivacyPolicy) {
                PrivacyPolicyView()
            }

            .sheet(isPresented: $showingMonthlySalary) {
                MonthlySalaryView()
                    .presentationDetents([.fraction(0.65), .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingCurrencySelection) {
                CurrencySelectionView()
            }
            .sheet(isPresented: $showingDeletedExpenses) {
                DeletedExpensesView()
            }
            .sheet(isPresented: $showingDataExport) {
                DataExportView()
            }
            .sheet(isPresented: $showingDataImport) {
                DataImportView()
            }
            .sheet(isPresented: $showingIntegrations) {
                NavigationStack {
                    ExpenseSyncView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingIntegrations = false }
                            }
                        }
                }
            }
            .alert("clear_all_data".localized, isPresented: $showingAlert) {
                Button("cancel".localized, role: .cancel) { }
                Button("delete".localized, role: .destructive) {
                    clearAllData()
                }
            } message: {
                Text("\("clear_all_data_message".localized) Google Sheets, Notion, server copies and remote history are not deleted. A sync change already in progress may finish. Revoke SmartSpend in your provider account settings and contact the server administrator to remove remote copies or retained access.")
            }
        }
    }

    private var settingsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                moneySetupPanel

                settingsGroup("planning".localized) {
                    NavigationLink(destination: BudgetSettingsView()) {
                        settingsRowContent(
                            icon: "flag",
                            title: "budget_goals".localized,
                            tint: Color(.systemGreen)
                        )
                    }
                    .buttonStyle(SettingsPressStyle())

                    settingsDivider

                    NavigationLink(destination: CategoryManagementView()) {
                        settingsRowContent(
                            icon: "tag",
                            title: "categories".localized,
                            tint: Color(.systemOrange)
                        )
                    }
                    .buttonStyle(SettingsPressStyle())
                }

                settingsGroup("data_management".localized) {
                    settingsButtonRow(
                        icon: "arrow-down-tray",
                        title: "import_data".localized,
                        tint: Color(.systemBlue)
                    ) {
                        showingDataImport = true
                    }

                    settingsDivider

                    settingsButtonRow(
                        icon: "arrow-up-tray",
                        title: "export_data".localized,
                        tint: Color(.systemGreen)
                    ) {
                        showingDataExport = true
                    }

                    settingsDivider

                    settingsButtonRow(
                        icon: "archive-box",
                        title: "deleted_expenses".localized,
                        tint: Color(.systemGray)
                    ) {
                        showingDeletedExpenses = true
                    }

                    settingsDivider

                    settingsButtonRow(
                        icon: "arrow-path",
                        title: "Integrations",
                        tint: Color(.systemBlue)
                    ) {
                        showingIntegrations = true
                    }
                    .accessibilityIdentifier("settings.integrations")
                }

                settingsGroup("support".localized) {
                    settingsButtonRow(
                        icon: "hand-raised",
                        title: "privacy_policy".localized,
                        tint: Color(.systemIndigo)
                    ) {
                        showingPrivacyPolicy = true
                    }

                    settingsDivider

                    settingsButtonRow(
                        icon: "envelope",
                        title: "email_us".localized,
                        tint: Color(.systemBlue),
                        showsChevron: false
                    ) {
                        if let url = URL(string: "mailto:tursunov.umidjon.uz@gmail.com") {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                destructiveAction

                Text(appVersionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(Color.white)
    }

    private var moneySetupPanel: some View {
        VStack(spacing: 0) {
            Button {
                showingMonthlySalary = true
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(.systemBlue))
                        .frame(width: 4, height: 52)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("monthly_salaries".localized)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(currentMonthSalaryText)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(currentMonthSalaryColor)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                    }

                    Spacer(minLength: 8)

                    HeroIcon("chevron-right", size: 14)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())

            Divider()
                .padding(.leading, 36)

            Button {
                showingCurrencySelection = true
            } label: {
                HStack(spacing: 13) {
                    HeroIcon("credit-card", size: 21)
                        .foregroundStyle(Color(.systemTeal))
                        .frame(width: 24)

                    Text("currency".localized)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Text(dataManager.user.currency.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospaced()

                    HeroIcon("chevron-right", size: 13)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
        }
        .liquidGlassCard(cornerRadius: 22)
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color(.separator).opacity(0.14), lineWidth: 1)
            }
        }
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.leading, 53)
            .padding(.trailing, 16)
    }

    private func settingsButtonRow(
        icon: String,
        title: String,
        tint: Color,
        trailing: String? = nil,
        trailingColor: Color = .secondary,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            settingsRowContent(
                icon: icon,
                title: title,
                tint: tint,
                trailing: trailing,
                trailingColor: trailingColor,
                showsChevron: showsChevron
            )
        }
        .buttonStyle(SettingsPressStyle())
    }

    private func settingsRowContent(
        icon: String,
        title: String,
        tint: Color,
        trailing: String? = nil,
        trailingColor: Color = .secondary,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 13) {
            HeroIcon(icon, size: 21)
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            if showsChevron {
                HeroIcon(systemName: "chevron.right", size: 13)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var destructiveAction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                showingAlert = true
            } label: {
                HStack(spacing: 13) {
                    HeroIcon("trash", size: 21)
                        .frame(width: 24)

                    Text("clear_all_data".localized)
                        .font(.body.weight(.semibold))

                    Spacer()
                }
                .foregroundStyle(Color(.systemRed))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            .background(
                Color(.systemRed).opacity(0.06),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color(.systemRed).opacity(0.16), lineWidth: 1)
            }

            Text("clear_all_data_message".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func clearAllData() {
        ExpenseSyncController.shared.clearLocalConnection()
        Task { await VoiceConnectionStore.shared.disconnect() }
        dataManager.clearAllData()
    }

    private func formatCurrency(_ amount: Double, _ currency: Currency) -> String {
        return CurrencyFormatter.format(amount, currency: currency)
    }
}

private struct SettingsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.58 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

#Preview {
    MainTabView()
}
