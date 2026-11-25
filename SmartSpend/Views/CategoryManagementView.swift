import SwiftUI

struct CategoryManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    @State private var editorRoute: CategoryEditorRoute?

    var body: some View {
        NavigationStack {
            List {
                if dataManager.userCategories.isEmpty {
                    Text("No categories yet")
                        .foregroundStyle(.secondary)
                        .listRowBackground(iOSDesignSystem.elevatedBackground)
                } else {
                    ForEach(dataManager.userCategories) { category in
                        HStack(spacing: 12) {
                            HeroIcon(systemName: category.iconSystemName, size: 22)
                                .foregroundStyle(category.color)
                                .frame(width: iOSDesignSystem.Size.compactIcon)
                            Text(category.name)
                            Spacer()
                            HeroIcon(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: iOSDesignSystem.Size.minimumTapTarget)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editorRoute = .edit(category)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                dataManager.deleteUserCategory(category)
                            } label: {
                                HeroIconLabel(title: "Delete", systemName: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editorRoute = .edit(category)
                            } label: {
                                HeroIconLabel(title: "Edit", systemName: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                    .listRowBackground(iOSDesignSystem.elevatedBackground)
                }
            }
            .listStyle(.insetGrouped)
            .groupedListBackdrop()
            .navigationTitle("categories".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorRoute = .add
                    } label: {
                        HeroIcon("plus", size: 21)
                            .iOSMinimumTapTarget()
                    }
                    .liquidGlassButtonStyle()
                }
            }
            .sheet(item: $editorRoute) { route in
                CategoryEditorView(category: route.category)
                    .presentationDetents([.large])
            }
        }
    }
}

private enum CategoryEditorRoute: Identifiable {
    case add
    case edit(UserCategory)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let category):
            return category.id.uuidString
        }
    }

    var category: UserCategory? {
        switch self {
        case .add:
            return nil
        case .edit(let category):
            return category
        }
    }
}

// MARK: - Editor

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dataManager = DataManager.shared

    let category: UserCategory?

    @State private var name: String
    @State private var iconSystemName: String
    @State private var selectedColorName: String
    @State private var showValidationError = false

    init(category: UserCategory?) {
        self.category = category
        _name             = State(initialValue: category?.name ?? "")
        _iconSystemName   = State(initialValue: HeroIcon.resolvedName(category?.iconSystemName ?? "tag"))
        _selectedColorName = State(initialValue: category?.colorName ?? "systemBlue")
    }

    private var selectedColor: Color { color(for: selectedColorName) }
    private var isEditing: Bool { category != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Name
                Section {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                .listRowBackground(iOSDesignSystem.elevatedBackground)

                // Icon
                Section("Icon") {
                    iconGrid
                        .listRowInsets(EdgeInsets(top: iOSDesignSystem.Spacing.medium, leading: iOSDesignSystem.Spacing.screenMargin, bottom: iOSDesignSystem.Spacing.medium, trailing: iOSDesignSystem.Spacing.screenMargin))
                }
                .listRowBackground(iOSDesignSystem.elevatedBackground)

                // Color
                Section("Color") {
                    colorGrid
                        .listRowInsets(EdgeInsets(top: iOSDesignSystem.Spacing.medium, leading: iOSDesignSystem.Spacing.screenMargin, bottom: iOSDesignSystem.Spacing.medium, trailing: iOSDesignSystem.Spacing.screenMargin))
                }
                .listRowBackground(iOSDesignSystem.elevatedBackground)
            }
            .groupedListBackdrop()
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "save".localized : "add".localized) {
                        saveCategory()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Invalid Name", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please enter a unique category name.")
            }
        }
    }

    // MARK: - Grids

    private var iconGrid: some View {
        let columns = [GridItem(.adaptive(minimum: iOSDesignSystem.Size.minimumTapTarget), spacing: iOSDesignSystem.Spacing.small)]
        return LazyVGrid(columns: columns, spacing: iOSDesignSystem.Spacing.small) {
            ForEach(UserCategory.presetIcons, id: \.self) { iconName in
                let isSelected = iconSystemName == iconName
                Button {
                    iconSystemName = iconName
                } label: {
                    HeroIcon(iconName, size: 22)
                        .foregroundStyle(isSelected ? selectedColor : .primary)
                        .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                        .liquidGlassSurface(RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: iOSDesignSystem.Radius.small)
                                .stroke(isSelected ? selectedColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(iconName.replacingOccurrences(of: "-", with: " "))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var colorGrid: some View {
        let columns = [GridItem(.adaptive(minimum: iOSDesignSystem.Size.minimumTapTarget), spacing: iOSDesignSystem.Spacing.medium)]
        return LazyVGrid(columns: columns, spacing: iOSDesignSystem.Spacing.medium) {
            ForEach(UserCategory.presetColors, id: \.self) { colorName in
                let isSelected = selectedColorName == colorName
                Circle()
                    .fill(color(for: colorName))
                    .frame(width: 34, height: 34)
                    .overlay {
                        if isSelected {
                            HeroIcon(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
                    .contentShape(Circle())
                    .onTapGesture { selectedColorName = colorName }
            }
        }
    }

    // MARK: - Helpers

    private func color(for name: String) -> Color {
        switch name {
        case "systemRed":    return Color(.systemRed)
        case "systemOrange": return Color(.systemOrange)
        case "systemYellow": return Color(.systemYellow)
        case "systemGreen":  return Color(.systemGreen)
        case "systemMint":   return Color(.systemMint)
        case "systemTeal":   return Color(.systemTeal)
        case "systemCyan":   return Color(.systemCyan)
        case "systemBlue":   return Color(.systemBlue)
        case "systemIndigo": return Color(.systemIndigo)
        case "systemPurple": return Color(.systemPurple)
        case "systemPink":   return Color(.systemPink)
        case "systemBrown":  return Color(.systemBrown)
        case "systemGray":   return Color(.systemGray)
        default:             return Color(.systemBlue)
        }
    }

    private func saveCategory() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isDuplicate = dataManager.userCategories.contains {
            $0.name.lowercased() == trimmed.lowercased() && $0.id != category?.id
        }
        guard !isDuplicate else { showValidationError = true; return }

        if var updated = category {
            updated.name = trimmed
            updated.iconSystemName = iconSystemName
            updated.colorName = selectedColorName
            dataManager.updateUserCategory(updated)
        } else {
            let new = UserCategory(name: trimmed, iconSystemName: iconSystemName, colorName: selectedColorName)
            dataManager.addUserCategory(new)
        }
        dismiss()
    }
}

#Preview {
    CategoryManagementView()
}
