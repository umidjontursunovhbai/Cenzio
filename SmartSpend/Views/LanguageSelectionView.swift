import SwiftUI

/// Picks the language of the app's own text. A tap switches at once: the sheet closes and
/// the whole app redraws in the new language. "Same as iPhone" clears the choice.
struct LanguageSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    private let selected = AppLanguage.override

    var body: some View {
        NavigationStack {
            Form {
                Section("select_language".localized) {
                    systemRow
                    ForEach(Language.allCases) { language in
                        LanguageRowView(
                            title: language.name,
                            subtitle: language.englishName,
                            isSelected: selected == language,
                            onTap: { pick(language) }
                        )
                    }
                }
                Section {
                    Text("app_interface_language".localized)
                        .font(.caption)
                        .foregroundStyle(NightTheme.secondaryLabel)
                }
                .listRowBackground(NightTheme.glassFill)
            }
            .scrollContentBackground(.hidden)
            .background(NightGround())
            .navigationTitle("language".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                        .foregroundStyle(.tint)
                }
            }
        }
        .tint(NightTheme.accent)
    }

    private var systemRow: some View {
        LanguageRowView(
            title: "language_same_as_iphone".localized,
            subtitle: systemLanguageName,
            isSelected: selected == nil,
            onTap: { pick(nil) }
        )
    }

    /// Name of the iPhone's own language, in that language.
    private var systemLanguageName: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return Language(rawValue: code)?.name
            ?? Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized
            ?? code
    }

    private func pick(_ language: Language?) {
        guard language != selected else { dismiss(); return }
        dismiss()
        // Let the sheet slide away first; then the app redraws in the new language.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            AppLanguage.override = language
        }
    }
}

struct LanguageRowView: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(NightTheme.secondaryLabel)
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
        .listRowBackground(NightTheme.glassFill)
        .listRowSeparatorTint(NightTheme.hair)
    }
}

#Preview {
    LanguageSelectionView()
}
