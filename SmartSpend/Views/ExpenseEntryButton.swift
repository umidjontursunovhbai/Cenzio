import SwiftUI
import UIKit

/// Bottom-trailing entry controls: a visible microphone for voice entry and
/// a plus for the manual form, placed within thumb reach above the tab bar.
struct ExpenseEntryBar: View {
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    var accessibilityPrefix: String
    var isRecording = false
    var isProcessing = false
    var onAdd: () -> Void
    var onVoice: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard !isProcessing else { return }
                UIImpactFeedbackGenerator(style: isRecording ? .light : .heavy).impactOccurred()
                if isRecording { onStop() } else { onVoice() }
            } label: {
                ZStack {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isRecording ? Color.white : Color.accentColor)
                    }
                }
                .frame(width: 56, height: 56)
                .background {
                    if isRecording { Circle().fill(Color(.systemRed)) }
                }
                .liquidGlassSurface(Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityIdentifier("\(accessibilityPrefix).voice-expense")
            .accessibilityLabel(isRecording ? voiceText("Stop recording", "Остановить запись") : isProcessing ? voiceText("Preparing expense", "Подготовка расхода") : voiceText("Add expense by voice", "Добавить расход голосом"))

            Button(action: onAdd) {
                Image("hero-plus")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 10, x: 0, y: 5)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isRecording || isProcessing)
            .accessibilityIdentifier("\(accessibilityPrefix).add-expense")
            .accessibilityLabel("add_expense".localized)
        }
        .padding(.trailing, iOSDesignSystem.Spacing.screenMargin)
        .padding(.bottom, 12 + tabBarClearance)
    }
}

extension EnvironmentValues {
    /// Height a floating tab bar covers at the bottom of a tab's content.
    @Entry var floatingTabBarClearance: CGFloat = 0
}

extension View {
    /// Pins the entry bar to the bottom-trailing corner of a screen.
    func expenseEntryBar(_ bar: ExpenseEntryBar, hidden: Bool = false) -> some View {
        overlay(alignment: .bottomTrailing) {
            if !hidden { bar }
        }
    }
}
