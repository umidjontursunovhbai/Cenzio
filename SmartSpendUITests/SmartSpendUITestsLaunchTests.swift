//
//  SmartSpendUITestsLaunchTests.swift
//  SmartSpendUITests
//
//  Created by Umidjon Tursunov on 23/08/2025.
//

import XCTest

final class SmartSpendUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
