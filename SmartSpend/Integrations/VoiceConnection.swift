import Foundation
import Security
import Combine

struct VoiceConnection: Codable {
    let server: URL
    let token: String
}

enum VoiceServiceError: LocalizedError {
    case invalidServer, notConnected, connection, unauthorized, pairing, limited, provider, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServer: return voiceText("Use the private HTTPS server address ending in .ts.net, with no extra path.", "Укажите приватный HTTPS-адрес сервера .ts.net без дополнительного пути.")
        case .notConnected: return voiceText("AI access is not configured for this installation. Your text is kept; no expense was saved.", "Доступ к ИИ не настроен для этой установки. Текст сохранён, расход не создан.")
        case .connection: return voiceText("Cannot reach the server. Check your internet connection and try again.", "Сервер недоступен. Проверьте интернет и попробуйте снова.")
        case .unauthorized: return voiceText("This connection was revoked. Pair your iPhone again.", "Подключение отозвано. Подключите iPhone заново.")
        case .pairing: return voiceText("The pairing code is incorrect or expired. Request a new code on your Mac.", "Код неверен или истёк. Запросите новый код на Mac.")
        case .limited: return voiceText("The server is busy or the preview limit was reached. Try later; nothing was saved.", "Сервер занят или достигнут лимит. Попробуйте позже. Ничего не сохранено.")
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

    static func validatedServer(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, host.hasSuffix(".ts.net"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else { throw VoiceServiceError.invalidServer }
        return url
    }

    static func request(server: URL, path: String, token: String? = nil, method: String = "POST", body: Data? = nil) async throws -> Data {
        _ = try validatedServer(server.absoluteString)
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw VoiceServiceError.invalidResponse }
            guard data.count <= 65_536 else { throw VoiceServiceError.invalidResponse }
            switch response.statusCode {
            case 200: return data
            case 401: throw path == "v1/pair" ? VoiceServiceError.pairing : VoiceServiceError.unauthorized
            case 429: throw VoiceServiceError.limited
            case 502, 503, 504: throw VoiceServiceError.provider
            default: throw VoiceServiceError.invalidResponse
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as VoiceServiceError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw VoiceServiceError.connection }
    }
}

@MainActor
final class VoiceConnectionStore: ObservableObject {
    static let shared = VoiceConnectionStore()
    static let defaultServer = "https://ubuntu.onca-albacore.ts.net:10000"
    @Published private(set) var connection: VoiceConnection?
    private let service = "ai.humblebee.smartspend.private-voice"

    private init() {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
           let stored = try? JSONDecoder().decode(VoiceConnection.self, from: data),
           (try? VoiceAPI.validatedServer(stored.server.absoluteString)) != nil {
            connection = stored
        }
        #if DEBUG
        // Owner-only development provisioning over the paired Mac. Not bundled
        // in the app and never a shared credential for public distribution.
        if let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let file = directory.appendingPathComponent(".smartspend-voice-connection.json")
            if let data = try? Data(contentsOf: file), data.count <= 4096,
               let provisioned = try? VoiceDevelopmentProvisioning.decode(data) {
                let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
                var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    status = SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
                }
                if status == errSecSuccess {
                    connection = provisioned
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        #endif
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "paired-phone"]
    }

    func pair(server text: String, code: String) async throws {
        let server = try VoiceAPI.validatedServer(text)
        guard code.count == 32, code.range(of: #"^[A-Za-z0-9_-]{32}$"#, options: .regularExpression) != nil else { throw VoiceServiceError.pairing }
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        let data = try await VoiceAPI.request(server: server, path: "v1/pair", body: body)
        struct PairResponse: Decodable { let token: String }
        guard let response = try? JSONDecoder().decode(PairResponse.self, from: data),
              response.token.range(of: #"^[A-Za-z0-9_-]{40,100}$"#, options: .regularExpression) != nil else { throw VoiceServiceError.invalidResponse }
        let paired = VoiceConnection(server: server, token: response.token)
        let encoded = try JSONEncoder().encode(paired)
        let attributes: [String: Any] = [kSecValueData as String: encoded, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(keychainQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            _ = try? await VoiceAPI.request(server: server, path: "v1/device", token: response.token, method: "DELETE")
            throw VoiceServiceError.notConnected
        }
        connection = paired
    }

    func disconnect() async {
        let previous = connection
        SecItemDelete(keychainQuery as CFDictionary)
        connection = nil
        if let connection = previous {
            _ = try? await VoiceAPI.request(server: connection.server, path: "v1/device", token: connection.token, method: "DELETE")
        }
    }

    func drafts(text: String, categories: [UserCategory], currency: Currency, reference: Date, requestID: UUID) async throws -> VoiceDraftResponse {
        guard let connection else { throw VoiceServiceError.notConnected }
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
        let data = try await VoiceAPI.request(server: connection.server, path: "v1/drafts", token: connection.token, body: body)
        guard let response = try? JSONDecoder().decode(VoiceDraftResponse.self, from: data),
              response.requiresReview, !response.saved, response.transactions.count <= 10,
              response.unresolvedFields.count <= 30 else { throw VoiceServiceError.invalidResponse }
        return response
    }
}

#if DEBUG
@MainActor
enum VoiceDevelopmentProvisioning {
    static func decode(_ data: Data) throws -> VoiceConnection {
        guard data.count <= 4096,
              let result = try? JSONDecoder().decode(VoiceConnection.self, from: data),
              result.server.absoluteString == VoiceConnectionStore.defaultServer,
              result.token.count >= 40, result.token.count <= 100,
              result.token.range(of: #"^[A-Za-z0-9_-]{40,100}$"#, options: .regularExpression) != nil else { throw VoiceServiceError.invalidResponse }
        return result
    }
}
#endif
