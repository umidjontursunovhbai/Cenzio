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
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system
    @Environment(\.colorScheme) private var colorScheme

    private enum Metrics {
        static let horizontalMargin: CGFloat = 24
        static let sectionSpacing: CGFloat = 28
        static let cardRadius: CGFloat = 20
        static let heroRadius: CGFloat = 26
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
                .appBackdrop()
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
                // Sign-in lives only on the launch welcome screen; Settings shows
                // the account just to manage it (sign out, delete) once signed in.
                VStack(alignment: .leading, spacing: 10) {
                    if appleAccount.account != nil {
                        accountCard
                    }
                    iCloudSyncSection
                }

                moneyCard

                settingsSection("settings_section_preferences".localized) {
                    Menu {
                        Picker("appearance".localized, selection: $appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                    } label: {
                        rowLabel(
                            icon: "paint-brush",
                            tint: .indigo,
                            title: "appearance".localized,
                            trailing: appearance.title,
                            showsChevron: false
                        )
                    }
                    .buttonStyle(SettingsPressStyle())
                    .accessibilityIdentifier("settings.appearance")

                    sectionDivider

                    NavigationLink(destination: CategoryManagementView()) {
                        rowLabel(icon: "tag", tint: .orange, title: "categories".localized)
                    }
                    .buttonStyle(SettingsPressStyle())
                }

                settingsSection("data_management".localized) {
                    settingsButtonRow(icon: "arrow-down-tray", tint: .cyan, title: "import_data".localized) {
                        showingDataImport = true
                    }
                    sectionDivider
                    settingsButtonRow(icon: "arrow-up-tray", tint: .teal, title: "export_data".localized) {
                        showingDataExport = true
                    }
                    sectionDivider
                    settingsButtonRow(icon: "archive-box", tint: Color(.systemGray), title: "deleted_expenses".localized) {
                        showingDeletedExpenses = true
                    }
                }

                settingsSection("support".localized) {
                    settingsButtonRow(icon: "hand-raised", tint: .purple, title: "privacy_policy".localized) {
                        showingPrivacyPolicy = true
                    }
                    sectionDivider
                    settingsButtonRow(
                        icon: "envelope",
                        tint: .blue,
                        title: "email_us".localized,
                        showsChevron: false
                    ) {
                        if let url = URL(string: "mailto:umidjon.muydinov@icloud.com") {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                destructiveSection
                    .padding(.top, 8)

                Text(appVersionText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.horizontalMargin)
            .padding(.top, 8)
            .padding(.bottom, 32)
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
            Circle().fill(
                LinearGradient(
                    colors: [Color.indigo, Color.blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
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
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
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
        .padding(.vertical, iCloudStatusIsProblem ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A problem gets a tinted plate so it reads as something to act on;
            // the normal state stays a quiet line of text.
            if iCloudStatusIsProblem {
                cardShape.fill(Color(.systemOrange).opacity(0.12))
            }
        }
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

    /// The one card with its own light: salary up top, currency and budget
    /// goals as chips below it. A soft green glow sits inside the glass so the
    /// screen has a warm focal point instead of a stack of identical black rows.
    private var moneyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showingMonthlySalary = true
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        iconTile("banknotes", tint: .green)
                        Text("settings_salary_this_month".localized)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        chevron
                    }

                    Text(currentMonthSalaryText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(currentMonthSalary > 0 ? Color.primary : Color(.systemOrange))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .padding(.horizontal, Metrics.rowPadding + 2)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
            .accessibilityIdentifier("settings.salary")

            HStack(spacing: 10) {
                moneyChip(
                    icon: "credit-card",
                    tint: .blue,
                    title: "currency".localized,
                    value: dataManager.user.currency.rawValue
                ) {
                    showingCurrencySelection = true
                }
                // Budget Goals owns its NavigationStack and Done button, so present it like Dashboard does.
                moneyChip(
                    icon: "flag",
                    tint: .orange,
                    title: "budget_goals".localized,
                    value: nil
                ) {
                    showingBudgetGoals = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(alignment: .topLeading) {
            RadialGradient(
                colors: [Color.green.opacity(colorScheme == .dark ? 0.26 : 0.14), .clear],
                center: UnitPoint(x: 0.05, y: 0.0),
                startRadius: 0,
                endRadius: 280
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(heroShape)
        .liquidGlassCard(cornerRadius: Metrics.heroRadius)
    }

    private func moneyChip(
        icon: String,
        tint: Color,
        title: String,
        value: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HeroIcon(icon, size: 16)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(iOSDesignSystem.insetFill, in: chipShape)
            .contentShape(chipShape)
        }
        .buttonStyle(ChipPressStyle())
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var heroShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.heroRadius, style: .continuous)
    }

    // MARK: - Building blocks

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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

    /// A solid system-hue tile with a white glyph, like the iOS Settings app.
    /// Each row keeps its own hue so the eye finds it by color; on black glass
    /// these tiles are the screen's color.
    private func iconTile(_ icon: String, tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HeroIcon(icon, size: Metrics.tileGlyph)
            .foregroundStyle(.white)
            .frame(width: Metrics.tileSize, height: Metrics.tileSize)
            .background(tint.gradient, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private func settingsButtonRow(
        icon: String,
        tint: Color,
        title: String,
        showsChevron: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowLabel(icon: icon, tint: tint, title: title, showsChevron: showsChevron)
        }
        .buttonStyle(SettingsPressStyle())
    }

    private func rowLabel(
        icon: String,
        tint: Color,
        title: String,
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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsChevron {
                chevron
            } else if trailing != nil {
                // Menus open in place, so they get the up-down glyph instead of a chevron.
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
            .background(Color(.systemRed).opacity(colorScheme == .dark ? 0.10 : 0.06))
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
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
    }
}

/// Chips dim and shrink a touch while pressed; they sit on their own fill,
/// so a background highlight would not read.
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Grouped list backdrop

extension View {
    /// For `.insetGrouped` List/Form screens. Dark mode hides the gray grouped
    /// background so the black backdrop shows; light mode keeps the system look.
    /// Pair rows with `.listRowBackground(iOSDesignSystem.elevatedBackground)`.
    func groupedListBackdrop() -> some View {
        modifier(GroupedListBackdrop())
    }
}

private struct GroupedListBackdrop: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
            .appBackdrop()
    }
}

// MARK: - Settings-area fills

extension iOSDesignSystem {
    /// Quiet well/chip fill: light keeps systemGray6, dark is a faint white on black.
    static let settingsWellFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.05) : UIColor.systemGray6
    })

    /// Nested card plate: light keeps the tertiary grouped gray, dark is the near-black plate.
    static let settingsNestedPlate = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.02, alpha: 1)
            : UIColor.tertiarySystemGroupedBackground
    })
}
