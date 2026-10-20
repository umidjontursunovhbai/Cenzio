import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class ExpenseSpeechRecorder: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var isAuthorizing = false
    @Published var message: String?
    @Published private(set) var audioLevel: Float = 0
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var locale = "en-US"
    private var peakPower: Float = -160
    private var generation = UUID()
    private var finishingTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?

    func start(locale: String) async {
        cancel()
        let identifier = UUID()
        generation = identifier
        isAuthorizing = true
        defer { if generation == identifier { isAuthorizing = false } }
        message = nil
        transcript = ""
        self.locale = locale
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, generation == identifier else { return }
        guard speech == .authorized else {
            message = voiceText("Allow Speech Recognition for SmartSpend in iPhone Settings, then try recording again.", "Разрешите распознавание речи для SmartSpend в настройках iPhone, затем повторите запись.")
            return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled, generation == identifier else { return }
        guard microphone else {
            message = voiceText("Allow Microphone access for SmartSpend in iPhone Settings, then try recording again.", "Разрешите доступ к микрофону для SmartSpend в настройках iPhone, затем повторите запись.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("smartspend-voice-\(UUID().uuidString).caf")
            recordingURL = url
            let capture = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            capture.isMeteringEnabled = true
            guard capture.prepareToRecord(), capture.record() else { throw LocalSpeechFailure.emptyRecording }
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
            recorder = capture
            peakPower = -160
            isRecording = true
            isAuthorizing = false
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, let self, self.generation == identifier, let capture = self.recorder else { return }
                    capture.updateMeters()
                    self.peakPower = max(self.peakPower, capture.peakPower(forChannel: 0))
                    self.audioLevel = min(1, pow(10, capture.averagePower(forChannel: 0) / 30))
                    if capture.currentTime >= 55 { self.finish(); return }
                }
            }
        } catch {
            cancel()
            message = voiceText("Cannot start the microphone. Close other recording apps and try again.", "Не удалось включить микрофон. Закройте другие приложения записи и повторите.")
        }
    }

    func finish() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        isFinishing = true
        let identifier = generation
        guard let url = recordingURL else { isFinishing = false; return }
        let selectedLocale = locale
        finishingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: url)
                if self.generation == identifier {
                    self.recordingURL = nil
                    self.isFinishing = false
                }
            }
            do {
                let text = try await LocalExpenseTranscriber.transcribe(fileURL: url, locale: selectedLocale) { [weak self] status in
                    guard self?.generation == identifier else { return }
                    self?.message = status
                }
                guard !Task.isCancelled, self.generation == identifier else { return }
                self.transcript = text
                self.message = nil
            } catch {
                guard !Task.isCancelled, self.generation == identifier else { return }
                if self.peakPower < -70 {
                    self.message = voiceText("No microphone audio was captured. Check microphone access and try again.", "Звук с микрофона не записан. Проверьте доступ к микрофону и повторите.")
                } else if error is LocalSpeechFailure {
                    self.message = voiceText("Audio was recorded, but speech could not be transcribed. Please try again. Nothing was uploaded.", "Звук записан, но речь не распознана. Попробуйте ещё раз. Ничего не отправлено.")
                } else {
                    self.message = SpeechRecognitionFeedback.message(for: error as NSError)
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        meterTask?.cancel()
        finishingTask?.cancel()
        meterTask = nil
        finishingTask = nil
        recorder?.stop()
        recorder = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        isFinishing = false
        isAuthorizing = false
    }

}

enum SpeechRecognitionFeedback {
    static var noSpeech: String {
        voiceText("No speech recognized. Please try recording again.", "Речь не распознана. Попробуйте записать ещё раз.")
    }

    static func message(for error: NSError) -> String {
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 102):
            return voiceText("The speech model is not installed. Enable Dictation in iPhone Settings → General → Keyboard, let its download finish, then retry. Audio was not uploaded.", "Модель речи не установлена. Включите диктовку: Настройки → Основные → Клавиатура, дождитесь загрузки и повторите. Аудио не отправлено.")
        case ("kLSRErrorDomain", 201):
            return voiceText("Dictation is disabled. Enable it in iPhone Settings → General → Keyboard, then retry.", "Диктовка отключена. Включите её: Настройки → Основные → Клавиатура, затем повторите.")
        case ("kAFAssistantErrorDomain", 1700):
            return voiceText("Allow Speech Recognition for SmartSpend in iPhone Settings, then retry.", "Разрешите распознавание речи для SmartSpend в настройках iPhone и повторите.")
        case ("kAFAssistantErrorDomain", 1110):
            return noSpeech
        case ("kAFAssistantErrorDomain", 1101), ("kAFAssistantErrorDomain", 1107):
            return voiceText("The iPhone speech service stopped. Start a new recording to try again. Audio was not uploaded.", "Служба распознавания iPhone остановилась. Начните новую запись. Аудио не отправлено.")
        default:
            // Never surface raw provider descriptions that may include user data.
            return voiceText("Speech recognition stopped. Your recognized words are kept. Tap the microphone to retry.", "Распознавание остановилось. Уже распознанный текст сохранён. Нажмите микрофон ещё раз.")
        }
    }
}
