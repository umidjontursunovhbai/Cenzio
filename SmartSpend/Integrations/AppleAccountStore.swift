import AuthenticationServices
import Foundation
import Security

/// The signed-in Apple ID. Name and email are only delivered by Apple on the first
/// authorization, so they are kept from the stored copy on later sign-ins.
struct AppleAccount: Codable, Equatable {
    let userID: String
    var fullName: String?
    var email: String?
}

/// Owns the Sign in with Apple session. Expenses never depend on this state;
/// it only gates the UI.
@MainActor
final class AppleAccountStore: ObservableObject {
    static let shared = AppleAccountStore()

    enum State: Equatable {
        case checking
        case signedOut
        case signedIn(AppleAccount)
    }

    @Published private(set) var state: State = .checking
    /// Localized message for the last non-cancellation sign-in failure.
    @Published private(set) var errorMessage: String?

    var account: AppleAccount? {
        if case .signedIn(let account) = state { return account }
        return nil
    }

    private let keychain = AppleAccountKeychain(service: "ai.humblebee.smartspend.apple-account")
    private var revocationObserver: NSObjectProtocol?

    private init() {
        if let stored = keychain.load() {
            state = .signedIn(stored)
        } else {
            // Nothing stored means nothing to verify: show the gate at once instead of a blank screen.
            state = .signedOut
        }
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.signOut() }
        }
    }

    // MARK: - Sign in

    func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "apple_signin_error_generic".localized
                return
            }
            let incoming = AppleAccount(
                userID: credential.user,
                fullName: Self.formattedName(credential.fullName),
                email: credential.email
            )
            let merged = Self.merge(stored: keychain.load(), incoming: incoming)
            keychain.save(merged)
            errorMessage = nil
            state = .signedIn(merged)
        case .failure(let error):
            if Self.isCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription.isEmpty
                    ? "apple_signin_error_generic".localized
                    : error.localizedDescription
            }
        }
    }

    func signOut() {
        keychain.delete()
        errorMessage = nil
        state = .signedOut
    }

    /// Re-validates the stored Apple ID with Apple. Call on launch and when the app becomes active.
    func refreshCredentialState() async {
        guard let stored = keychain.load() else {
            state = .signedOut
            return
        }
        let outcome: CredentialCheck
        do {
            let credentialState = try await Self.credentialState(for: stored.userID)
            outcome = .state(credentialState)
        } catch {
            outcome = .failed
        }
        // The keychain may have been cleared while the check was in flight.
        let current = keychain.load()
        state = Self.resolve(outcome, stored: current)
        if case .signedOut = state, current != nil {
            keychain.delete()
        }
    }

    // MARK: - Pure rules (unit-tested)

    enum CredentialCheck: Equatable {
        case state(ASAuthorizationAppleIDProvider.CredentialState)
        case failed
    }

    /// Maps a credential check to the session state.
    /// `.revoked` / `.notFound` sign out; `.authorized` keeps the session; a failed or
    /// transient check keeps a stored account signed in.
    nonisolated static func resolve(_ check: CredentialCheck, stored: AppleAccount?) -> State {
        guard let stored else { return .signedOut }
        switch check {
        case .state(.revoked), .state(.notFound):
            return .signedOut
        case .state(.authorized), .failed:
            return .signedIn(stored)
        case .state:
            // `.transferred` or future cases: keep the user signed in.
            return .signedIn(stored)
        }
    }

    /// Apple only returns name and email on the first authorization; keep the stored
    /// values when a later sign-in for the same user returns nil.
    nonisolated static func merge(stored: AppleAccount?, incoming: AppleAccount) -> AppleAccount {
        guard let stored, stored.userID == incoming.userID else { return incoming }
        return AppleAccount(
            userID: incoming.userID,
            fullName: nonEmpty(incoming.fullName) ?? stored.fullName,
            email: nonEmpty(incoming.email) ?? stored.email
        )
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled { return true }
        let nsError = error as NSError
        return nsError.domain == ASAuthorizationError.errorDomain
            && nsError.code == ASAuthorizationError.Code.canceled.rawValue
    }

    // MARK: - Helpers

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func formattedName(_ components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        return nonEmpty(name)
    }

    private static func credentialState(for userID: String) async throws
        -> ASAuthorizationAppleIDProvider.CredentialState {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: state)
                }
            }
        }
    }
}

/// Minimal Keychain wrapper storing one JSON-encoded `AppleAccount`.
private struct AppleAccountKeychain {
    let service: String
    private let accountKey = "apple-account"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
        ]
    }

    func load() -> AppleAccount? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AppleAccount.self, from: data)
    }

    func save(_ account: AppleAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
