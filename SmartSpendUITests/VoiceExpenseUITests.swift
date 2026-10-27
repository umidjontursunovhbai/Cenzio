import XCTest

final class VoiceExpenseUITests: XCTestCase {
    @MainActor
    func testRecordingShowsNoTopOverlay() {
        verifyNoVoiceOverlay(state: "recording")
    }

    @MainActor
    func testPreparingShowsNoTopOverlay() {
        verifyNoVoiceOverlay(state: "processing")
    }

    /// Recording and preparing show on the entry bar only; the top card is for consent and errors.
    @MainActor
    private func verifyNoVoiceOverlay(state: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_VOICE_OVERLAY_TEST"] = state
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        XCTAssertTrue(app.otherElements["dashboard.overview"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["voice.overlay"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["VOICE_UI_TEST_PRIVATE_TRANSCRIPT"].exists)
        app.terminate()
    }

    @MainActor
    func testVoiceConsentKeepsTranscriptPrivateAndDashboardInPlace() {
        verifyVoiceOverlay(state: "consent")
    }

    @MainActor
    func testVoiceErrorOffersRetryWithoutExposingTranscript() {
        verifyVoiceOverlay(state: "error")
    }

    @MainActor
    private func verifyVoiceOverlay(state: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        let overview = app.otherElements["dashboard.overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        let initialY = overview.frame.minY
        app.terminate()
        app.launchEnvironment["SMARTSPEND_VOICE_OVERLAY_TEST"] = state
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        let close = app.buttons["voice.overlay-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let current = app.otherElements["dashboard.overview"].firstMatch
        XCTAssertTrue(current.exists)
        XCTAssertEqual(current.frame.minY, initialY, accuracy: 1, "The overlay must not shift dashboard content.")
        XCTAssertFalse(app.staticTexts["voice.transcript"].exists, "STT is an internal handoff, not part of the voice HUD.")
        XCTAssertFalse(app.staticTexts["VOICE_UI_TEST_PRIVATE_TRANSCRIPT"].exists)
        XCTAssertFalse(app.buttons["voice.overlay-stop"].exists)
        XCTAssertEqual(app.buttons["voice.allow-ai"].exists, state == "consent")
        XCTAssertEqual(app.buttons["voice.retry"].exists, state == "error")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Voice \(state) — compact HUD, private transcript, dashboard unchanged"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(close.frame.height, 52)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertFalse(app.buttons["voice.overlay-close"].exists)
        XCTAssertEqual(current.frame.minY, initialY, accuracy: 1)
        XCTAssertTrue(app.buttons["dashboard.add-expense"].isEnabled)
        app.terminate()
    }

    @MainActor
    func testLiveGPTPreparesExpenseWithoutSaving() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_GPT_UI_TEST"] = "1"
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "GPT-6 Luna")).firstMatch.exists)
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)
        let allow = app.buttons["voice.allow-ai"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let title = app.descendants(matching: .any)["expense.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 35), "Authenticated GPT request must reach the actual expense preview.")
        XCTAssertTrue((title.value as? String ?? "").lowercased().contains("bus"))
        let amount = app.textFields["expense.amount"]
        XCTAssertEqual((amount.value as? String ?? "").filter(\.isNumber), "2500")
        // No Save tap, no microphone capture, and no real ledger writes.
        app.terminate()
    }

    @MainActor
    func testOrdinaryTapOpensOnlyManualExpenseForm() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["SMARTSPEND_UI_TEST_SKIP_SIGNIN"] = "1"
        app.launch()
        let add = app.buttons["dashboard.add-expense"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        // Voice entry has its own visible button; plus only opens the form.
        XCTAssertTrue(app.buttons["dashboard.voice-expense"].exists)
        add.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["expense.voice-entry"].exists)
        XCTAssertFalse(app.buttons["voice.record"].exists)
        XCTAssertFalse(app.textViews["voice.transcript"].exists)
        // No microphone, AI request or synthetic expense save on the owner's phone.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Ordinary tap — manual expense form only"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }
}
