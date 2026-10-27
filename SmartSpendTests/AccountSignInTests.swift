import Foundation
import Testing
@testable import SmartSpend

@Suite("Apple account display")
struct AccountSignInTests {
    @Test("Title prefers full name, then email, then Apple ID")
    func titleFallbacks() {
        #expect(AppleAccountDisplay.title(for: AppleAccount(userID: "u", fullName: "Ada Lovelace", email: "ada@example.com")) == "Ada Lovelace")
        #expect(AppleAccountDisplay.title(for: AppleAccount(userID: "u", fullName: "  ", email: "ada@example.com")) == "ada@example.com")
        #expect(AppleAccountDisplay.title(for: AppleAccount(userID: "u", fullName: nil, email: nil)) == "account_apple_id".localized)
        #expect(AppleAccountDisplay.title(for: nil) == "account_apple_id".localized)
    }

    @Test("Subtitle shows the email only when the title doesn't already")
    func subtitle() {
        #expect(AppleAccountDisplay.subtitle(for: AppleAccount(userID: "u", fullName: "Ada", email: "ada@example.com")) == "ada@example.com")
        #expect(AppleAccountDisplay.subtitle(for: AppleAccount(userID: "u", fullName: nil, email: "ada@example.com")) == "account_signed_in_with_apple".localized)
        #expect(AppleAccountDisplay.subtitle(for: AppleAccount(userID: "u", fullName: nil, email: nil)) == "account_signed_in_with_apple".localized)
        #expect(AppleAccountDisplay.subtitle(for: nil) == "account_not_signed_in".localized)
    }

    @Test("Display strings are localized, not raw keys")
    func localized() {
        #expect("account_apple_id".localized == "Apple ID")
        #expect("account_signed_in_with_apple".localized == "Signed in with Apple")
    }
}
