import SwiftUI

struct LanguageSelectionView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLanguage: Language
    
    init() {
        self._selectedLanguage = State(initialValue: DataManager.shared.user.language)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("select_language".localized) {
                    ForEach(Language.allCases, id: \.self) { language in
                        LanguageRowView(
                            language: language,
                            isSelected: selectedLanguage == language,
                            onTap: { selectedLanguage = language }
                        )
                    }
                }
                .listRowBackground(iOSDesignSystem.elevatedBackground)
                
                Section {
                    Text("app_interface_language".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(iOSDesignSystem.elevatedBackground)
            }
            .groupedListBackdrop()
            .navigationTitle("language".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    cancelButton
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    saveButton
                }
            }
        }
    }
    
    private var cancelButton: some View {
        Button("cancel".localized) {
            dismiss()
        }
        .foregroundStyle(.tint)
    }
    
    private var saveButton: some View {
        Button("save".localized) {
            dataManager.updateLanguage(selectedLanguage)
            dismiss()
        }
        .fontWeight(.semibold)
        .foregroundStyle(.tint)
    }
}

struct LanguageRowView: View {
    let language: Language
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(language.englishName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    HeroIcon(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.title3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LanguageSelectionView()
}
