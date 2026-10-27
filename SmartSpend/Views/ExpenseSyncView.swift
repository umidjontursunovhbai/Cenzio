import SwiftUI

/// Integrations screen: Notion is the only provider. Expenses sync through the
/// SmartSpend server, which polls Notion; ExpenseSyncController polls the server.
struct ExpenseSyncView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sync = ExpenseSyncController.shared
    @State private var confirmingConnect = false
    @State private var confirmingDisconnect = false
    @State private var status: ExpenseSyncNotionStatus?
    @State private var busy = false
    @State private var connecting = false
    @State private var connectionMessage: String?
    @State private var refreshError: String?
    @State private var notionPages: [ExpenseSyncNotionPage] = []
    @State private var choosingNotionPage = false
    @State private var available: ExpenseSyncCapabilities?
    @State private var notionSelectionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keep your expenses in a Notion table. Changes made in Notion sync back to this iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                notionCard

                if let connectionMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .accessibilityHidden(true)
                        Text(connectionMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }

                if let refreshError {
                    Label(refreshError, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                if sync.connected {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Sync while the app is open", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                        if let last = sync.lastSynced {
                            Text("Last synced \(last.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            NavigationLink("History & Trash") { ExpenseSyncHistoryView() }
                            Spacer()
                            Button("Sync now") { Task { await sync.sync() } }
                                .disabled(sync.isBusy || !sync.enabled)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                }

                if let message = sync.message {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Needs attention", systemImage: "exclamationmark.circle")
                            .font(.subheadline.weight(.semibold))
                        Text(message).font(.footnote)
                        ForEach(sync.conflicts) { conflict in
                            Text("Expense \(conflict.expenseId.prefix(8)): \(conflict.reason)")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(Color(.systemOrange))
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                }
                if sync.isBusy { ProgressView("Syncing…").font(.footnote) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshConnection() }
        .refreshable { await refreshConnection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshConnection() } }
        }
        .confirmationDialog("Connect Notion?", isPresented: $confirmingConnect, titleVisibility: .visible) {
            Button("Continue to Notion") { Task { await connect() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your current and archived expenses will be securely uploaded for sync. Then choose your Notion account and approve access on its consent screen. You can disconnect at any time. Budgets, salary and microphone audio stay on your iPhone.")
        }
        .confirmationDialog("Disconnect Notion?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await sync.disconnectNotion()
                        status = nil
                        connectionMessage = "Disconnected. Your saved expenses, history and Notion table were kept."
                    } catch { connectionMessage = "Could not disconnect. Try again when you are online." }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Future changes stop syncing with Notion; a change already in progress may finish. Your Notion table and history are kept. To remove Notion's permission entirely, also revoke Cenzio in Notion's settings.") }
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
                                status = try await sync.notionStatus()
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

    private var statusText: String {
        let unavailable = available?.notion == false || status?.configured == false
        if unavailable { return "Not available yet" }
        if status?.needsAttention == true { return "Needs attention" }
        if status?.connected == true { return "Connected" }
        if status?.needsSelection == true { return "Choose a page" }
        if status?.pending == true { return "Connection pending" }
        return "Not connected"
    }

    @ViewBuilder private var notionCard: some View {
        let connected = status?.connected == true
        let pending = status?.pending == true || status?.needsSelection == true || status?.needsAttention == true
        let unavailable = available?.notion == false || status?.configured == false
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                notionIcon
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notion").font(.headline)
                    HStack(spacing: 5) {
                        if connected {
                            Circle().fill(Color(.systemGreen)).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(connected ? Color.primary : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                if connected || pending {
                    Menu {
                        Button(connected ? "Disconnect" : "Cancel connection", role: .destructive) { confirmingDisconnect = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Notion connection options")
                }
            }

            if !connected && !pending {
                Text("Choose a page for a new table, or preview one you already use.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { confirmingConnect = true } label: {
                    HStack(spacing: 8) {
                        if connecting { ProgressView().controlSize(.small) }
                        Text("Connect Notion")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 13))
                .tint(Color.accentColor)
                .disabled(busy || sync.isBusy || unavailable)
                .accessibilityLabel("Connect Notion")
            }
            if connected {
                if let checked = status?.lastChecked {
                    Text("Notion checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = status?.databaseURL {
                    Link(destination: url) {
                        Label("Open in Notion", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                }
            }
            if status?.needsSelection == true {
                Button("Create new table") { Task { await chooseNotionPage() } }
                    .buttonStyle(.bordered).disabled(busy || sync.isBusy)
                NavigationLink("Preview an existing table") { ExistingNotionPreviewView() }
                    .font(.subheadline)
            }
            if status?.needsAttention == true {
                Text(connected
                     ? "Some Notion rows couldn't sync. Check that each row keeps its SmartSpend ID, Category ID, Currency and a date with a time."
                     : "Check Notion for a table already created before canceling this connection. Reconnecting may create a new copy; Cenzio will not retry creation automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status?.pending == true {
                Text("Finish the Notion consent screen in your browser, or use connection options to cancel.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("integration.card.notion")
    }

    private var notionIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(Color.primary.opacity(0.06))
            Image("NotionBrand")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    @MainActor private func connect() async {
        busy = true
        connecting = true
        defer { busy = false; connecting = false }
        do {
            let capabilities = try await sync.capabilities()
            guard capabilities.notion, sync.connected || capabilities.deviceEnrollment else {
                connectionMessage = "Notion connections are not available yet. Your expenses have not been uploaded for this connection."
                return
            }
            try await sync.prepareConnection()
            let url = try await sync.connectNotion()
            connectionMessage = "Complete the Notion consent screen, then return here."
            openURL(url)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            connectionMessage = error as? ExpenseSyncError == .connectionsUnavailable
                ? ExpenseSyncError.connectionsUnavailable.localizedDescription
                : "Couldn't connect right now. Please try again later."
        }
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

    @MainActor private func refreshConnection() async {
        guard !busy else { return }
        busy = true
        refreshError = nil
        defer { busy = false }
        var failure: String?
        do {
            let capabilities = try await sync.capabilities()
            try Task.checkCancellation()
            available = capabilities
        } catch {
            // Leaving the screen/backgrounding cancels requests; that is not a
            // connection failure and must not leave a persistent warning.
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            if error as? ExpenseSyncError == .connectionsUnavailable {
                // This server does not offer account connections yet. Retrying
                // cannot fix a missing endpoint; disable Connect until supported.
                available = ExpenseSyncCapabilities(deviceEnrollment: false, notion: false)
                refreshError = "Account connections aren't available yet. Please try again later."
                return
            }
            failure = "Couldn't check connections. Pull down to retry."
        }
        if sync.connected {
            do {
                let value = try await sync.notionStatus()
                try Task.checkCancellation()
                status = value
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled else { return }
                failure = "Notion connection details could not be loaded. Pull down to retry."
            }
        }
        // A successful refresh clears only refresh errors, not action feedback.
        refreshError = failure
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
            if let item = restoreItem { Text("\(item.after.expense.title) · \(item.after.expense.amount). This changes the connected ledger and updates Notion.") }
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
