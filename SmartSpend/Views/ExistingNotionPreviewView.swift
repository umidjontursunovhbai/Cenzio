import SwiftUI

struct ExistingNotionSource: Decodable, Identifiable {
    struct Property: Decodable {
        let type: String
        let options: [String]?
    }
    let id: String
    let title: String
    let schema: [String: Property]
    func fields(of types: Set<String>) -> [String] {
        schema.filter { types.contains($0.value.type) }.keys.sorted()
    }
}

struct ExistingNotionMapping: Encodable {
    let title: String
    let amount: String
    let date: String
    let category: String
    let categoryMap: [String: String]
}

struct ExistingNotionPreview: Decodable {
    let readOnly: Bool
    let dataSourceId: String
    let currency: String
    let timeZone: String
    let totalRows: Int
    let validRows: Int
    let excludedArchivedRows: Int
    let unmappedCategories: [String]
    let samples: [MCPExpenseRecord]
    let hasMore: Bool
    let canSync: Bool
}

enum ExistingNotionPreviewDate {
    static func label(_ text: String, timeZone: String, locale: Locale = .current) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: text)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: text)
        }
        guard let date, let zone = TimeZone(identifier: timeZone) else { return "Date unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// An explicit, read-only mapping preview. This view never imports or binds a table.
struct ExistingNotionPreviewView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var sync = ExpenseSyncController.shared
    @State private var sources: [ExistingNotionSource] = []
    @State private var selected = ""
    @State private var titleField = ""
    @State private var amountField = ""
    @State private var dateField = ""
    @State private var categoryField = ""
    @State private var categoryMap: [String: String] = [:]
    @State private var preview: ExistingNotionPreview?
    @State private var busy = false
    @State private var message: String?
    @State private var consent = false

    private var source: ExistingNotionSource? { sources.first { $0.id == selected } }
    private var mapped: Bool { !titleField.isEmpty && !amountField.isEmpty && !dateField.isEmpty && !categoryField.isEmpty }
    private var categoryLabels: [String] {
        Array(Set((source?.schema[categoryField]?.options ?? []) + (preview?.unmappedCategories ?? []))).sorted()
    }

    var body: some View {
        Form {
            Section {
                Text("Preview only")
                    .font(.headline)
                Text("Check an existing Notion expense table without changing or importing anything. Existing tables are not syncing yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Notion table") {
                Picker("Table", selection: $selected) {
                    Text("Choose a table").tag("")
                    ForEach(sources) { item in Text(item.title.isEmpty ? "Untitled table" : item.title).tag(item.id) }
                }
                if sources.isEmpty && !busy {
                    Text("No tables found. Share the page containing your table with Cenzio in Notion, then reconnect.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let source {
                Section("Match your columns") {
                    fieldPicker("Title", values: source.fields(of: ["title"]), selection: $titleField)
                    fieldPicker("Amount", values: source.fields(of: ["number"]), selection: $amountField)
                    fieldPicker("Date", values: source.fields(of: ["date"]), selection: $dateField)
                    fieldPicker("Category", values: source.fields(of: ["select", "rich_text"]), selection: $categoryField)
                }
                if !categoryLabels.isEmpty {
                    Section("Match your categories") {
                        ForEach(categoryLabels, id: \.self) { label in
                            Picker(label, selection: Binding(get: { categoryMap[label] ?? "" }, set: { categoryMap[label] = $0 })) {
                                Text("Not matched").tag("")
                                ForEach(dataManager.userCategories) { category in
                                    Text(category.name).tag(category.id.uuidString.lowercased())
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Preview expenses…") { consent = true }.disabled(!mapped || busy)
                } footer: {
                    Text("Only the columns you choose are used. No rows are added, edited or deleted in either app.")
                }
            }
            if let preview {
                Section("Preview results") {
                    LabeledContent("Rows checked", value: "\(preview.totalRows)")
                    LabeledContent("Matching expenses", value: "\(preview.validRows)")
                    LabeledContent("Archived rows excluded", value: "\(preview.excludedArchivedRows)")
                    Text("Currency: \(preview.currency) · Time zone: \(preview.timeZone)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !preview.unmappedCategories.isEmpty {
                        Text("Choose a matching category above for: \(preview.unmappedCategories.joined(separator: ", ")). Then preview again.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !preview.samples.isEmpty {
                    Section("Sample expenses") {
                        ForEach(preview.samples, id: \.id) { expense in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(expense.title)
                                Text("\(expense.amount) \(preview.currency) · \(ExistingNotionPreviewDate.label(expense.date, timeZone: preview.timeZone))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if busy { ProgressView("Loading preview…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        }
        .navigationTitle("Existing Notion table")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { await loadSources() }
        .refreshable { await loadSources() }
        .onChange(of: selected) { _, _ in
            titleField = ""; amountField = ""; dateField = ""; categoryField = ""
            categoryMap = [:]; preview = nil
        }
        .onChange(of: categoryField) { _, _ in categoryMap = [:]; preview = nil }
        .onChange(of: titleField) { _, _ in preview = nil }
        .onChange(of: amountField) { _, _ in preview = nil }
        .onChange(of: dateField) { _, _ in preview = nil }
        .confirmationDialog("Read this table for a preview?", isPresented: $consent, titleVisibility: .visible) {
            Button("Read and preview expenses") { Task { await loadPreview() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The selected table's expense rows will be read by Cenzio's service to check your mapping. No rows are imported, saved to your ledger or changed in Notion.")
        }
    }

    private func fieldPicker(_ title: String, values: [String], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose a column").tag("")
            ForEach(values, id: \.self) { Text($0).tag($0) }
        }
    }

    @MainActor private func loadSources() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { sources = try await sync.existingNotionSources(); message = nil }
        catch { message = "Could not load your Notion tables. Check the connection and try again." }
    }

    @MainActor private func loadPreview() async {
        guard !busy, mapped else { return }
        busy = true
        defer { busy = false }
        let mapping = ExistingNotionMapping(title: titleField, amount: amountField, date: dateField,
            category: categoryField, categoryMap: categoryMap.filter { !$0.value.isEmpty })
        do {
            let result = try await sync.existingNotionPreview(sourceId: selected, mapping: mapping)
            guard result.readOnly, !result.canSync, !result.hasMore, result.samples.count <= 5,
                  result.dataSourceId == selected else { throw ExpenseSyncError.response }
            preview = result
            message = nil
        } catch { message = "Could not preview this table. Check the column mapping and try again. No rows were changed." }
    }
}
