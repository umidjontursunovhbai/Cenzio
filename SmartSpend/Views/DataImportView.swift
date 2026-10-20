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
    
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
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

                    Text("CSV import adds expenses. Budgets, goals, and app settings need to be set up separately.")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingFormatInfo = true
                    } label: {
                        HeroIcon(systemName: "info.circle")
                            .foregroundStyle(.blue)
                    }
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
            .confirmationDialog(
                "confirm_import".localized,
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(format: "import_all_expenses_format".localized, previewData?.totalRows ?? 0)) {
                    performImport()
                }
                Button("cancel".localized, role: .cancel) { }
            } message: {
                Text("confirm_import_message".localized)
            }
            .sheet(isPresented: $showingFormatInfo) {
                CSVFormatInfoView()
            }
        }
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
                        .stroke(Color.blue.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [5]))
                )
            }
            .buttonStyle(.plain)
            
            // Instructions
            VStack(alignment: .leading, spacing: 16) {
                Text("how_to_import_title".localized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("1")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.blue, in: Circle())
                        
                        Text("import_step_1".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("2")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.blue, in: Circle())
                        
                        Text("import_step_2".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(alignment: .top, spacing: 12) {
                        Text("3")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.blue, in: Circle())
                        
                        Text("import_step_3".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
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
                isImporting ? Color.gray : Color.blue,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(.white)
        }
        .disabled(isImporting)
    }
    
    // MARK: - File Selection Handler
    
    private func handleFileSelection(_ url: URL) {
        selectedFileURL = url
        previewData = nil
        
        // Start security-scoped resource access
        let accessedResource = url.startAccessingSecurityScopedResource()
        
        defer {
            if accessedResource { url.stopAccessingSecurityScopedResource() }
        }
        
        // Preview the file
        previewFile(url: url)
    }
    
    private func previewFile(url: URL) {
        if let preview = importer.previewCSVImport(fileURL: url) {
            previewData = preview
        } else {
            alertMessage = "cannot_read_file_debug".localized
            showingAlert = true
        }
    }
    
    // MARK: - Methods
    
    private func performImport() {
        guard let fileURL = selectedFileURL else { return }
        
        print("Starting import process for file: \(fileURL.lastPathComponent)")
        isImporting = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            print("Running import in background thread...")
            let result = importer.importFromCSV(fileURL: fileURL, dataManager: dataManager)
            print("Import finished with result: \(result)")
            
            DispatchQueue.main.async {
                print("Updating UI on main thread...")
                isImporting = false
                importResult = result
                
                switch result {
                case .success(let importedCount, let skippedCount, let errors):
                    print("Import success! Imported: \(importedCount), Skipped: \(skippedCount), Errors: \(errors.count)")
                    
                    if errors.isEmpty {
                        alertMessage = String(format: "import_success_count".localized, importedCount)
                    } else {
                        alertMessage = String(format: "import_partial_with_errors".localized, importedCount, skippedCount)
                        print("Import errors (showing first 5):")
                        for error in errors.prefix(5) {
                            print("  - \(error)")
                        }
                    }
                    
                case .failure(let error):
                    print("Import failure: \(error)")
                    alertMessage = String(format: "import_failed_error".localized, String(describing: error))
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

// MARK: - CSV Format Info View

struct CSVFormatInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var animateHeader = false
    @State private var animateCards = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Animated Header
                    VStack(spacing: 12) {
                        HeroIcon(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .scaleEffect(animateHeader ? 1.0 : 0.8)
                            .rotationEffect(.degrees(animateHeader ? 0 : -10))
                            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1), value: animateHeader)
                        
                        Text("csv_format_guide".localized)
                            .font(.title)
                            .fontWeight(.bold)
                            .opacity(animateHeader ? 1 : 0)
                            .offset(y: animateHeader ? 0 : -20)
                            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.2), value: animateHeader)
                        
                        Text("csv_format_subtitle".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .opacity(animateHeader ? 1 : 0)
                            .offset(y: animateHeader ? 0 : -20)
                            .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.3), value: animateHeader)
                    }
                    .padding(.top, 20)
                    
                    // Format Cards
                    VStack(spacing: 20) {
                        formatCard(
                            title: "smartspend_format".localized,
                            icon: "square.and.arrow.down",
                            color: .green,
                            description: "smartspend_format_desc".localized,
                            requiredColumns: [
                                ("column_date".localized, "required".localized),
                                ("column_title".localized, "required".localized),
                                ("column_amount".localized, "required".localized),
                                ("column_category".localized, "required".localized)
                            ],
                            example: "Date,Title,Amount,Category",
                            delay: 0.4
                        )
                        
                        formatCard(
                            title: "custom_format".localized,
                            icon: "wand.and.stars",
                            color: .purple,
                            description: "custom_format_desc".localized,
                            requiredColumns: [
                                ("column_title_name_description".localized, "any_of_these".localized),
                                ("column_amount_price_cost".localized, "any_of_these".localized),
                                ("column_date".localized, "required".localized),
                                ("column_category_type".localized, "any_of_these".localized)
                            ],
                            example: "Description,Price,Date,Type",
                            delay: 0.5
                        )
                    }
                    .opacity(animateCards ? 1 : 0)
                    .offset(y: animateCards ? 0 : 30)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: animateCards)
                    
                    // Tips Section
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            HeroIcon(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                                .font(.title3)
                            
                            Text("tips_title".localized)
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            tipRow(icon: "checkmark.circle.fill", text: "tip_case_insensitive".localized)
                            tipRow(icon: "checkmark.circle.fill", text: "tip_date_formats".localized)
                            tipRow(icon: "checkmark.circle.fill", text: "tip_categories_auto".localized)
                            tipRow(icon: "checkmark.circle.fill", text: "tip_currency_symbols".localized)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemGray6))
                    )
                    .opacity(animateCards ? 1 : 0)
                    .offset(y: animateCards ? 0 : 30)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.7), value: animateCards)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                animateHeader = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    animateCards = true
                }
            }
        }
    }
    
    private func formatCard(
        title: String,
        icon: String,
        color: Color,
        description: String,
        requiredColumns: [(String, String)],
        example: String,
        delay: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                HeroIcon(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 40, height: 40)
                    .background(color.opacity(0.15), in: Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
            
            // Required Columns
            VStack(alignment: .leading, spacing: 10) {
                Text("required_columns".localized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                
                ForEach(requiredColumns, id: \.0) { column in
                    HStack(spacing: 8) {
                        HeroIcon(systemName: "checkmark.circle.fill")
                            .foregroundStyle(color)
                            .font(.caption)
                        
                        Text(column.0)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("• \(column.1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Example
            VStack(alignment: .leading, spacing: 8) {
                Text("example_header".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                    )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: color.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .opacity(animateCards ? 1 : 0)
        .offset(x: animateCards ? 0 : -50)
        .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(delay), value: animateCards)
    }
    
    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            HeroIcon(systemName: icon)
                .foregroundStyle(.yellow)
                .font(.caption)
            
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    DataImportView()
}
