import SwiftUI
import UIKit

/// Bottom-trailing entry controls: a visible microphone for voice entry and
/// a plus for the manual form, placed within thumb reach above the tab bar.
struct ExpenseEntryBar: View {
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var flags = FeatureFlags.shared
    var accessibilityPrefix: String
    /// A street figure standing on the Add button (dashboard only).
    var figure: StreetFigure?
    /// Dashboard style: a 44 pt "Add expense" pill beside a 44 pt mic, no figure.
    var compact = false
    var isRecording = false
    var isProcessing = false
    var onAdd: () -> Void
    var onVoice: () -> Void
    var onStop: () -> Void

    var body: some View {
        if compact {
            compactBar
        } else {
            regularBar
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) {
                HStack(spacing: 6) {
                    Image("hero-plus")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text("add_expense".localized)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(colorScheme == .dark ? NightTheme.ink : .white)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule().fill(NightTheme.figure(colorScheme)))
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRecording || isProcessing)
            .accessibilityIdentifier("\(accessibilityPrefix).add-expense")

            if flags.voiceEnabled || isRecording || isProcessing {
                voiceButton(size: 44, iconSize: 18, tint: .primary)
            }
        }
        .padding(.trailing, iOSDesignSystem.Spacing.screenMargin)
        .padding(.bottom, 12 + tabBarClearance)
    }

    private func voiceButton(size: CGFloat, iconSize: CGFloat, tint: Color) -> some View {
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
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(isRecording ? Color.white : tint)
                }
            }
            .frame(width: size, height: size)
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
    }

    private var regularBar: some View {
        HStack(spacing: 12) {
            // Keep the button while a recording is in flight so it can still be stopped.
            if flags.voiceEnabled || isRecording || isProcessing {
                voiceButton(size: 56, iconSize: 20, tint: .accentColor)
            }

            Button(action: onAdd) {
                Image("hero-plus")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(colorScheme == .dark ? NightTheme.ink : .white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(NightTheme.figure(colorScheme)))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 5)
                    .contentShape(Circle())
            }
            .modifier(OptionalKerbFigure(figure: figure))
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

/// Adds `kerbFigure` only when a figure is given.
private struct OptionalKerbFigure: ViewModifier {
    let figure: StreetFigure?

    func body(content: Content) -> some View {
        if let figure {
            content.kerbFigure(figure, alignment: .center, inset: 0, height: 26)
        } else {
            content
        }
    }
}
