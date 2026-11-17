//
//  ContentView.swift
//  SmartSpend
//
//  Created by Umidjon Tursunov on 23/08/2025.
//

import SwiftUI

struct ContentView: View {
    @State private var initializationError: String?
    
    var body: some View {
        Group {
            if let error = initializationError {
                // Show error screen if initialization fails
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text("Initialization Error")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .padding()
            } else {
                MainTabView()
            }
        }
        .onAppear {
            // Initialize managers
            debugLog("🔄 Initializing managers...")
            _ = DataManager.shared
            debugLog("✅ DataManager initialized")
            _ = TabManager.shared
            debugLog("✅ TabManager initialized")
            debugLog("✅ All managers initialized successfully")
        }
    }
}

#Preview {
    ContentView()
}
