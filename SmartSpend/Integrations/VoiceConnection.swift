import Foundation

enum VoiceServiceError: LocalizedError {
    case notConnected, connection, limited, provider, invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return voiceText("AI is not available right now. Your text is kept; no expense was saved.", "ИИ сейчас недоступен. Текст сохранён, расход не создан.")
        case .connection: return voiceText("Cannot reach the server. Check your internet connection and try again.", "Сервер недоступен. Проверьте интернет и попробуйте снова.")
        case .limited: return voiceText("Too many requests. Try again in a minute; nothing was saved.", "Слишком много запросов. Попробуйте через минуту. Ничего не сохранено.")
        case .provider: return voiceText("AI could not prepare a draft. Your text is still here; retry when ready.", "ИИ не смог подготовить черновик. Текст сохранён на экране — попробуйте ещё раз.")
        case .invalidResponse: return voiceText("The server returned an invalid draft. Nothing was saved.", "Сервер вернул некорректный черновик. Ничего не сохранено.")
        }
    }
}

func voiceText(_ english: String, _ russian: String) -> String {
    LocalizationManager.shared.currentLanguage == .russian ? russian : english
}

private final class VoiceNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum VoiceAPI {
    /// Cloudflare Worker in `voice-worker/`. It holds the OpenRouter key; the app holds no credential.
    static let endpoint = URL(string: "https://cenzio-voice.cenzio.workers.dev")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: VoiceNoRedirects(), delegateQueue: nil)
    }()

    static func request(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw VoiceServiceError.invalidResponse }
            guard data.count <= 65_536 else { throw VoiceServiceError.invalidResponse }
            switch response.statusCode {
            case 200: return data
            case 429: throw VoiceServiceError.limited
            case 502, 504: throw VoiceServiceError.provider
            case 503: throw VoiceServiceError.notConnected
            default: throw VoiceServiceError.invalidResponse
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as VoiceServiceError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw VoiceServiceError.connection }
    }

    static func drafts(text: String, categories: [UserCategory], currency: Currency, reference: Date, requestID: UUID) async throws -> VoiceDraftResponse {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let body = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID.uuidString.lowercased(), "transcript": text,
            "categories": categories.map { ["id": $0.id.uuidString.lowercased(), "name": $0.name] },
            "currency": currency.rawValue, "reference_date": formatter.string(from: reference),
            "time_zone": TimeZone.current.identifier, "consent": true
        ])
        let data = try await request(path: "v1/drafts", body: body)
        guard let response = try? JSONDecoder().decode(VoiceDraftResponse.self, from: data),
              response.requiresReview, !response.saved, response.transactions.count <= 10,
              response.unresolvedFields.count <= 30 else { throw VoiceServiceError.invalidResponse }
        return response
    }
}
