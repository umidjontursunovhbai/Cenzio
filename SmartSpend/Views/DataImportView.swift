import SwiftUI
import UniformTypeIdentifiers

struct DataImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var importer = DataImporter.shared
    @ObservedObject private var dataManager = DataManager.shared
    
    @State private var showingFilePicker = false
    @State private var selectedFileURL: URL?
    @State private var previewData: (headers: [String], sampleRows: [[String]], totalRows: Int)?
    @State private var isImporting = false
    @State private var importResult: DataImporter.ImportResult?
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingConfirmation = false
    @State private var showingFormatInfo = false
    
    var body: some View {
        Group { // pushed from Settings: the Settings stack gives the back button
            ZStack {
            NightGround()
            ScrollView {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 12) {
                    HeroIcon(systemName: "square.and.arrow.down")
                        .font(.system(size: 50))
                        .foregroundStyle(NightTheme.accent)
                    
                    Text("import_expenses_title".localized)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("import_expenses_subtitle".localized)
                        .font(.subheadline)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .multilineTextAlignment(.center)

                    Text("import_scope_note".localized)
                        .font(.caption)
                        .foregroundStyle(NightTheme.secondaryLabel)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)
                
                // File Selection
                if let selectedFileURL = selectedFileURL {
                    selectedFileView(fileURL: selectedFileURL)
                } else {
                    fileSelectionView
                }
                
                // Preview Section
                if let previewData = previewData {
                    previewSection(previewData: previewData)
                }
                
                // Import Button
                if selectedFileURL != nil && previewData != nil {
                    importButton
                }
            }
            .padding()
            }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingFormatInfo = true } label: {
                        HeroIcon("information-circle")
                    }
                    .accessibilityLabel("csv_format_guide".localized)
                    .accessibilityIdentifier("import.infoButton")
                }

            }
            // Its own page in the same stack: back returns here, not to Settings.
            .navigationDestination(isPresented: $showingFormatInfo) { CSVFormatGuidePage() }
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(selectedURL: $selectedFileURL, onFileSelected: handleFileSelection)
            }
            .alert("import_status".localized, isPresented: $showingAlert) {
                Button("ok".localized) {
                    // Only dismiss if import was successful
                    if case .success = importResult {
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
            // An alert always shows both buttons; a confirmation dialog shown as a popover hides Cancel.
            .alert("confirm_import".localized, isPresented: $showingConfirmation) {
                Button("cancel".localized, role: .cancel) { }
                Button(String(format: "import_all_expenses_format".localized, previewData?.totalRows ?? 0)) {
                    performImport()
                }
            } message: {
                Text("confirm_import_message".localized)
            }
        }
        .tint(NightTheme.accent)
    }

    // MARK: - View Components
    
    private var fileSelectionView: some View {
        VStack(spacing: 16) {
            Button {
                showingFilePicker = true
            } label: {
                VStack(spacing: 12) {
                    HeroIcon(systemName: "doc.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(NightTheme.accent)
                    
                    Text("select_csv_file".localized)
                        .font(.headline)
                        .fontWeight(.medium)
                    
                    Text("select_csv_subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(NightTheme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                )
            }
            .buttonStyle(.plain)
            
            // Instructions
            VStack(alignment: .leading, spacing: 16) {
                Text("how_to_import_title".localized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 8) {
                    // The step strings already carry their "1." / "2." / "3." numbering.
                    ForEach(["import_step_1", "import_step_2", "import_step_3"], id: \.self) { key in
                        Text(key.localized)
                            .font(.caption)
                            .foregroundStyle(NightTheme.secondaryLabel)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(NightTheme.glassFill, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private func selectedFileView(fileURL: URL) -> some View {
        VStack(spacing: 12) {
            HStack {
                HeroIcon(systemName: "doc.text")
                    .foregroundStyle(NightTheme.accent)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("file_selected".localized)
                        .font(.caption)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                
                Spacer()
                
                Button("change".localized) {
                    selectedFileURL = nil
                    previewData = nil
                }
                .font(.caption)
                .foregroundStyle(NightTheme.accent)
            }
            .padding()
            .background(NightTheme.glassFill, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private func previewSection(previewData: (headers: [String], sampleRows: [[String]], totalRows: Int)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeroIcon(systemName: "eye")
                    .foregroundStyle(NightTheme.accent)
                
                Text("preview".localized)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(String(format: "total_rows_format".localized, previewData.totalRows))
                    .font(.caption)
                    .foregroundStyle(NightTheme.secondaryLabel)
            }
            
            // Headers
            VStack(alignment: .leading, spacing: 8) {
                Text("detected_columns".localized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 4) {
                    ForEach(previewData.headers, id: \.self) { header in
                        Text(header)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(NightTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            
            // Sample Data
            VStack(alignment: .leading, spacing: 8) {
                Text("sample_data_first_three".localized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                ForEach(Array(previewData.sampleRows.prefix(3).enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "row_number_format".localized, index + 1))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(NightTheme.secondaryLabel)
                        
                        Text(row.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(NightTheme.iconFill, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding()
        .background(NightTheme.glassFill, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var importButton: some View {
        Button {
            showingConfirmation = true
        } label: {
            HStack {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(colorScheme == .dark ? NightTheme.ink : Color.white)
                } else {
                    HeroIcon(systemName: "square.and.arrow.down")
                }
                
                Text(isImporting ? "importing".localized : "import_expenses_cta".localized)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                isImporting ? NightTheme.track : NightTheme.accent,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(colorScheme == .dark ? NightTheme.ink : Color.white)
        }
        .disabled(isImporting)
    }
    
    // MARK: - File Selection Handler
    
    private func handleFileSelection(_ url: URL) {
        selectedFileURL = url
        importResult = nil
        // DataImporter opens/closes the security-scoped resource itself.
        if let preview = importer.previewCSVImport(fileURL: url) {
            previewData = preview
        } else {
            // Don't leave an unreadable file "selected" with no way to import it.
            selectedFileURL = nil
            previewData = nil
            alertMessage = "cannot_read_file_debug".localized
            showingAlert = true
        }
    }
    
    // MARK: - Methods
    
    private func performImport() {
        guard let fileURL = selectedFileURL else { return }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = importer.importFromCSV(fileURL: fileURL, dataManager: dataManager)

            DispatchQueue.main.async {
                isImporting = false
                importResult = result

                switch result {
                case .success(let importedCount, let skippedCount, let errors):
                    alertMessage = errors.isEmpty
                        ? String(format: "import_success_count".localized, importedCount)
                        : String(format: "import_partial_with_errors".localized, importedCount, skippedCount)
                case .failure(let error):
                    alertMessage = String(format: "import_failed_error".localized, error)
                }

                showingAlert = true
            }
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedURL: URL?
    let onFileSelected: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.commaSeparatedText, UTType.plainText])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // Store the URL and call the callback
            parent.selectedURL = url
            parent.onFileSelected(url)
        }
    }
}

// MARK: - CSV format guide page

/// The CSV format guide, pushed from the import screen's info button.
struct CSVFormatGuidePage: View {
    /// Header names the importer accepts for each field (matched case-insensitively, in English).
    private let customFields: [(field: String, names: [String])] = [
        ("column_title".localized, ["Title", "Name", "Description"]),
        ("column_amount".localized, ["Amount", "Price", "Cost"]),
        ("column_date".localized, ["Date"]),
        ("column_category".localized, ["Category", "Type"])
    ]

    var body: some View {
        InfoPage(title: "csv_format_guide".localized, lead: "csv_format_subtitle".localized) {
            InfoPageSection("smartspend_format".localized, note: "smartspend_format_desc".localized) {
                VStack(alignment: .leading, spacing: 8) {
                    sampleSheet
                    HStack(spacing: 6) {
                        Circle().fill(NightTheme.accent).frame(width: 6, height: 6)
                        Text("required".localized)
                    }
                    .font(.caption)
                    .foregroundStyle(NightTheme.secondaryLabel)
                    .accessibilityHidden(true)
                    InfoPageCode(text: "Date,Title,Amount,Category")
                }
            }

            InfoPageSection("custom_format".localized, note: "custom_format_desc".localized) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(spacing: 0) {
                        ForEach(Array(customFields.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                Divider().overlay(NightTheme.hair).padding(.leading, 14)
                            }
                            fieldRow(item.field, names: item.names)
                        }
                    }
                    .nightGroup()
                    InfoPageCode(text: "Description,Price,Date,Type")
                }
            }

            InfoPageSection("tips_title".localized) {
                InfoPageList(rows: [
                    ("document-text", "tip_case_insensitive".localized),
                    ("calendar-days", "tip_date_formats".localized),
                    ("tag", "tip_categories_auto".localized),
                    ("banknotes", "tip_currency_symbols".localized)
                ])
            }
        }
    }

    /// Two sample rows under the four required headers, the way the file looks in a spreadsheet.
    private var sampleSheet: some View {
        let rows = [
            ["2026-11-24", "csv_sample_title_1".localized, "12000", "csv_sample_category_1".localized],
            ["2026-11-25", "csv_sample_title_2".localized, "28000", "csv_sample_category_2".localized]
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Date", "Title", "Amount", "Category"], id: \.self) { header in
                        HStack(spacing: 6) {
                            Circle().fill(NightTheme.accent).frame(width: 6, height: 6)
                            Text(verbatim: header).fontWeight(.semibold)
                        }
                        .gridColumnAlignment(header == "Amount" ? .trailing : .leading)
                    }
                }
                .padding(.vertical, 11)
                ForEach(rows, id: \.self) { row in
                    Divider().overlay(NightTheme.hair)
                    GridRow {
                        ForEach(row, id: \.self) { value in
                            Text(value).foregroundStyle(NightTheme.secondaryLabel)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 14)
        }
        .nightGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Date, Title, Amount, Category")
    }

    private func fieldRow(_ field: String, names: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(field)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 72, alignment: .leading)
            FlowChips(names: names)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(field): \(names.joined(separator: ", "))")
    }
}

/// Header names as small pills, wrapping to a new line when they do not fit.
private struct FlowChips: View {
    let names: [String]

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(verbatim: name)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NightTheme.iconFill, in: Capsule())
                    .overlay(Capsule().stroke(NightTheme.glassLine, lineWidth: 1))
            }
        }
    }
}

/// Minimal wrapping row layout for the chips.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    DataImportView()
}
