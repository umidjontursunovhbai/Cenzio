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
                DashboardView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace()
            }
            Tab("expenses", image: "hero-list-bullet", value: 1) {
                ExpenseListView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace()
            }
            Tab("recurring", image: "hero-arrow-path", value: 2) {
                RecurringExpensesView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace()
            }
            Tab("settings", image: "hero-cog-6-tooth", value: 3) {
                SettingsView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace()
            }
        }
        .tint(Color.accentColor)
        .overlay(alignment: .bottom) {
            CompactTabBar(selection: $tabManager.selectedTab)
                .ignoresSafeArea(.keyboard)
        }
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
        let defaults = UserDefaults(suiteName: "group.ai.humblebee.smartspend") ?? UserDefaults.standard
        guard defaults.bool(forKey: "openAddExpense") else { return }
        defaults.removeObject(forKey: "openAddExpense")
        tabManager.switchToExpensesTab()
        DispatchQueue.main.async {
            showingAddExpense = true
        }
    }
}

private extension View {
    /// Lifts a tab's content (scroll insets, bottom overlays like the entry bar)
    /// above the floating tab bar, the way the system tab bar would.
    func reservesCompactTabBarSpace() -> some View {
        // TabView pages ignore safe-area insets here, so floating controls
        // read the clearance explicitly.
        self
            .contentMargins(.bottom, CompactTabBar.reservedHeight, for: .scrollContent)
            .environment(\.floatingTabBarClearance, CompactTabBar.reservedHeight)
    }
}

/// Icon-only floating capsule (YouTube-style) replacing the taller labeled system tab bar.
private struct CompactTabBar: View {
    /// Visible bar height (44 + 2 × 6 padding) minus the 10pt it dips below the safe area.
    static let reservedHeight: CGFloat = 46

    @Binding var selection: Int

    private let items: [(image: String, key: String, id: String)] = [
        ("hero-home", "dashboard", "tab.dashboard"),
        ("hero-list-bullet", "expenses", "tab.expenses"),
        ("hero-arrow-path", "recurring", "tab.recurring"),
        ("hero-cog-6-tooth", "settings", "tab.settings")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isSelected = selection == index
                Button {
                    selection = index
                } label: {
                    Image(item.image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(width: 76, height: 44)
                        .background {
                            if isSelected {
                                Capsule().fill(Color(.systemGray5))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.key.localized)
                .accessibilityIdentifier(item.id)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(6)
        .liquidGlassSurface(Capsule())
        .padding(.bottom, -10)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

#Preview {
    MainTabView()
}
