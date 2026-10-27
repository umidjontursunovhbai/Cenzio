import SwiftUI
import Combine

struct MainTabView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var tabManager = TabManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAddExpense = false
    /// Bottom safe-area inset of this device: 34 on Face ID iPhones, 0 on Home-button ones.
    @State private var bottomInset: CGFloat = 34

    var body: some View {
        let clearance = CompactTabBar.clearance(bottomInset: bottomInset)
        TabView(selection: $tabManager.selectedTab) {
            Tab("dashboard", image: "hero-home", value: 0) {
                DashboardView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace(clearance)
            }
            Tab("expenses", image: "hero-list-bullet", value: 1) {
                ExpenseListView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace(clearance)
            }
            Tab("recurring", image: "hero-arrow-path", value: 2) {
                RecurringExpensesView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace(clearance)
            }
            Tab("settings", image: "hero-cog-6-tooth", value: 3) {
                SettingsView().toolbar(.hidden, for: .tabBar).reservesCompactTabBarSpace(clearance)
            }
        }
        .tint(Color.accentColor)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { bottomInset = proxy.safeAreaInsets.bottom }
                    .onChange(of: proxy.safeAreaInsets.bottom) { _, inset in bottomInset = inset }
            }
        }
        .overlay(alignment: .bottom) {
            CompactTabBar(selection: $tabManager.selectedTab, bottomInset: bottomInset)
                .ignoresSafeArea(.keyboard)
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView()
        }
        .onAppear {
            dataManager.reloadFromSharedStorage()
            dataManager.processRecurringExpenses()
            checkAddExpenseIntent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .smartSpendOpenAddExpense)) { _ in
            checkAddExpenseIntent()
        }
        .onChange(of: scenePhase) { _, newPhase in
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
    func reservesCompactTabBarSpace(_ clearance: CGFloat) -> some View {
        // TabView pages ignore safe-area insets here, so floating controls
        // read the clearance explicitly.
        self
            .contentMargins(.bottom, clearance, for: .scrollContent)
            .environment(\.floatingTabBarClearance, clearance)
    }
}

/// Icon-only floating capsule (YouTube-style) replacing the taller labeled system tab bar.
private struct CompactTabBar: View {
    /// Visible bar height: 44 + 2 × 6 padding.
    static let barHeight: CGFloat = 56
    /// Face ID iPhones: the bar dips 10pt into the home-indicator area. Home-button
    /// iPhones have no inset, so the bar keeps a gap above the screen edge instead.
    static func bottomOffset(bottomInset: CGFloat) -> CGFloat {
        bottomInset > 0 ? -10 : 8
    }
    /// Space the bar covers above the safe area, reserved at the bottom of each tab.
    static func clearance(bottomInset: CGFloat) -> CGFloat {
        barHeight + bottomOffset(bottomInset: bottomInset)
    }

    @Binding var selection: Int
    let bottomInset: CGFloat

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
        .padding(.bottom, Self.bottomOffset(bottomInset: bottomInset))
        .animation(.snappy(duration: 0.2), value: selection)
    }
}

#Preview {
    MainTabView()
}
