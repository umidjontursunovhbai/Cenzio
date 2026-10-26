import Foundation
import Testing
@testable import SmartSpend

@Suite("Account sign-in safety")
struct AccountSignInTests {
    @Test("PKCE uses the RFC 7636 SHA256 vector")
    func pkce() {
        #expect(AccountSignInSecurity.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Random state and verifier are URL safe, distinct and sufficiently long")
    func randomValues() throws {
        let first = try AccountSignInSecurity.randomValue()
        let second = try AccountSignInSecurity.randomValue()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil)
    }

    @Test("Native callbacks require exact route and matching one-time state")
    func callbacks() throws {
        let code = "test-one-time-code-long-enough"
        #expect(try AccountSignInSecurity.callbackCode(URL(string: "smartspend://account/callback?code=\(code)&state=expected")!, state: "expected") == code)
        for text in [
            "smartspend://account/callback?code=\(code)&state=wrong",
            "https://account/callback?code=\(code)&state=expected",
            "smartspend://wrong/callback?code=\(code)&state=expected",
            "smartspend://account/other?code=\(code)&state=expected",
            "smartspend://account/callback?code=\(code)&state=expected&state=wrong",
            "smartspend://account/callback?code=\(code)&state=expected&error=sign_in_failed",
            "smartspend://account/callback?code=\(code)&code=another&state=expected"
        ] {
            #expect(throws: AccountSignInError.self) {
                try AccountSignInSecurity.callbackCode(URL(string: text)!, state: "expected")
            }
        }
    }

    @Test("Authorization rejects impostor hosts and non-HTTPS URLs")
    func authorizationHosts() throws {
        let server = URL(string: "https://sync.example.com:10000")!
        #expect(try AccountSignInSecurity.authorizationURL("https://accounts.google.com/o/oauth2/v2/auth", provider: .google, server: server).host == "accounts.google.com")
        for text in ["http://accounts.google.com/o/oauth2/v2/auth", "https://accounts.google.com.evil.example/auth",
                     "https://user@accounts.google.com/auth", "https://sync.example.com:9999/auth"] {
            #expect(throws: AccountSignInError.self) {
                try AccountSignInSecurity.authorizationURL(text, provider: .google, server: server)
            }
        }
    }
}
