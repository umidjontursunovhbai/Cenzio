import AVFoundation
import Foundation
import Speech
import Testing
@testable import SmartSpend

/// Real on-device decoder integration checks, not mocked transcripts. The fixtures
/// are generated with macOS system voices; they contain no user's financial data.
/// First execution may download Apple's speech assets. No audio is uploaded.
@Suite("Offline expense speech decoder", .serialized)
@MainActor
struct LocalExpenseTranscriberTests {
    @Test("English synthetic speech preserves the expense and amount", .timeLimit(.minutes(3)))
    func englishAudio() async throws {
        let text = try await transcribeFixture("synthetic-expense-en", locale: "en_US")
        let normalized = normalize(text)
        #expect(normalized.contains("taxi"), "English fixture must preserve its expense noun.")
        #expect(
            normalized.filter(\.isNumber).contains("15800") || normalized.contains("fifteen thousand eight hundred"),
            "English fixture must preserve the synthetic amount."
        )
    }

    @Test("Russian synthetic speech preserves the expense and amount", .timeLimit(.minutes(3)))
    func russianAudio() async throws {
        let text = try await transcribeFixture("synthetic-expense-ru", locale: "ru_RU")
        let normalized = normalize(text)
        #expect(normalized.contains("такси"), "Russian fixture must preserve its expense noun.")
        #expect(
            normalized.filter(\.isNumber).contains("15800") || normalized.contains("пятнадцать тысяч восемьсот"),
            "Russian fixture must preserve the synthetic amount."
        )
    }

    private func transcribeFixture(_ name: String, locale: String) async throws -> String {
        #if targetEnvironment(simulator)
        throw FixtureError.physicalDeviceRequired
        #else
        // New SpeechAnalyzer runs entirely locally; no microphone is opened.
        // Older builds use the legacy authorization requirements.
        if #unavailable(iOS 26.0) {
            try #require(SFSpeechRecognizer.authorizationStatus() == .authorized)
        }
        let bundle = Bundle(for: FixtureBundleMarker.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "aiff", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "aiff"),
            "Synthetic audio fixture must be included in the test bundle."
        )
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
        #expect(file.processingFormat.sampleRate > 0)
        let transcript = try await LocalExpenseTranscriber.transcribe(fileURL: url, locale: locale, status: { _ in })
        #expect(!transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return transcript
        #endif
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class FixtureBundleMarker: NSObject {}
private enum FixtureError: Error { case physicalDeviceRequired }
