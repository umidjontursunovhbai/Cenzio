import SwiftUI

struct ExpenseSyncView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sync = ExpenseSyncController.shared
    @State private var consentProvider: ExpenseSyncProvider?
    @State private var disconnectProvider: ExpenseSyncProvider?
    @State private var statuses: [ExpenseSyncProvider: ExpenseSyncProviderStatus] = [:]
    @State private var busy = false
    @State private var connectionMessage: String?
    @State private var notionPages: [ExpenseSyncNotionPage] = []
    @State private var choosingNotionPage = false
    @State private var available: ExpenseSyncCapabilities?
    @State private var notionSelectionMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Connect your own accounts")
                    .font(.headline)
                Text("Keep your expenses in Google Sheets or Notion. Connections are optional, and you choose which accounts to use.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                ForEach(ExpenseSyncProvider.allCases) { provider in
                    providerRow(provider)
                }
                if busy { ProgressView("Connecting…") }
                if let connectionMessage { Text(connectionMessage).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Google Sheets creates a dedicated spreadsheet. For Notion, choose a page for a dedicated expense database. Existing files and pages are not replaced.")
            }
            if sync.connected {
                Section {
                    Toggle("Sync while the app is open", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                    if let last = sync.lastSynced { Text("Last synced \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await sync.sync() } }.disabled(sync.isBusy || !sync.enabled)
                    NavigationLink("History & Trash") { ExpenseSyncHistoryView() }
                } header: { Text("Connection") } footer: {
                    Text("Changes sync while SmartSpend is open. Offline edits stay on your iPhone and retry when you reconnect.")
                }
            }
            if let message = sync.message {
                Section("Needs attention") {
                    Text(message).foregroundStyle(.orange)
                    ForEach(sync.conflicts) { conflict in
                        Text("Expense \(conflict.expenseId.prefix(8)): \(conflict.reason)").font(.caption)
                    }
                    Text("Neither copy is overwritten automatically. Keep a backup and review the saved versions before continuing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if sync.isBusy { ProgressView("Connecting safely…") }
            Section("Privacy") {
                Text("Connecting sends your current and archived expenses, dates, amounts and categories to SmartSpend's sync service and the account you choose. Budgets, goals, salary and microphone audio are not included. Disconnecting stops future changes; saved copies and history are not erased.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshConnections() }
        .refreshable { await refreshConnections() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshConnections() } }
        }
        .confirmationDialog("Connect \(consentProvider?.name ?? "account")?", isPresented: Binding(get: { consentProvider != nil }, set: { if !$0 { consentProvider = nil } }), titleVisibility: .visible) {
            if let provider = consentProvider {
                Button("Continue to \(provider == .google ? "Google" : "Notion")") {
                    Task { await connect(provider) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your current and archived expenses will be securely uploaded for sync. Then choose your account and approve access on its consent screen. You can disconnect at any time. Budgets, salary and microphone audio stay on your iPhone.")
        }
        .confirmationDialog("Disconnect \(disconnectProvider?.name ?? "account")?", isPresented: Binding(get: { disconnectProvider != nil }, set: { if !$0 { disconnectProvider = nil } }), titleVisibility: .visible) {
            if let provider = disconnectProvider {
                Button("Disconnect", role: .destructive) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await sync.disconnectProvider(provider)
                            statuses[provider] = nil
                            connectionMessage = "Disconnected. Your saved expenses, history and external copies were kept."
                        } catch { connectionMessage = "Could not disconnect. Try again when you are online." }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Future changes stop syncing with this account; a change already in progress may finish. External files and history are kept. To remove Google's or Notion's permission entirely, also revoke SmartSpend in that account's settings.") }
        .sheet(isPresented: $choosingNotionPage) {
            NavigationStack {
                List(notionPages) { page in
                    Button(page.title.isEmpty ? "Untitled page" : page.title) {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                try await sync.selectNotionPage(page)
                                choosingNotionPage = false
                                statuses[.notion] = try await sync.providerStatus(.notion)
                            } catch { notionSelectionMessage = "Could not create the expense database. Try again." }
                        }
                    }.disabled(busy)
                }
                .navigationTitle("Choose a Notion page")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingNotionPage = false } } }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if let notionSelectionMessage { Text(notionSelectionMessage).foregroundStyle(.orange) }
                        Text("A new expense database will be created inside this page. Existing content is kept.")
                            .foregroundStyle(.secondary)
                    }.font(.footnote).padding()
                }
            }
        }
    }

    @ViewBuilder private func providerRow(_ provider: ExpenseSyncProvider) -> some View {
        let status = statuses[provider]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.headline)
                    Text(available?.supports(provider) == false || status?.configured == false ? "Not available yet" : status?.needsAttention == true ? "Needs attention" : status?.connected == true ? "Connected" : status?.needsSelection == true ? "Choose a page to finish" : status?.pending == true ? "Finish in your browser" : "Not connected")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if status?.connected == true || status?.pending == true || status?.needsSelection == true || status?.needsAttention == true {
                    Menu {
                        Button(status?.connected == true ? "Disconnect" : "Cancel connection", role: .destructive) { disconnectProvider = provider }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }.accessibilityLabel("\(provider.name) connection options")
                } else {
                    Button("Connect") { consentProvider = provider }
                        .buttonStyle(.bordered).disabled(busy || sync.isBusy || available?.supports(provider) == false)
                }
            }
            if provider == .google, let url = status?.spreadsheetURL {
                Link("Open spreadsheet", destination: url).font(.subheadline)
            }
            if provider == .notion, status?.needsSelection == true {
                Button("Create new table") { Task { await chooseNotionPage() } }
                    .buttonStyle(.bordered).disabled(busy || sync.isBusy)
                NavigationLink("Preview an existing table") { ExistingNotionPreviewView() }
                    .font(.subheadline)
            }
            if status?.needsAttention == true {
                Text("Check your account for a table or spreadsheet already created before canceling this connection. Reconnecting may create a new copy; SmartSpend will not retry creation automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if status?.pending == true {
                Text("Finish the consent screen in your browser, or use connection options to cancel. If a file may already have been created, review it before reconnecting.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }

    @MainActor private func connect(_ provider: ExpenseSyncProvider) async {
        busy = true
        defer { busy = false }
        do {
            let capabilities = try await sync.capabilities()
            guard capabilities.supports(provider), sync.connected || capabilities.deviceEnrollment else {
                connectionMessage = "\(provider.name) connections are not available yet. Your expenses have not been uploaded for this connection."
                return
            }
            try await sync.prepareConnection()
            let url = try await sync.connectProvider(provider)
            connectionMessage = "Complete the \(provider == .google ? "Google" : "Notion") consent screen, then return here."
            openURL(url)
        } catch { connectionMessage = "This connection is unavailable right now. Please try again later. No existing files were replaced." }
    }

    @MainActor private func chooseNotionPage() async {
        busy = true
        defer { busy = false }
        do {
            notionPages = try await sync.notionPages()
            if notionPages.isEmpty { connectionMessage = "No Notion pages are shared. Reconnect and select a page on Notion's consent screen." }
            else { choosingNotionPage = true }
        } catch { connectionMessage = "Could not load your Notion pages. Try again." }
    }

    @MainActor private func refreshConnections() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { available = try await sync.capabilities() }
        catch { connectionMessage = "Connection availability could not be checked. Try again when you are online." }
        guard sync.connected else { return }
        for provider in ExpenseSyncProvider.allCases {
            do { statuses[provider] = try await sync.providerStatus(provider) }
            catch { connectionMessage = "Some connection details could not be loaded. Pull to refresh or try again later." }
        }
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
