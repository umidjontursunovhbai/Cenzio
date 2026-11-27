import SwiftUI

struct DataExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var exporter = DataExporter.shared
    
    @State private var selectedDataTypes: Set<DataExporter.ExportData> = [.expenses]
    @State private var selectedFormat: DataExporter.ExportFormat = .csv
    @State private var useDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var isExporting = false
    @State private var exportedFileURL: URL?
    @State private var showingShareSheet = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("export_data_types".localized) {
                    ForEach(DataExporter.ExportData.allCases, id: \.self) { dataType in
                        HStack {
                            HeroIcon(systemName: dataType.icon)
                                .foregroundStyle(NightTheme.accent)
                                .frame(width: 20)
                            
                            Text(dataType.localizedName)
                            
                            Spacer()
                            
                            if selectedDataTypes.contains(dataType) {
                                HeroIcon(systemName: "checkmark")
                                    .foregroundStyle(NightTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleDataType(dataType)
                        }
                    }
                }
                .listRowBackground(NightTheme.glassFill)
                .listRowSeparatorTint(NightTheme.hair)
                
                Section("export_format_section".localized) {
                    ForEach(DataExporter.ExportFormat.allCases, id: \.self) { format in
                        let isSelected = selectedFormat == format
                        HStack {
                            HeroIcon(systemName: format.icon)
                                .foregroundStyle(NightTheme.accent)
                                .frame(width: 20)

                            Text(format.rawValue)
                                .fontWeight(isSelected ? .semibold : .regular)

                            Spacer()

                            ZStack {
                                Circle()
                                    .strokeBorder(NightTheme.secondaryLabel, lineWidth: 1.5)
                                    .opacity(isSelected ? 0 : 1)
                                HeroIcon(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(NightTheme.accent)
                                    .opacity(isSelected ? 1 : 0)
                                    .scaleEffect(isSelected || reduceMotion ? 1 : 0.6)
                            }
                            .frame(width: 22, height: 22)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard selectedFormat != format else { return }
                            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.22)) {
                                selectedFormat = format
                            }
                        }
                        .listRowBackground(
                            ZStack {
                                NightTheme.glassFill
                                NightTheme.accent.opacity(isSelected ? 0.12 : 0)
                            }
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .sensoryFeedback(.selection, trigger: selectedFormat)
                .listRowSeparatorTint(NightTheme.hair)
                
                Section("date_range_section".localized) {
                    Toggle("use_date_range".localized, isOn: $useDateRange)
                    
                    if useDateRange {
                        DatePicker("start_date".localized, selection: $startDate, displayedComponents: .date)
                        DatePicker("end_date".localized, selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
                .listRowBackground(NightTheme.glassFill)
                .listRowSeparatorTint(NightTheme.hair)
                
                Section("preview_section".localized) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("export_summary".localized)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        HStack {
                            Text("data_types_label".localized)
                            Spacer()
                            Text(String(format: "selected_count".localized, selectedDataTypes.count))
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                        
                        HStack {
                            Text("format_label".localized)
                            Spacer()
                            Text(selectedFormat.rawValue)
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                        
                        if useDateRange {
                            HStack {
                                Text("date_range_label".localized)
                                Spacer()
                                Text("\(DateFormatter.shortStyle.string(from: startDate)) - \(DateFormatter.shortStyle.string(from: endDate))")
                                    .foregroundStyle(NightTheme.secondaryLabel)
                            }
                        }
                        
                        HStack {
                            Text("estimated_size_label".localized)
                            Spacer()
                            Text(estimatedFileSize)
                                .foregroundStyle(NightTheme.secondaryLabel)
                        }
                    }
                }
                .listRowBackground(NightTheme.glassFill)
                .listRowSeparatorTint(NightTheme.hair)
            }
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .navigationTitle("export_data_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("cancel".localized) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: exportData) {
                        if isExporting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("export_button".localized)
                        }
                    }
                    .disabled(selectedDataTypes.isEmpty || isExporting)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("export_status_title".localized, isPresented: $showingAlert) {
                Button("ok".localized) { }
            } message: {
                Text(alertMessage)
            }
        }
        .tint(NightTheme.accent)
    }
    
    private func toggleDataType(_ dataType: DataExporter.ExportData) {
        if dataType == .all {
            if selectedDataTypes.contains(.all) {
                selectedDataTypes.removeAll()
            } else {
                selectedDataTypes = Set(DataExporter.ExportData.allCases)
            }
        } else {
            if selectedDataTypes.contains(dataType) {
                selectedDataTypes.remove(dataType)
                selectedDataTypes.remove(.all)
            } else {
                selectedDataTypes.insert(dataType)
                
                // Check if all individual types are selected
                let individualTypes = Set(DataExporter.ExportData.allCases.filter { $0 != .all })
                if selectedDataTypes.isSuperset(of: individualTypes) {
                    selectedDataTypes.insert(.all)
                }
            }
        }
    }
    
    private var estimatedFileSize: String {
        let dataManager = DataManager.shared
        var itemCount = 0
        
        if selectedDataTypes.contains(.expenses) || selectedDataTypes.contains(.all) {
            itemCount += dataManager.expenses.count
        }
        if selectedDataTypes.contains(.recurringExpenses) || selectedDataTypes.contains(.all) {
            itemCount += dataManager.recurringExpenses.count
        }
        if selectedDataTypes.contains(.budgets) || selectedDataTypes.contains(.all) {
            itemCount += dataManager.categoryBudgets.count
        }
        if selectedDataTypes.contains(.spendingGoals) || selectedDataTypes.contains(.all) {
            itemCount += dataManager.spendingGoals.count
        }
        if selectedDataTypes.contains(.monthlySalaries) || selectedDataTypes.contains(.all) {
            itemCount += dataManager.monthlySalaries.count
        }
        
        let estimatedKB = max(1, itemCount / 10)
        
        if estimatedKB < 1024 {
            return "\(estimatedKB) KB"
        } else {
            let estimatedMB = Double(estimatedKB) / 1024.0
            return String(format: "%.1f MB", estimatedMB)
        }
    }
    
    private func exportData() {
        isExporting = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let dateRange = useDateRange ? DateInterval(start: startDate, end: endDate) : nil
            let fileURL = exporter.exportData(
                dataTypes: selectedDataTypes,
                format: selectedFormat,
                dateRange: dateRange
            )
            
            DispatchQueue.main.async {
                isExporting = false
                
                if let url = fileURL {
                    exportedFileURL = url
                    showingShareSheet = true
                    alertMessage = "export_success".localized
                } else {
                    alertMessage = "export_failed".localized
                }
                
                showingAlert = true
            }
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - DateFormatter Extension
extension DateFormatter {
    static let shortStyle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()
}

#Preview {
    DataExportView()
}
