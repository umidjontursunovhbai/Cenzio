//
//  SmartSpendUITests.swift
//  SmartSpendUITests
//
//  Created by Umidjon Tursunov on 23/08/2025.
//

import XCTest

final class SmartSpendUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testIntegrationsUsesConsumerControlsWithoutMCPOrCredentials() {
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        let settingsTab = app.buttons["tab.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let integrations = app.buttons["settings.integrations"]
        for _ in 0..<4 where !integrations.isHittable { app.swipeUp() }
        XCTAssertTrue(integrations.isHittable)
        XCTAssertFalse(app.staticTexts["AI tools (MCP)"].exists)
        integrations.tap()
        XCTAssertTrue(app.navigationBars["Integrations"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Notion"].exists)
        XCTAssertFalse(app.textFields["https://your-server.example"].exists)
        XCTAssertFalse(app.secureTextFields["Dedicated sync access token"].exists)
        XCTAssertFalse(app.staticTexts["AI tools (MCP)"].exists)
        XCTAssertFalse(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.buttons["Connect Notion"].exists)
        XCTAssertFalse(app.staticTexts["Google Sheets"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Integrations — Notion without developer credentials"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // No Connect tap: do not upload or alter the user's ledger/provider data.
        app.terminate()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
            app.launch()
        }
    }
}
