import SwiftUI
import Combine

struct SettingsView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var appleAccount = AppleAccountStore.shared
    @ObservedObject private var cloudSync = CloudSyncController.shared

    @State private var showingMonthlySalary = false
    @State private var showingCurrencySelection = false
    @State private var showingDeletedExpenses = false
    @State private var showingDataExport = false
    @State private var showingDataImport = false
    @State private var showingBudgetGoals = false
    @State private var showingAccount = false
    @State private var showingPrivacyPolicy = false
    @State private var showingAlert = false

    private enum Metrics {
        static let horizontalMargin: CGFloat = 24
        static let sectionSpacing: CGFloat = 24
        static let cardRadius: CGFloat = 20
        static let rowMinHeight: CGFloat = 52
        static let tileSize: CGFloat = 30
        static let tileGlyph: CGFloat = 17
        static let rowSpacing: CGFloat = 14
        static let rowPadding: CGFloat = 16
        /// Divider starts where the row title starts, like native grouped lists.
        static var dividerInset: CGFloat { rowPadding + tileSize + rowSpacing }
    }

    private var currentMonthSalary: Double {
        dataManager.getCurrentMonthSalary()
    }

    private var currentMonthSalaryText: String {
        currentMonthSalary > 0
            ? CurrencyFormatter.format(currentMonthSalary, currency: dataManager.user.currency)
            : "not_set".localized
    }

    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        return "Cenzio v\(version) • Privacy First"
    }

    var body: some View {
        NavigationStack {
            settingsContent
                .background(iOSDesignSystem.appBackground.ignoresSafeArea())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showingPrivacyPolicy) {
                    PrivacyPolicyView()
                }
                .sheet(isPresented: $showingAccount) {
                    NavigationStack { AccountView() }
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
                .sheet(isPresented: $showingBudgetGoals) {
                    BudgetSettingsView()
                }
                .sheet(isPresented: $showingAlert) {
                    ClearDataView()
                }
        }
    }

    // MARK: - Layout

    /// A plain (non-lazy) VStack: the screen has a fixed, small number of
    /// sections, so every height is measured up front and the scroll content
    /// size never changes while scrolling. (A LazyVStack here estimated the
    /// height of off-screen cards and corrected it as they appeared, which made
    /// the content jump when scrolling up and down.)
    private var settingsContent: some View {
        ScrollView {
            AppScreenHeader("settings".localized)

            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    accountCard
                    iCloudSyncSection
                }

                settingsSection("monthly_salaries".localized) {
                    salaryRow
                    sectionDivider
                    Button {
                        showingCurrencySelection = true
                    } label: {
                        rowLabel(
                            icon: "credit-card",
                            title: "currency".localized,
                            tint: Color(.systemTeal),
                            trailing: dataManager.user.currency.rawValue
                        )
                    }
                    .buttonStyle(SettingsPressStyle())
                }

                settingsSection("planning".localized) {
                    // Budget Goals owns its NavigationStack and Done button, so present it like Dashboard does.
                    settingsButtonRow(icon: "flag", title: "budget_goals".localized, tint: Color(.systemGreen)) {
                        showingBudgetGoals = true
                    }

                    sectionDivider

                    NavigationLink(destination: CategoryManagementView()) {
                        rowLabel(icon: "tag", title: "categories".localized, tint: Color(.systemOrange))
                    }
                    .buttonStyle(SettingsPressStyle())
                }

                settingsSection("data_management".localized) {
                    settingsButtonRow(icon: "arrow-down-tray", title: "import_data".localized, tint: Color(.systemBlue)) {
                        showingDataImport = true
                    }
                    sectionDivider
                    settingsButtonRow(icon: "arrow-up-tray", title: "export_data".localized, tint: Color(.systemGreen)) {
                        showingDataExport = true
                    }
                    sectionDivider
                    settingsButtonRow(icon: "archive-box", title: "deleted_expenses".localized, tint: Color(.systemGray)) {
                        showingDeletedExpenses = true
                    }
                }

                settingsSection("support".localized) {
                    settingsButtonRow(icon: "hand-raised", title: "privacy_policy".localized, tint: Color(.systemPurple)) {
                        showingPrivacyPolicy = true
                    }
                    sectionDivider
                    settingsButtonRow(
                        icon: "envelope",
                        title: "email_us".localized,
                        tint: Color(.systemBlue),
                        showsChevron: false
                    ) {
                        if let url = URL(string: "mailto:umidjon.muydinov@icloud.com") {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                destructiveSection

                Text(appVersionText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Metrics.horizontalMargin)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Account header card

    private var accountCard: some View {
        let account = appleAccount.account
        let name = account?.fullName.flatMap { $0.isEmpty ? nil : $0 } ?? account?.email
        let title = AppleAccountDisplay.title(for: account)
        let subtitle = AppleAccountDisplay.subtitle(for: account)

        return Button {
            showingAccount = true
        } label: {
            HStack(spacing: Metrics.rowSpacing) {
                avatar(for: name)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                chevron
            }
            .padding(Metrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .clipShape(cardShape)
        .liquidGlassCard(cornerRadius: Metrics.cardRadius)
        .accessibilityIdentifier("settings.account")
    }

    private func avatar(for name: String?) -> some View {
        ZStack {
            Circle().fill(Color.accentColor)
            if let initial = name?.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    // MARK: - iCloud Sync

    /// Sync is automatic, so this is a plain note rather than a row; it only speaks up on a problem.
    private var iCloudSyncSection: some View {
        Label {
            Text(iCloudNoteText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: iCloudStatusIsProblem ? "exclamationmark.icloud" : "checkmark.icloud")
        }
        .font(.footnote)
        .foregroundStyle(iCloudStatusIsProblem ? Color(.systemOrange) : .secondary)
        .padding(.horizontal, Metrics.rowPadding)
        .accessibilityIdentifier("settings.icloudSync.note")
    }

    private var iCloudNoteText: String {
        if cloudSync.accountMismatch { return "icloud_sync_account_mismatch".localized }
        switch cloudSync.status {
        case .noAccount: return "icloud_sync_no_account_footer".localized
        case .restricted: return "icloud_sync_status_restricted".localized
        case .temporarilyUnavailable: return "icloud_sync_status_unavailable".localized
        case .failed(let message): return message
        case .checking, .syncing, .upToDate: return "icloud_sync_footer".localized
        }
    }

    private var iCloudStatusIsProblem: Bool {
        switch cloudSync.status {
        case .noAccount, .restricted, .temporarilyUnavailable, .failed: return true
        default: return cloudSync.accountMismatch
        }
    }


    // MARK: - Money

    private var salaryRow: some View {
        Button {
            showingMonthlySalary = true
        } label: {
            HStack(spacing: Metrics.rowSpacing) {
                iconTile("banknotes", tint: Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("monthly_salaries".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(currentMonthSalaryText)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(currentMonthSalary > 0 ? Color.primary : Color.orange)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Spacer(minLength: 8)

                chevron
            }
            .padding(.horizontal, Metrics.rowPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }

    // MARK: - Building blocks

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, Metrics.rowPadding)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                content()
            }
            .clipShape(cardShape)
            .liquidGlassCard(cornerRadius: Metrics.cardRadius)
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.leading, Metrics.dividerInset)
    }

    private var chevron: some View {
        HeroIcon("chevron-right", size: 13)
            .foregroundStyle(.tertiary)
    }

    private func iconTile(_ icon: String, tint: Color) -> some View {
        HeroIcon(icon, size: Metrics.tileGlyph)
            .foregroundStyle(.white)
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private func settingsButtonRow(
        icon: String,
        title: String,
        tint: Color,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowLabel(icon: icon, title: title, tint: tint, showsChevron: showsChevron)
        }
        .buttonStyle(SettingsPressStyle())
    }

    private func rowLabel(
        icon: String,
        title: String,
        tint: Color,
        trailing: String? = nil,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: Metrics.rowSpacing) {
            iconTile(icon, tint: tint)

            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 12)

            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospaced()
                    .lineLimit(1)
            }

            if showsChevron {
                chevron
            }
        }
        .padding(.horizontal, Metrics.rowPadding)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var destructiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showingAlert = true
            } label: {
                HStack(spacing: Metrics.rowSpacing) {
                    iconTile("trash", tint: Color(.systemRed))
                    Text("clear_data_title".localized)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.systemRed))
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, Metrics.rowPadding)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            .clipShape(cardShape)
            .liquidGlassCard(cornerRadius: Metrics.cardRadius)

            Text("clear_data_footer".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.rowPadding)
        }
    }
}

/// Row highlight like native grouped lists: a soft fill while pressed, no
/// layout change (so nothing shifts under the finger while scrolling).
private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill).opacity(0.6) : Color.clear)
    }
}
