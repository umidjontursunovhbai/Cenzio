import AuthenticationServices
import Foundation
import Testing
@testable import SmartSpend

@Suite("Apple account store")
struct AppleAccountStoreTests {
    private let stored = AppleAccount(userID: "001.abc", fullName: "Ada Lovelace", email: "ada@privaterelay.appleid.com")

    // MARK: Merge rule

    @Test("Later sign-ins without name/email keep the stored ones")
    func keepsStoredNameAndEmail() {
        let incoming = AppleAccount(userID: "001.abc", fullName: nil, email: nil)
        #expect(AppleAccountStore.merge(stored: stored, incoming: incoming) == stored)
    }

    @Test("Blank values from Apple count as missing")
    func blankValuesAreIgnored() {
        let incoming = AppleAccount(userID: "001.abc", fullName: "  ", email: "")
        #expect(AppleAccountStore.merge(stored: stored, incoming: incoming) == stored)
    }

    @Test("New name/email from Apple replace the stored ones")
    func freshValuesWin() {
        let incoming = AppleAccount(userID: "001.abc", fullName: "Ada King", email: nil)
        let merged = AppleAccountStore.merge(stored: stored, incoming: incoming)
        #expect(merged.fullName == "Ada King")
        #expect(merged.email == stored.email)
    }

    @Test("A different Apple ID never inherits the stored profile")
    func differentUserDoesNotMerge() {
        let incoming = AppleAccount(userID: "002.xyz", fullName: nil, email: nil)
        #expect(AppleAccountStore.merge(stored: stored, incoming: incoming) == incoming)
    }

    @Test("First sign-in uses what Apple returned")
    func firstSignIn() {
        let incoming = AppleAccount(userID: "001.abc", fullName: "Ada", email: "a@b.c")
        #expect(AppleAccountStore.merge(stored: nil, incoming: incoming) == incoming)
    }

    // MARK: Credential state mapping

    @Test("Authorized keeps the stored account signed in")
    func authorized() {
        #expect(AppleAccountStore.resolve(.state(.authorized), stored: stored) == .signedIn(stored))
    }

    @Test("Revoked and not-found sign out", arguments: [
        ASAuthorizationAppleIDProvider.CredentialState.revoked,
        .notFound,
    ])
    func signsOut(state: ASAuthorizationAppleIDProvider.CredentialState) {
        #expect(AppleAccountStore.resolve(.state(state), stored: stored) == .signedOut)
    }

    @Test("A failed check keeps a stored account signed in")
    func transientFailure() {
        #expect(AppleAccountStore.resolve(.failed, stored: stored) == .signedIn(stored))
    }

    @Test("Without a stored account the user is signed out")
    func noStoredAccount() {
        #expect(AppleAccountStore.resolve(.failed, stored: nil) == .signedOut)
        #expect(AppleAccountStore.resolve(.state(.authorized), stored: nil) == .signedOut)
    }

    // MARK: Cancellation

    @Test("User cancellation is not an error")
    func cancellation() {
        #expect(AppleAccountStore.isCancellation(ASAuthorizationError(.canceled)))
        #expect(!AppleAccountStore.isCancellation(ASAuthorizationError(.failed)))
        #expect(!AppleAccountStore.isCancellation(NSError(domain: "x", code: 1001)))
    }
}
