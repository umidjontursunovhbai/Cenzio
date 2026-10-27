import SwiftUI
import UniformTypeIdentifiers

struct MCPIntegrationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared
    @State private var exportDocument: MCPJSONFile?
    @State private var showingExport = false
    @State private var showingImport = false
    @State private var document: MCPExpenseOperationsDocument?
    @State private var plan: MCPExpenseExchangePlan?
    @State private var message: String?
    @State private var showingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Expense sync & history") {
                        ExpenseSyncView()
                    }
                    NavigationLink(voiceText("Voice connection", "Подключение голоса")) {
                        VoiceConnectionView()
                    }
                }
                Section {
                    Label("Manual file exchange", systemImage: "doc.badge.arrow.up")
                    Text("Share an expense snapshot with your private Cenzio MCP server. Review its changes here before applying them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("This does not connect ChatGPT or enable live sync. Nothing is uploaded automatically.")
                }

                Section {
                    Button("Export snapshot", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = MCPJSONFile(data: try dataManager.exportMCPSnapshot())
                            showingExport = true
                        } catch { message = error.localizedDescription }
                    }
                } header: {
                    Text("Share with your AI")
                } footer: {
                    Text("The JSON includes expense titles, amounts, dates, categories and archived expenses. Share it only with a server or AI you trust. It does not include income, budgets or goals.")
                }

                Section {
                    Button("Review AI changes", systemImage: "square.and.arrow.down") {
                        showingImport = true
                    }
                } footer: {
                    Text("Choose the operations JSON from your MCP server. Changed or duplicate records are checked before anything is saved.")
                }

                if let plan {
                    Section("Changes to apply") {
                        if plan.changes.isEmpty {
                            Text("No new changes. These operations were already applied.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(plan.changes) { change in
                            changeRow(change)
                        }
                        if plan.skippedCount > 0 {
                            Text("\(plan.skippedCount) previously applied operations will be skipped.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if !plan.changes.isEmpty {
                            Button("Apply \(plan.changes.count) changes") {
                                showingConfirmation = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("AI tools (MCP)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .fileExporter(isPresented: $showingExport, document: exportDocument,
                          contentType: .json, defaultFilename: "Cenzio-MCP-snapshot") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $showingImport, allowedContentTypes: [.json]) { result in
                document = nil
                plan = nil
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: MCPExpenseExchange.maximumFileBytes + 1) ?? Data()
                    let incoming = try MCPExpenseExchange.decodeOperations(data)
                    dataManager.reloadFromSharedStorage()
                    plan = try dataManager.previewMCPChanges(incoming)
                    document = incoming
                } catch { message = error.localizedDescription }
            }
            .confirmationDialog("Apply the reviewed AI changes?", isPresented: $showingConfirmation,
                                titleVisibility: .visible) {
                Button("Apply changes") {
                    guard let document else { return }
                    do {
                        let count = try dataManager.applyMCPChanges(document)
                        self.document = nil
                        plan = nil
                        message = "Applied \(count) changes. Export a fresh snapshot to acknowledge them to your MCP server."
                    } catch {
                        plan = nil
                        self.document = nil
                        message = error.localizedDescription
                    }
                }
            } message: {
                Text("Cenzio will check the current records again. A conflict stops the entire batch; archived expenses remain in Deleted Expenses.")
            }
            .alert("AI file exchange", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func expenseTitle(_ id: String) -> String {
        dataManager.expenses.first { $0.id.uuidString.lowercased() == id }?.title ?? "Expense"
    }

    private func categoryName(_ id: String) -> String {
        dataManager.userCategories.first { $0.id.uuidString.lowercased() == id }?.name ?? "Category"
    }

    private func changeRow(_ change: MCPExpenseOperation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(change.kind.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(change.kind == .archive ? Color.orange : Color.secondary)
            Text(change.expense?.title ?? expenseTitle(change.expenseId))
                .font(.headline)
            if change.kind == .update,
               let current = dataManager.expenses.first(where: { $0.id.uuidString.lowercased() == change.expenseId }) {
                Text("Currently in app: \(current.title) · \(amountText(String(current.amount)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let expense = change.expense {
                Text(amountText(expense.amount)).monospacedDigit()
                Text(categoryName(expense.categoryId))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(MCPExpenseExchange.dateFormatter.date(from: expense.date)?.formatted(date: .abbreviated, time: .shortened) ?? expense.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func amountText(_ amount: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = MCPExpenseExchange.locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        let formatted = formatter.string(from: NSDecimalNumber(string: amount)) ?? amount
        let unit = dataManager.user.currency == .uzs ? "so'm" : dataManager.user.currency.rawValue
        return "\(formatted) \(unit)"
    }
}

private struct MCPJSONFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
