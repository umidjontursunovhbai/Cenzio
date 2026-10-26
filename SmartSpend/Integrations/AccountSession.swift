import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

enum AccountProvider: String, Codable, CaseIterable, Identifiable {
    case google, apple, telegram
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

struct SmartSpendAccount: Codable, Equatable {
    let id: String
    let provider: AccountProvider
    let email: String?
    let displayName: String?
}

struct AccountProviderAvailability: Decodable {
    let id: AccountProvider
    let available: Bool
}

struct AccountCredential: Codable {
    let accessToken: String
    let expiresAt: Int
    let account: SmartSpendAccount
}

enum AccountSignInError: LocalizedError {
    case invalidResponse, unavailable, unauthorized, storage, connection
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Sign-in couldn't be completed. Please try again."
        case .unavailable: "This sign-in option isn't available yet."
        case .unauthorized: "Your session has expired. Please sign in again."
        case .storage: "Couldn't securely save your sign-in on this iPhone."
        case .connection: "Couldn't reach the sign-in service. Please try again."
        }
    }
}

enum AccountSignInSecurity {
    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AccountSignInError.storage
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizationURL(_ text: String, provider: AccountProvider, server: URL) throws -> URL {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil else { throw AccountSignInError.invalidResponse }
        let expectedHost: String
        let expectedPath: String
        switch provider {
        case .google: expectedHost = "accounts.google.com"; expectedPath = "/o/oauth2/v2/auth"
        case .apple: expectedHost = "appleid.apple.com"; expectedPath = "/auth/authorize"
        case .telegram: expectedHost = "oauth.telegram.org"; expectedPath = "/auth"
        }
        guard url.host == expectedHost, url.path == expectedPath, url.port == nil || url.port == 443 else {
            throw AccountSignInError.invalidResponse
        }
        return url
    }

    static func callbackCode(_ url: URL, state: String) throws -> String {
        guard url.scheme == "smartspend", url.host == "account", url.path == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.count >= 20, code.count <= 200 else { throw AccountSignInError.invalidResponse }
        return code
    }
}

private enum AccountKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.tursunov.SmartSpend.account",
         kSecAttrAccount as String: "session",
         kSecAttrSynchronizable as String: false]
    }
    static func load() -> AccountCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AccountCredential.self, from: data)
    }
    static func save(_ credential: AccountCredential) throws {
        let values: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw AccountSignInError.storage
            }
        } else if result != errSecSuccess { throw AccountSignInError.storage }
    }
    static func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AccountSignInError.storage }
    }
}

private final class AccountNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class AccountSessionStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AccountSessionStore()
    @Published private(set) var account: SmartSpendAccount?
    @Published private(set) var providers: [AccountProviderAvailability] = []
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published var message: String?
    private var credential: AccountCredential?
    private var browserSession: ASWebAuthenticationSession?
    private let server: URL
    private let network = URLSession(configuration: .ephemeral, delegate: AccountNoRedirects(), delegateQueue: nil)

    private override init() {
        // Account tokens are never sent to custom voice/sync endpoints.
        server = URL(string: VoiceConnectionStore.defaultServer)!
        credential = AccountKeychain.load()
        if let credential, credential.expiresAt > Int(Date().timeIntervalSince1970) {
            account = credential.account
        }
        super.init()
    }

    func available(_ provider: AccountProvider) -> Bool {
        providers.first(where: { $0.id == provider })?.available == true
    }

    func refresh() async {
        guard !loading, !busy else { return }
        loading = true
        defer { loading = false }
        do {
            struct Providers: Decodable { let providers: [AccountProviderAvailability] }
            let result: Providers = try await request("providers")
            providers = result.providers
            if let credential {
                if credential.expiresAt <= Int(Date().timeIntervalSince1970) {
                    try clearSession()
                } else {
                    struct Profile: Decodable { let account: SmartSpendAccount }
                    let profile: Profile = try await request("me", token: credential.accessToken)
                    account = profile.account
                }
            }
            message = nil
        } catch is CancellationError { }
        catch AccountSignInError.unauthorized {
            do { try clearSession() } catch { message = error.localizedDescription; return }
            message = AccountSignInError.unauthorized.localizedDescription
        } catch { providers = []; message = error.localizedDescription }
    }

    func signIn(_ provider: AccountProvider) async {
        guard !busy, !loading, available(provider) else { return }
        busy = true
        message = nil
        defer { busy = false; browserSession = nil }
        do {
            let verifier = try AccountSignInSecurity.randomValue()
            let state = try AccountSignInSecurity.randomValue()
            struct Started: Decodable { let authorizationURL: String }
            let started: Started = try await request("start", body: ["provider": provider.rawValue,
                "codeChallenge": AccountSignInSecurity.challenge(verifier), "state": state])
            let url = try AccountSignInSecurity.authorizationURL(started.authorizationURL, provider: provider, server: server)
            let callback = try await authenticate(url)
            let code = try AccountSignInSecurity.callbackCode(callback, state: state)
            let signedIn: AccountCredential = try await request("exchange", body: ["code": code,
                "codeVerifier": verifier, "state": state])
            guard signedIn.accessToken.range(of: #"^[A-Za-z0-9_-]{32,512}$"#, options: .regularExpression) != nil,
                  signedIn.expiresAt > Int(Date().timeIntervalSince1970),
                  signedIn.account.provider == provider else { throw AccountSignInError.invalidResponse }
            try AccountKeychain.save(signedIn)
            credential = signedIn
            account = signedIn.account
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }

    func signOut() async {
        guard !busy, !loading else { return }
        busy = true
        defer { busy = false }
        var revocationFailed = false
        if let credential {
            do {
                struct Result: Decodable { let signedOut: Bool }
                let _: Result = try await request("logout", body: [:], token: credential.accessToken)
            } catch { revocationFailed = true }
        }
        do {
            try clearSession()
            message = revocationFailed ? "Signed out on this iPhone. The server session couldn't be revoked; it will expire automatically." : nil
        } catch { message = error.localizedDescription }
    }

    func deleteAccount() async {
        guard !busy, !loading, let credential else { return }
        busy = true
        defer { busy = false }
        do {
            struct Result: Decodable { let deleted: Bool }
            let result: Result = try await request("me", method: "DELETE", token: credential.accessToken)
            guard result.deleted else { throw AccountSignInError.invalidResponse }
            try clearSession()
            message = "Account deleted. Expenses on this iPhone are unchanged."
        } catch { message = error.localizedDescription }
    }

    private func clearSession() throws {
        try AccountKeychain.remove()
        credential = nil
        account = nil
    }

    private func request<T: Decodable>(_ path: String, method: String? = nil,
                                      body: [String: String]? = nil, token: String? = nil) async throws -> T {
        var request = URLRequest(url: server.appendingPathComponent("v1/account/\(path)"))
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await network.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 65_536 else {
                throw AccountSignInError.invalidResponse
            }
            switch response.statusCode {
            case 200...299: return try JSONDecoder().decode(T.self, from: data)
            case 401: throw AccountSignInError.unauthorized
            case 404, 503: throw AccountSignInError.unavailable
            default: throw AccountSignInError.invalidResponse
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AccountSignInError { throw error }
        catch { throw AccountSignInError.connection }
    }

    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "smartspend") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else { continuation.resume(throwing: AccountSignInError.invalidResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            browserSession = session
            guard session.start() else {
                continuation.resume(throwing: AccountSignInError.unavailable)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }
}
