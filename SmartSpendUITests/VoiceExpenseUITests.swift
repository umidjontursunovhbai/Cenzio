import XCTest

final class VoiceExpenseUITests: XCTestCase {
    @MainActor
    func testTopVoiceOverlayDoesNotMoveDashboard() {
        verifyVoiceOverlay(state: "recording")
    }

    @MainActor
    func testPreparingVoiceOverlayIsCompactAndHidesTranscript() {
        verifyVoiceOverlay(state: "processing")
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
        app.launch()
        let overview = app.otherElements["dashboard.overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        let initialY = overview.frame.minY
        app.terminate()
        app.launchEnvironment["SMARTSPEND_VOICE_OVERLAY_TEST"] = state
        app.launch()
        let close = app.buttons["voice.overlay-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let current = app.otherElements["dashboard.overview"].firstMatch
        XCTAssertTrue(current.exists)
        XCTAssertEqual(current.frame.minY, initialY, accuracy: 1, "The overlay must not shift dashboard content.")
        XCTAssertFalse(app.staticTexts["voice.transcript"].exists, "STT is an internal handoff, not part of the voice HUD.")
        XCTAssertFalse(app.staticTexts["VOICE_UI_TEST_PRIVATE_TRANSCRIPT"].exists)
        XCTAssertEqual(app.buttons["voice.overlay-stop"].exists, state == "recording")
        XCTAssertEqual(app.buttons["voice.allow-ai"].exists, state == "consent")
        XCTAssertEqual(app.buttons["voice.retry"].exists, state == "error")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Voice \(state) — compact HUD, private transcript, dashboard unchanged"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(close.frame.height, 52)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        if state == "recording" || state == "processing" {
            let overlay = app.otherElements["voice.overlay"].firstMatch
            XCTAssertTrue(overlay.exists)
            XCTAssertLessThanOrEqual(overlay.frame.height, 90, "Active voice states should be a compact HUD, not a transcript card.")
            XCTAssertLessThanOrEqual(overlay.frame.width, 350)
        }
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
        app.launch()
        let add = app.buttons["dashboard.add-expense"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        // Holding without the deliberate downward pull must not record or open
        // the manual form, and must not poison the next ordinary tap.
        add.press(forDuration: 0.5)
        XCTAssertFalse(app.buttons["voice.record"].exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
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
