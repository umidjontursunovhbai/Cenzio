import SwiftUI
import UIKit

/// Bottom-trailing entry controls: a visible microphone for voice entry and
/// a plus for the manual form, placed within thumb reach above the tab bar.
struct ExpenseEntryBar: View {
    @Environment(\.floatingTabBarClearance) private var tabBarClearance
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var flags = FeatureFlags.shared
    var accessibilityPrefix: String
    var isRecording = false
    var isProcessing = false
    var onAdd: () -> Void
    var onVoice: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Keep the button while a recording is in flight so it can still be stopped.
            if flags.voiceEnabled || isRecording || isProcessing {
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
                .liquidGlassSurface(Circle(), interactive: true)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .accessibilityIdentifier("\(accessibilityPrefix).voice-expense")
            .accessibilityLabel(isRecording ? voiceText("Stop recording", "Остановить запись") : isProcessing ? voiceText("Preparing expense", "Подготовка расхода") : voiceText("Add expense by voice", "Добавить расход голосом"))
            }

            Button(action: onAdd) {
                Image("hero-plus")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(iOSDesignSystem.onAccent)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor))
                    // A glow reads as smudge on black; dark mode keeps the solid disc only.
                    .shadow(color: colorScheme == .dark ? .clear : Color.accentColor.opacity(0.3), radius: 10, x: 0, y: 5)
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

// MARK: - Dark-only surfaces for the expense screens
// Light mode keeps its existing look exactly; dark mode moves to black + Liquid Glass.

/// Native glass in dark mode; the given fill in light mode.
private struct ExpenseDarkGlass<S: Shape, Light: ShapeStyle>: ViewModifier {
    let shape: S
    let light: Light
    let interactive: Bool
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.liquidGlassSurface(shape, interactive: interactive)
        } else {
            content.background(light, in: shape)
        }
    }
}

/// A control that sits inside a glass card: a quiet well in dark mode (glass never
/// nests in glass), the existing glass control in light mode.
private struct ExpenseNestedControlSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.background(iOSDesignSystem.insetFill, in: shape)
        } else {
            content.liquidGlassSurface(shape)
        }
    }
}

/// Forms and grouped lists: true black behind the rows in dark mode.
private struct ExpenseDarkFormBackdrop: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content
                .scrollContentBackground(.hidden)
                .appBackdrop()
        } else {
            content
        }
    }
}

/// Near-black row plates in dark mode; the system row background in light mode.
private struct ExpenseDarkRowBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.listRowBackground(colorScheme == .dark ? iOSDesignSystem.elevatedBackground : nil)
    }
}

extension View {
    func expenseDarkGlass<S: Shape, Light: ShapeStyle>(_ shape: S, light: Light, interactive: Bool = false) -> some View {
        modifier(ExpenseDarkGlass(shape: shape, light: light, interactive: interactive))
    }

    func expenseNestedControlSurface<S: Shape>(_ shape: S) -> some View {
        modifier(ExpenseNestedControlSurface(shape: shape))
    }

    func expenseDarkFormBackdrop() -> some View {
        modifier(ExpenseDarkFormBackdrop())
    }

    func expenseDarkRowBackground() -> some View {
        modifier(ExpenseDarkRowBackground())
    }
}
