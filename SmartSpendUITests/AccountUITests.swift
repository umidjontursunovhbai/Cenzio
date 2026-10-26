import XCTest

final class AccountUITests: XCTestCase {
    @MainActor
    func testAccountIsOptionalAndDoesNotStartSyncOrSignIn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let settings = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let account = app.buttons["settings.account"]
        for _ in 0..<4 where !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.isHittable)
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sign-in is optional. Your expenses stay on this iPhone; signing in doesn't turn on sync."].exists)
        XCTAssertFalse(app.secureTextFields.element.exists)
        XCTAssertFalse(app.buttons["Connect Google Sheets"].exists)
        // Do not initiate OAuth, upload a ledger, or alter the owner's existing session.
        if app.buttons["account.signOut"].exists {
            XCTAssertTrue(app.buttons["account.delete"].exists)
        } else {
            XCTAssertTrue(app.buttons["account.signIn.google"].exists)
            XCTAssertTrue(app.buttons["account.signIn.apple"].exists)
            XCTAssertTrue(app.buttons["account.signIn.telegram"].exists)
        }
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Account"].exists)
        app.terminate()
    }
}
