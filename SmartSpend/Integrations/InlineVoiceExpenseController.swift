import SwiftUI
import Combine
import AVFoundation

/// Local audio/STT, then one explicit server-side GPT-6 Luna request. No local semantic fallback.
@MainActor
final class InlineVoiceExpenseController: ObservableObject {
    static let recognitionLocale = "en-US"
    typealias Prepare = @MainActor (String, [UserCategory], Currency, Date, UUID) async throws -> VoiceDraftResponse
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var transcript = ""
    @Published private(set) var message: String?
    @Published private(set) var isVisible = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var needsAIConsent = false
    @Published private(set) var canRetry = false
    @Published private(set) var remainingCount = 0
    @Published var prefill: VoiceExpensePrefill?
    private let speech = ExpenseSpeechRecorder()
    private let defaults: UserDefaults
    private let prepare: Prepare
    private var subscriptions = Set<AnyCancellable>()
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var requestID = UUID()
    private var reference = Date()
    private var pending: [VoiceExpensePrefill] = []
    private var advanceAfterReview = false

    init(defaults: UserDefaults = .standard, prepare: @escaping Prepare = { text, categories, currency, reference, id in
        try await VoiceConnectionStore.shared.drafts(text: text, categories: categories, currency: currency, reference: reference, requestID: id)
    }) {
        self.defaults = defaults
        self.prepare = prepare
        speech.objectWillChange.sink { [weak self] in Task { @MainActor [weak self] in self?.refresh() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.cancel() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                Task { @MainActor [weak self] in self?.cancel() }
            }.store(in: &subscriptions)
    }

    func start() {
        guard !isRecording, !isProcessing else { return }
        work?.cancel()
        generation = UUID()
        requestID = UUID()
        reference = Date()
        prefill = nil
        pending = []
        advanceAfterReview = false
        remainingCount = 0
        transcript = ""
        message = nil
        needsAIConsent = false
        canRetry = false
        isVisible = true
        isRecording = true
        let identifier = generation
        work = Task { [weak self] in
            guard let self else { return }
            await self.speech.start(locale: Self.recognitionLocale)
            guard !Task.isCancelled, self.generation == identifier else { return }
            self.refresh()
        }
    }

    func stop() {
        guard isRecording, !isProcessing else { return }
        if speech.isAuthorizing { cancel(); return }
        work?.cancel()
        speech.finish()
        finishTranscription()
    }

    private func finishTranscription() {
        guard !isProcessing else { return }
        isRecording = false
        isProcessing = true
        let identifier = generation
        work = Task { [weak self] in
            guard let self else { return }
            while self.speech.isFinishing {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard self.generation == identifier else { return }
            }
            guard !Task.isCancelled, self.generation == identifier else { return }
            self.refresh()
            self.isProcessing = false
            let text = self.speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.prepareRecognizedText(text)
        }
    }

    /// Also enables tests to exercise the actual AI handoff without opening a microphone.
    func prepareRecognizedText(_ text: String) {
        guard !isProcessing, !isRecording else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { return }
        transcript = trimmed
        isVisible = true
        guard defaults.bool(forKey: "voice.gpt6luna.textConsent.v1") else {
            needsAIConsent = true
            return
        }
        runAI()
    }

    func allowAI() {
        defaults.set(true, forKey: "voice.gpt6luna.textConsent.v1")
        needsAIConsent = false
        runAI()
    }

    func retry() { guard canRetry, !isProcessing else { return }; runAI() }

    private func runAI() {
        guard !isProcessing, !transcript.isEmpty, defaults.bool(forKey: "voice.gpt6luna.textConsent.v1") else { return }
        isProcessing = true
        canRetry = false
        message = nil // The inline processing label already shows progress.
        let identifier = generation
        let text = transcript
        let categories = DataManager.shared.userCategories
        let currency = DataManager.shared.user.currency
        work = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == identifier { self.isProcessing = false } }
            do {
                let response = try await self.prepare(text, categories, currency, self.reference, self.requestID)
                try Task.checkCancellation()
                guard self.generation == identifier else { return }
                self.pending = try VoiceAIReviewBatch.prefills(response: response, categories: categories, currency: currency.rawValue, reference: self.reference)
                self.remainingCount = self.pending.count
                self.message = response.unresolvedFields.isEmpty ? nil : response.unresolvedFields.joined(separator: "\n")
                if self.pending.isEmpty {
                    self.message = voiceText("No supported expense found. Nothing was saved.", "Поддерживаемый расход не найден. Ничего не сохранено.")
                }
                self.reviewNext()
            } catch is CancellationError { }
            catch {
                guard self.generation == identifier else { return }
                self.message = error.localizedDescription
                self.canRetry = true
                // Deliberately no regex/keyword/category fallback.
            }
        }
    }

    func reviewNext() {
        guard prefill == nil, let next = pending.first else { return }
        isVisible = false
        prefill = next
    }

    #if DEBUG
    func showOverlayForTesting(state: String = "recording") {
        // Layout-only fixtures: no microphone, network request or expense write.
        // Keeping a transcript in every state proves that the HUD never exposes STT.
        transcript = "VOICE_UI_TEST_PRIVATE_TRANSCRIPT"
        isRecording = state == "recording" || state == "1"
        isProcessing = state == "processing"
        audioLevel = isRecording ? 0.55 : 0
        needsAIConsent = state == "consent"
        canRetry = state == "error"
        message = canRetry ? "We couldn't prepare your expense. Please try again." : nil
        isVisible = true
    }
    #endif

    func didSave() {
        if let id = prefill?.id { pending.removeAll { $0.id == id } }
        prefill = nil
        remainingCount = pending.count
        isVisible = false
        advanceAfterReview = !pending.isEmpty
    }

    func reviewDidDismiss() {
        let advance = advanceAfterReview
        advanceAfterReview = false
        if advance {
            reviewNext()
        } else {
            pending = []
            remainingCount = 0
            cancel()
        }
    }

    func cancel() {
        generation = UUID()
        work?.cancel()
        work = nil
        speech.cancel()
        isRecording = false
        isProcessing = false
        isVisible = false
        audioLevel = 0
        needsAIConsent = false
        canRetry = false
        advanceAfterReview = false
    }

    private func refresh() {
        audioLevel = speech.audioLevel
        isRecording = speech.isRecording || speech.isAuthorizing
        if !speech.transcript.isEmpty { transcript = speech.transcript }
        if speech.isRecording || speech.isAuthorizing || speech.isFinishing || transcript.isEmpty { message = speech.message }
        if speech.isFinishing && !isProcessing { finishTranscription() }
    }
}

/// Validation of model output only; this does not infer expense fields locally.
enum VoiceAIReviewBatch {
    static func prefills(response: VoiceDraftResponse, categories: [UserCategory], currency: String, reference: Date) throws -> [VoiceExpensePrefill] {
        guard response.requiresReview, !response.saved, response.transactions.count <= 10 else { throw VoiceServiceError.invalidResponse }
        let allowed = Set(categories.map(\.id))
        return try response.transactions.filter { $0.canReviewAsExpense(currency: currency) }.map { draft in
            if let raw = draft.categoryID {
                guard let id = UUID(uuidString: raw), allowed.contains(id) else { throw VoiceServiceError.invalidResponse }
            }
            return VoiceExpensePrefill(draft: draft, referenceDate: reference)
        }
    }
}

struct InlineVoiceExpenseStatus: View {
    @ObservedObject var controller: InlineVoiceExpenseController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailsHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if controller.isProcessing {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    waveform
                }

                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice.status")
                Spacer(minLength: 0)

                if controller.isRecording {
                    Button { controller.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.red, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(voiceText("Stop recording", "Остановить запись"))
                    .accessibilityIdentifier("voice.overlay-stop")
                }
                Button { controller.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voiceText("Cancel voice entry", "Отменить голосовой ввод"))
                .accessibilityIdentifier("voice.overlay-close")
            }
            if hasDetails {
                ScrollView {
                    details
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                            detailsHeight = height
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(detailsHeight, 20), verticalSizeClass == .compact ? 96 : 200))
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 340, alignment: .leading)
        .liquidGlassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.overlay")
    }

    private var statusTitle: String {
        if controller.isRecording { return voiceText("Listening", "Слушаю") }
        if controller.isProcessing { return voiceText("Preparing expense…", "Подготовка расхода…") }
        if controller.needsAIConsent { return voiceText("Prepare your expense", "Подготовить расход") }
        if controller.canRetry { return voiceText("Try once more", "Попробуйте ещё раз") }
        return voiceText("Voice expense", "Голосовой расход")
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                Capsule()
                    .fill(controller.isRecording ? Color.primary : Color.secondary)
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(width: 34, height: 34)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.audioLevel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(voiceText("Microphone activity", "Уровень микрофона"))
        .accessibilityIdentifier("voice.waveform")
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
        let level = controller.isRecording ? CGFloat(min(max(controller.audioLevel, 0), 1)) : 0
        return 5 + weights[index] * (5 + level * 17)
    }

    private var hasDetails: Bool {
        guard !controller.isRecording, !controller.isProcessing else { return false }
        return controller.message != nil || controller.needsAIConsent || controller.canRetry
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
                if controller.canRetry {
                    Text(voiceText("Couldn't prepare this expense. Try again.", "Не удалось подготовить расход. Попробуйте снова."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.speech-message")
                } else if let message = controller.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("voice.speech-message")
                }
                if controller.needsAIConsent {
                    Text(voiceText("Allow AI to prepare expenses from your text, categories, currency and date. Audio and expense history stay on your iPhone. Nothing is saved without review.", "Разрешить ИИ подготовить расходы из текста, категорий, валюты и даты. Аудио и история расходов остаются на iPhone. Сохранение — только после проверки.")).font(.footnote)
                    Button { controller.allowAI() } label: {
                        Text(voiceText("Continue", "Продолжить"))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("voice.allow-ai")
                }
                if controller.canRetry {
                    Button { controller.retry() } label: {
                        Text(voiceText("Try again", "Попробовать снова"))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("voice.retry")
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VoiceExpenseOverlayModifier: ViewModifier {
    @ObservedObject var controller: InlineVoiceExpenseController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if controller.isVisible && controller.prefill == nil {
                InlineVoiceExpenseStatus(controller: controller)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.isVisible)
    }
}

extension View {
    func voiceExpenseOverlay(controller: InlineVoiceExpenseController) -> some View {
        modifier(VoiceExpenseOverlayModifier(controller: controller))
    }
}
