import SwiftUI
import UIKit

/// Tap for the form; deliberately hold, then pull down for hands-free entry.
struct ExpenseEntryButton: View {
    var accessibilityID: String
    var isRecording = false
    var isProcessing = false
    var onTap: () -> Void
    var onVoice: () -> Void
    var onStop: () -> Void = {}
    @State private var armed = false

    var body: some View {
        NativeExpenseEntryButton(accessibilityID: accessibilityID, isRecording: isRecording, isProcessing: isProcessing, onTap: onTap, onVoice: onVoice, onStop: onStop, onArmed: { armed = $0 })
            .frame(width: iOSDesignSystem.Size.minimumTapTarget, height: iOSDesignSystem.Size.minimumTapTarget)
            .liquidGlassSurface(Circle())
            .overlay {
                if isProcessing {
                    ProgressView()
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if armed && !isRecording && !isProcessing {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(.systemBlue))
                        .offset(y: 7)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct NativeExpenseEntryButton: UIViewRepresentable {
    let accessibilityID: String
    var isRecording: Bool
    var isProcessing: Bool
    var onTap: () -> Void
    var onVoice: () -> Void
    var onStop: () -> Void
    var onArmed: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(named: "hero-plus")?.withRenderingMode(.alwaysTemplate), for: .normal)
        button.tintColor = .systemBlue
        button.imageView?.contentMode = .scaleAspectFit
        button.configuration = .plain()
        button.configuration?.imagePadding = 0
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 9.5, leading: 9.5, bottom: 9.5, trailing: 9.5)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 16
        // A recognized hold cancels UIButton's tap, but short taps remain native.
        hold.cancelsTouchesInView = true
        button.addGestureRecognizer(hold)
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.parent = self
        let image = isProcessing ? nil : isRecording
            ? UIImage(systemName: "stop.circle.fill")
            : UIImage(named: "hero-plus")?.withRenderingMode(.alwaysTemplate)
        button.setImage(image, for: .normal)
        button.tintColor = isRecording ? .systemRed : .systemBlue
        button.isEnabled = !isProcessing
        button.accessibilityIdentifier = accessibilityID
        button.accessibilityLabel = isRecording ? voiceText("Stop recording", "Остановить запись") : isProcessing ? voiceText("Preparing expense", "Подготовка расхода") : "add_expense".localized
        button.accessibilityHint = isRecording ? voiceText("Tap to review your expense", "Нажмите, чтобы проверить расход") : voiceText("Hold, then drag down to dictate an expense", "Удерживайте и потяните вниз, чтобы продиктовать расход")
        button.accessibilityCustomActions = isRecording || isProcessing ? [] : [UIAccessibilityCustomAction(name: voiceText("Dictate expense", "Продиктовать расход"), target: context.coordinator, selector: #selector(Coordinator.dictate))]
    }

    final class Coordinator: NSObject {
        var parent: NativeExpenseEntryButton
        private var origin = CGPoint.zero
        private var triggered = false

        init(_ parent: NativeExpenseEntryButton) { self.parent = parent }

        @objc func tap() {
            guard !parent.isProcessing else { return }
            if parent.isRecording { parent.onStop() } else { parent.onTap() }
        }
        @objc func dictate() -> Bool {
            guard !parent.isRecording, !parent.isProcessing else { return false }
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            parent.onVoice()
            return true
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard !parent.isRecording, !parent.isProcessing else { return }
                origin = gesture.location(in: nil)
                triggered = false
                parent.onArmed(true)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .changed:
                guard !parent.isRecording, !parent.isProcessing else { return }
                let location = gesture.location(in: nil)
                guard !triggered, ExpenseVoiceGesture.shouldStart(x: location.x - origin.x, y: location.y - origin.y) else { return }
                triggered = true
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                parent.onVoice()
            case .ended, .cancelled, .failed:
                parent.onArmed(false)
                triggered = false
            default: break
            }
        }
    }
}

enum ExpenseVoiceGesture {
    static func shouldStart(x: CGFloat, y: CGFloat) -> Bool {
        x.isFinite && y.isFinite && y >= 28 && abs(x) <= 48 && y > abs(x)
    }
}
