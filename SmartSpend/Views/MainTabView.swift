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
        // iOS 26: the system tab bar, which has Apple's real Liquid Glass lens
        // (press, drag, water-drop refraction). Older iOS keeps the compact bar.
        let clearance = Self.usesNativeTabBar ? 0 : CompactTabBar.clearance(bottomInset: bottomInset)
        let tabBarVisibility: Visibility = Self.usesNativeTabBar ? .visible : .hidden
        TabView(selection: $tabManager.selectedTab) {
            Tab(value: 0) {
                DashboardView().toolbar(tabBarVisibility, for: .tabBar).reservesCompactTabBarSpace(clearance)
            } label: {
                // Icon only; the title stays as the VoiceOver label.
                Image("hero-home", label: Text("dashboard".localized))
            }
            Tab(value: 1) {
                ExpenseListView().toolbar(tabBarVisibility, for: .tabBar).reservesCompactTabBarSpace(clearance)
            } label: {
                // Icon only; the title stays as the VoiceOver label.
                Image("hero-list-bullet", label: Text("expenses".localized))
            }
            Tab(value: 2) {
                RecurringExpensesView().toolbar(tabBarVisibility, for: .tabBar).reservesCompactTabBarSpace(clearance)
            } label: {
                // Icon only; the title stays as the VoiceOver label.
                Image("hero-arrow-path", label: Text("recurring".localized))
            }
            Tab(value: 3) {
                SettingsView().toolbar(tabBarVisibility, for: .tabBar).reservesCompactTabBarSpace(clearance)
            } label: {
                // Icon only; the title stays as the VoiceOver label.
                Image("hero-cog-6-tooth", label: Text("settings".localized))
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
            if !Self.usesNativeTabBar {
                CompactTabBar(selection: $tabManager.selectedTab, bottomInset: bottomInset)
                    .ignoresSafeArea(.keyboard)
            }
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

    private static var usesNativeTabBar: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lens center while a finger is down; nil when the lens rests on the selected tab.
    @State private var dragX: CGFloat?
    @State private var dragVelocity: CGFloat = 0
    /// Tab under the lens, for the selection haptic while dragging.
    @State private var hoverIndex: Int?

    private let itemWidth: CGFloat = 76
    private let itemHeight: CGFloat = 44
    private let itemSpacing: CGFloat = 4

    private let items: [(image: String, key: String, id: String)] = [
        ("hero-home", "dashboard", "tab.dashboard"),
        ("hero-list-bullet", "expenses", "tab.expenses"),
        ("hero-arrow-path", "recurring", "tab.recurring"),
        ("hero-cog-6-tooth", "settings", "tab.settings")
    ]

    private var isPressed: Bool { dragX != nil }

    private func center(of index: Int) -> CGFloat {
        CGFloat(index) * (itemWidth + itemSpacing) + itemWidth / 2
    }

    private func index(at x: CGFloat) -> Int {
        let raw = Int((x / (itemWidth + itemSpacing)).rounded(.down))
        return min(max(raw, 0), items.count - 1)
    }

    private func clampedCenter(_ x: CGFloat) -> CGFloat {
        min(max(x, center(of: 0)), center(of: items.count - 1))
    }

    /// Critically damped settle (no overshoot on fast taps); a plain fade-speed ease when Reduce Motion is on.
    private var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1)
    }
    private var follow: Animation {
        reduceMotion ? .linear(duration: 0) : .interactiveSpring(response: 0.22, dampingFraction: 0.78)
    }

    var body: some View {
        let lensX = dragX ?? center(of: selection)
        let litIndex = index(at: lensX)
        // The lens swells while held and stretches along the drag, like a drop of liquid.
        let stretch = reduceMotion ? 0 : min(abs(dragVelocity) / 2600, 0.28)
        let lensScale = CGSize(
            width: (isPressed && !reduceMotion ? 1.12 : 1) + stretch,
            height: (isPressed && !reduceMotion ? 1.16 : 1) - stretch * 0.35
        )

        ZStack(alignment: .leading) {
            lens
                .frame(width: itemWidth, height: itemHeight)
                .scaleEffect(lensScale)
                .offset(x: lensX - itemWidth / 2)

            HStack(spacing: itemSpacing) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    let isLit = litIndex == index
                    Image(item.image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .scaleEffect(isLit && isPressed && !reduceMotion ? 1.12 : 1)
                        .foregroundStyle(isLit ? Color.primary : Color.primary.opacity(0.5))
                        .frame(width: itemWidth, height: itemHeight)
                        .contentShape(Capsule())
                        .accessibilityElement()
                        .accessibilityLabel(item.key.localized)
                        .accessibilityIdentifier(item.id)
                        .accessibilityAddTraits(selection == index ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { selection = index }
                }
            }
        }
        .coordinateSpace(name: "compactTabBar")
        .contentShape(Capsule())
        // One gesture for tap and drag: press anywhere, slide the lens across the
        // tabs, release to switch to the tab under it.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("compactTabBar"))
                .onChanged { value in
                    let x = clampedCenter(value.location.x)
                    withAnimation(dragX == nil ? settle : follow) {
                        dragX = x
                        dragVelocity = value.velocity.width
                    }
                    hoverIndex = index(at: x)
                }
                .onEnded { value in
                    let target = index(at: clampedCenter(value.location.x))
                    withAnimation(settle) {
                        selection = target
                        dragX = nil
                        dragVelocity = 0
                    }
                    hoverIndex = nil
                }
        )
        .sensoryFeedback(.selection, trigger: hoverIndex) { _, new in new != nil }
        .padding(6)
        .liquidGlassSurface(Capsule())
        .padding(.bottom, Self.bottomOffset(bottomInset: bottomInset))
    }

    /// The moving selection lens: a soft fill plus a clear Liquid Glass layer on
    /// iOS 26 so it bends the icons and bar beneath it as it slides.
    @ViewBuilder
    private var lens: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(iOSDesignSystem.selectionFill)
                .glassEffect(.clear.interactive(), in: Capsule())
        } else {
            Capsule()
                .fill(iOSDesignSystem.selectionFill)
        }
    }
}

#Preview {
    MainTabView()
}
