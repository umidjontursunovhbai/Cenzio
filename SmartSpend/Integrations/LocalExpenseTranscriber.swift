import Foundation
import AVFoundation
import Speech

enum LocalSpeechFailure: Error { case unsupportedLanguage, emptyRecording, noSpeech }

/// Audio never leaves the device. Modern speech assets are explicitly prepared.
@MainActor
enum LocalExpenseTranscriber {
    static func transcribe(fileURL: URL, locale: String, status: @escaping @MainActor (String) -> Void) async throws -> String {
        if #available(iOS 26.0, *) {
            if SpeechTranscriber.isAvailable,
               let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
                let module = SpeechTranscriber(locale: supported, preset: .transcription)
                return try await analyze(fileURL: fileURL, module: module, locale: supported, status: status) {
                    var text = ""
                    for try await result in module.results {
                        if result.isFinal { text += " " + String(result.text.characters) }
                    }
                    return text
                }
            }
            // Russian is not supported by every SpeechTranscriber model.
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
                let module = DictationTranscriber(locale: supported, preset: .longDictation)
                return try await analyze(fileURL: fileURL, module: module, locale: supported, status: status) {
                    var text = ""
                    for try await result in module.results {
                        if result.isFinal { text += " " + String(result.text.characters) }
                    }
                    return text
                }
            }
        }
        let job = LegacyExpenseFileTranscriber()
        return try await job.run(fileURL: fileURL, locale: locale)
    }

    @available(iOS 26.0, *)
    private static func analyze(fileURL: URL, module: any SpeechModule, locale: Locale,
                                status: @escaping @MainActor (String) -> Void,
                                results: @escaping @MainActor () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        try await AssetInventory.reserve(locale: locale)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            status(voiceText("Preparing speech model — first use may need a download…", "Подготовка модели речи — при первом запуске может потребоваться загрузка…"))
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        status(voiceText("Transcribing on this iPhone…", "Распознавание на этом iPhone…"))
        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > 0 else { throw LocalSpeechFailure.emptyRecording }
        let analyzer = SpeechAnalyzer(modules: [module])
        let reader = Task { try await results() }
        // Model downloads are allowed to finish; a stalled decoder must not
        // leave the expense button spinning forever after assets are ready.
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            await analyzer.cancelAndFinishNow()
            reader.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do {
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await reader.value.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw LocalSpeechFailure.noSpeech }
                return text
            } catch {
                await analyzer.cancelAndFinishNow()
                reader.cancel()
                throw error
            }
        } onCancel: {
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

/// Compatibility for older iOS versions, still strictly on-device.
@MainActor
private final class LegacyExpenseFileTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var text = ""

    func run(fileURL: URL, locale: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw LocalSpeechFailure.unsupportedLanguage }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        if let text { self.text = text }
                        if final || error != nil {
                            if !self.text.isEmpty { self.complete(.success(self.text)) }
                            else { self.complete(.failure(error ?? LocalSpeechFailure.noSpeech)) }
                        }
                    }
                }
                deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self else { return }
                    self.complete(self.text.isEmpty ? .failure(LocalSpeechFailure.noSpeech) : .success(self.text))
                }
            }
        } onCancel: { Task { @MainActor in self.complete(.failure(CancellationError())) } }
    }

    private func complete(_ result: Result<String, Error>) {
        let waiting = continuation
        continuation = nil
        deadline?.cancel()
        task?.cancel()
        task = nil
        recognizer = nil
        waiting?.resume(with: result)
    }
}
