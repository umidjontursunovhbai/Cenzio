import SwiftUI
import UniformTypeIdentifiers

struct DataImportView: View {
    @Environment(\.dismiss) private var dismiss
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
    /// Drives the staggered reveal of the inline guide after it is inserted.
    @State private var formatInfoVisible = false
    private static let pageTopID = "page.top"
    private static let formatInfoID = "import.inlineInfo"
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
            VStack(spacing: 20) {
                // Fixed scroll target above the animated info, so opening it never overshoots under the bar.
                Color.clear.frame(height: 0).id(Self.pageTopID)
                if showingFormatInfo {
                    inlineFormatInfo
                        .id(Self.formatInfoID)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        ))
                }

                // Header
                VStack(spacing: 12) {
                    HeroIcon(systemName: "square.and.arrow.down")
                        .font(.system(size: 50))
                        .foregroundStyle(.blue)
                    
                    Text("import_expenses_title".localized)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("import_expenses_subtitle".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("import_scope_note".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .onChange(of: showingFormatInfo) { _, isShowing in
                guard isShowing else { return }
                withAnimation(.snappy(duration: 0.35)) {
                    proxy.scrollTo(Self.pageTopID, anchor: .top)
                }
            }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: toggleFormatInfo) {
                        HeroIcon(showingFormatInfo ? "x-mark" : "information-circle")
                    }
                    .accessibilityLabel(showingFormatInfo ? "close".localized : "csv_format_guide".localized)
                    .accessibilityIdentifier("import.infoButton")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                    .accessibilityIdentifier("import.cancel")
                }
            }
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
    }

    /// Opens or closes the CSV guide inside the page instead of a separate popup.
    private func toggleFormatInfo() {
        if showingFormatInfo {
            formatInfoVisible = false
            withAnimation(.snappy(duration: 0.3)) { showingFormatInfo = false }
        } else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showingFormatInfo = true }
        }
    }

    private var inlineFormatInfo: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                HeroIcon("document-text", size: 18)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text("csv_format_guide".localized)
                    .font(.headline)
                Spacer()
                Button(action: toggleFormatInfo) {
                    HeroIcon("x-mark", size: 16)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(.systemGray6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("close".localized)
            }

            CSVFormatInfoView()
                .environment(\.infoPopupIsVisible, formatInfoVisible)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { formatInfoVisible = true }
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
                        .foregroundStyle(.blue)
                    
                    Text("select_csv_file".localized)
                        .font(.headline)
                        .fontWeight(.medium)
                    
                    Text("select_csv_subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private func selectedFileView(fileURL: URL) -> some View {
        VStack(spacing: 12) {
            HStack {
                HeroIcon(systemName: "doc.text")
                    .foregroundStyle(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("file_selected".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("change".localized) {
                    selectedFileURL = nil
                    previewData = nil
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }
            .padding()
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private func previewSection(previewData: (headers: [String], sampleRows: [[String]], totalRows: Int)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HeroIcon(systemName: "eye")
                    .foregroundStyle(.orange)
                
                Text("preview".localized)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(String(format: "total_rows_format".localized, previewData.totalRows))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
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
                            .foregroundStyle(.secondary)
                        
                        Text(row.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding()
        .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var importButton: some View {
        Button {
            showingConfirmation = true
        } label: {
            HStack {
                if isImporting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    HeroIcon(systemName: "square.and.arrow.down")
                }
                
                Text(isImporting ? "importing".localized : "import_expenses_cta".localized)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                isImporting ? Color.gray : Color.accentColor,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(.white)
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

// MARK: - CSV Format Info (popup body)

/// Body of the CSV format guide shown in `infoPopup` on the import screen.
struct CSVFormatInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("csv_format_subtitle".localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .infoPopupStaggered(0)

            formatCard(
                title: "smartspend_format".localized,
                icon: "check-badge",
                color: .green,
                description: "smartspend_format_desc".localized,
                columns: [
                    ("column_date".localized, "required".localized),
                    ("column_title".localized, "required".localized),
                    ("column_amount".localized, "required".localized),
                    ("column_category".localized, "required".localized)
                ],
                example: "Date,Title,Amount,Category"
            )
            .infoPopupStaggered(1)

            formatCard(
                title: "custom_format".localized,
                icon: "adjustments-horizontal",
                color: .purple,
                description: "custom_format_desc".localized,
                columns: [
                    ("column_title_name_description".localized, "any_of_these".localized),
                    ("column_amount_price_cost".localized, "any_of_these".localized),
                    ("column_date".localized, "required".localized),
                    ("column_category_type".localized, "any_of_these".localized)
                ],
                example: "Description,Price,Date,Type"
            )
            .infoPopupStaggered(2)

            InfoPopupSection("tips_title".localized, index: 3) {
                VStack(alignment: .leading, spacing: 8) {
                    tipRow("tip_case_insensitive".localized)
                    tipRow("tip_date_formats".localized)
                    tipRow("tip_categories_auto".localized)
                    tipRow("tip_currency_symbols".localized)
                }
            }
        }
    }

    private func formatCard(
        title: String,
        icon: String,
        color: Color,
        description: String,
        columns: [(name: String, note: String)],
        example: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                HeroIcon(icon, size: 18)
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("required_columns".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(columns, id: \.name) { column in
                    HStack(alignment: .center, spacing: 6) {
                        HeroIcon("check-circle", size: 14)
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                        Text(column.name)
                            .font(.footnote.weight(.medium))
                        Spacer(minLength: 8)
                        Text(column.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("example_header".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HeroIcon("sparkles", size: 14)
                .foregroundStyle(.orange)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    DataImportView()
}
