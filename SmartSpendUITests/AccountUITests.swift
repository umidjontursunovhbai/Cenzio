import XCTest

final class AccountUITests: XCTestCase {
    @MainActor
    func testAccountShowsAppleOnlyAndKeepsDataLocal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        let settings = app.buttons["tab.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let account = app.buttons["settings.account"]
        for _ in 0..<4 where !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.isHittable)
        account.tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your expenses are stored only on this iPhone. Signing out doesn't delete them."].exists)
        XCTAssertFalse(app.secureTextFields.element.exists)
        // Apple is the only sign-in provider; the old web sign-in buttons are gone.
        XCTAssertFalse(app.buttons["account.signIn.google"].exists)
        XCTAssertFalse(app.buttons["account.signIn.telegram"].exists)
        XCTAssertFalse(app.buttons["account.delete"].exists)
        // Open and cancel the confirmation only; never sign the owner out.
        let signOut = app.buttons["account.signOut"]
        if signOut.exists {
            signOut.tap()
            XCTAssertTrue(app.staticTexts["Sign out of Cenzio?"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Account"].exists)
        }
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Account"].exists)
        app.terminate()
    }
}
