import SwiftUI

struct ExpenseSyncView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sync = ExpenseSyncController.shared
    @State private var server = ""
    @State private var token = ""
    @State private var bootstrap = true
    @State private var consent = false
    @State private var googleConsent = false
    @State private var google: ExpenseSyncGoogleStatus?
    @State private var googleBusy = false
    @State private var googleMessage: String?

    var body: some View {
        Form {
            Section {
                Label("Your expenses, connected", systemImage: "arrow.triangle.2.circlepath")
                Text("Connect your private SmartSpend server to exchange expense changes with AI tools, Google Sheets and Notion. Each external provider must also be connected on your server.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if sync.connected {
                Section {
                    Toggle("Sync while the app is open", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                    if let last = sync.lastSynced { Text("Last synced \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await sync.sync() } }.disabled(sync.isBusy || !sync.enabled)
                    NavigationLink("History & Trash") { ExpenseSyncHistoryView() }
                    Button("Disconnect this iPhone", role: .destructive) { sync.disconnect() }.disabled(sync.isBusy)
                } header: { Text("Connection") } footer: {
                    Text("Changes are checked about every 12 seconds while SmartSpend is open. Offline edits stay on this iPhone and retry later. There is no background real-time sync.")
                }
                Section {
                    if google?.connected == true {
                        Label("Google Sheets connected", systemImage: "checkmark.circle")
                        if let url = google?.spreadsheetURL { Link("Open SmartSpend sheet", destination: url) }
                    } else {
                        Button(google?.pending == true ? "Continue connecting Google Sheets…" : "Connect Google Sheets…") { googleConsent = true }
                            .disabled(googleBusy)
                    }
                    Button("Refresh Google connection") { Task { await refreshGoogle() } }.disabled(googleBusy)
                    if googleBusy { ProgressView() }
                    if let googleMessage { Text(googleMessage).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Google Sheets") } footer: {
                    Text("Creates a new dedicated SmartSpend spreadsheet. Expense changes sync with that sheet; choosing an existing sheet is not supported here. Notion currently requires administrator setup on your server.")
                }
            } else {
                Section {
                    TextField("https://your-server.example", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Dedicated sync access token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Initialize an empty server with this ledger", isOn: $bootstrap)
                    Button("Connect…") { consent = true }
                        .disabled(sync.isBusy || token.isEmpty || server.isEmpty)
                } header: { Text("Private server") } footer: {
                    Text("Use a personal, revocable sync credential issued by your server administrator. Voice credentials cannot be used. Connecting an existing different ledger is blocked; use reviewed file exchange first.")
                }
            }
            if let message = sync.message {
                Section("Needs attention") {
                    Text(message).foregroundStyle(.orange)
                    ForEach(sync.conflicts) { conflict in
                        Text("Expense \(conflict.expenseId.prefix(8)): \(conflict.reason)").font(.caption)
                    }
                    Text("No conflict is silently overwritten. Review versions in History & Trash. Resume only after resolving both copies through reviewed file exchange.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if sync.isBusy { ProgressView("Connecting safely…") }
            Section("Privacy") {
                Text("Connecting shares titles, amounts, dates, categories, and archived expenses with your server. Budgets, goals, salary, preferences and microphone audio are not included. Turning sync off stops future exchanges; it does not erase the server copy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Expense sync")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshGoogle() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshGoogle() } }
        }
        .confirmationDialog("Connect Google Sheets?", isPresented: $googleConsent, titleVisibility: .visible) {
            Button("Continue to Google") {
                Task {
                    googleBusy = true
                    defer { googleBusy = false }
                    do {
                        let url = try await sync.connectGoogle()
                        googleMessage = "Complete Google's consent screen, then return here."
                        openURL(url)
                    } catch { googleMessage = "Could not start the Google connection. Check your server configuration and try again." }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Google will ask for permission to create and use a new dedicated SmartSpend spreadsheet. Your server will sync expense titles, amounts, dates, categories and archive status with this sheet. Budgets, salary and microphone audio are not shared. You can cancel on Google's screen.")
        }
        .confirmationDialog("Share this expense ledger with your server?", isPresented: $consent, titleVisibility: .visible) {
            Button("Share expenses & enable sync") {
                Task {
                    await sync.connect(server: server, token: token, bootstrap: bootstrap)
                    if sync.connected { token = "" }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your complete current and archived expense ledger is uploaded when initializing an empty server. Connected AI and external providers may read or change it according to their permissions. Keep a separate backup.")
        }
    }

    @MainActor private func refreshGoogle() async {
        guard sync.connected, !googleBusy else { return }
        googleBusy = true
        defer { googleBusy = false }
        do {
            google = try await sync.googleStatus()
            googleMessage = google?.pending == true ? "Waiting for Google consent. Complete the browser step, then refresh." : nil
        } catch { googleMessage = "Google connection status is unavailable. Check your server configuration and try again." }
    }
}

struct ExpenseSyncHistoryView: View {
    @ObservedObject private var sync = ExpenseSyncController.shared
    @State private var selected: String?
    @State private var items: [ExpenseSyncHistoryItem] = []
    @State private var after = 0
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var restoreItem: ExpenseSyncHistoryItem?

    var body: some View {
        List {
            Section("Expenses and Trash") {
                ForEach((sync.state?.baseline.values.map { $0 } ?? []).sorted { $0.expense.title < $1.expense.title }, id: \.expense.id) { record in
                    Button {
                        selected = record.expense.id
                        items = []
                        after = 0
                        Task { await load() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(record.expense.title)
                                Text("\(record.expense.amount) \(sync.state?.currency ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if record.archived { Image(systemName: "trash").foregroundStyle(.orange) }
                            if selected == record.expense.id { Image(systemName: "chevron.down") }
                        }
                    }.foregroundStyle(.primary)
                }
            }
            if selected != nil {
                Section("Saved versions") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.after.expense.title).font(.headline)
                            Text("\(item.after.expense.amount) · \(item.after.expense.date.prefix(10))")
                            Text("\(item.kind.replacingOccurrences(of: "_", with: " ").capitalized) · \(item.source) · revision \(item.after.revision)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let before = item.before {
                                Text("Before: \(before.expense.title) · \(before.expense.amount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Restore this version") { restoreItem = item }.disabled(loading || sync.isBusy)
                        }.padding(.vertical, 4)
                    }
                    if more { Button("Load more versions") { Task { await load() } }.disabled(loading) }
                    if loading { ProgressView() }
                    if !loading && items.isEmpty { Text("No server history for this expense yet.").foregroundStyle(.secondary) }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                Text("Trash keeps deleted expenses. Restoring creates a new history entry; it never erases the previous versions. History is not a substitute for a separate backup.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("History & Trash")
        .confirmationDialog("Restore this saved version?", isPresented: Binding(get: { restoreItem != nil }, set: { if !$0 { restoreItem = nil } }), titleVisibility: .visible) {
            if let item = restoreItem {
                Button("Restore \(item.after.expense.title)") {
                    Task {
                        do { try await sync.restore(item); items = []; after = 0; await load() }
                        catch { self.error = error.localizedDescription }
                        restoreItem = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { restoreItem = nil }
        } message: {
            if let item = restoreItem { Text("\(item.after.expense.title) · \(item.after.expense.amount). This changes the connected ledger and propagates to enabled providers.") }
        }
    }

    @MainActor private func load() async {
        guard !loading, let selected else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await sync.history(expenseId: selected, after: after)
            guard self.selected == selected else { return }
            items.append(contentsOf: page.items)
            after = page.nextSequence
            more = page.hasMore
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
