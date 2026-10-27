//
//  SmartSpendApp.swift
//  SmartSpend
//
//  Created by Umidjon Tursunov on 23/08/2025.
//

import AppIntents
import SwiftUI
import UIKit

@main
struct SmartSpendApp: App {
    @UIApplicationDelegateAdaptor(SmartSpendAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .onAppear {
                    print("✅ App window appeared")
                    SmartSpendAppShortcuts.updateAppShortcutParameters()
                }
                // No scroll bars anywhere; this environment value reaches every screen and sheet.
                .scrollIndicators(.hidden)
        }
    }
}

/// Registers for the silent CloudKit pushes that tell iCloud sync another device changed data.
final class SmartSpendAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // No rubber-band overscroll: lists stop at their ends instead of springing past and back.
        UIScrollView.appearance().bounces = false
        // Also covers UIKit-backed scrolling (Form, List) that SwiftUI's modifier may not reach.
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
        CloudSyncController.shared.start()
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["ck"] != nil else { // CloudKit pushes carry a "ck" payload
            completionHandler(.noData)
            return
        }
        Task {
            await CloudSyncController.shared.didReceiveRemoteNotification()
            completionHandler(.newData)
        }
    }
}

/// Shows the welcome screen until the owner signs in with Apple or continues without an
/// account. Expenses stay on device either way; this only decides which screen is visible.
private struct AppRootView: View {
    @StateObject private var account = AppleAccountStore.shared
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let skipsSignIn =
        ProcessInfo.processInfo.environment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] == "1"

    var body: some View {
        Group {
            if Self.skipsSignIn {
                ContentView()
            } else {
                if account.state == .checking {
                    Color(.systemBackground).ignoresSafeArea()
                } else if account.showsWelcome {
                    SignInGateView(store: account)
                        .transition(.opacity)
                } else {
                    ContentView()
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: account.showsWelcome)
        .onAppear { appearance.apply() }
        .onChange(of: appearance) { _, mode in mode.apply() }
        .task {
            guard !Self.skipsSignIn else { return }
            await account.refreshCredentialState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !Self.skipsSignIn else { return }
            CloudSyncController.shared.sceneDidBecomeActive()
            Task { await account.refreshCredentialState() }
        }
    }
}
