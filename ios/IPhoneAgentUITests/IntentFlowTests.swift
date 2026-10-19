import XCTest

final class IntentFlowTests: XCTestCase {
    @MainActor private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 10))
        if app.buttons["Discard Recording"].exists { app.buttons["Discard Recording"].tap() }
        return app
    }

    @MainActor func testLastRunCreatesANewIntent() {
        let app = launch()
        app.buttons["New intent"].tap()
        let saveRun = app.buttons.containing(.staticText, identifier: "Save last run as intent").firstMatch
        XCTAssertTrue(saveRun.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "New Intent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        saveRun.tap()
        XCTAssertTrue(app.navigationBars["Save as Intent"].waitForExistence(timeout: 5))
        let name = "Saved run \(UUID().uuidString.prefix(6))"
        let field = app.textFields["intent.name"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        field.typeText(name)
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.staticTexts[name].isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.staticTexts[name].isHittable)
    }

    @MainActor func testRecordingCreatesDraftAndReopensDemonstration() {
        let app = launch()
        app.buttons["New intent"].tap()
        app.buttons.containing(.staticText, identifier: "Record me doing it").firstMatch.tap()
        XCTAssertTrue(app.buttons["Stop Recording"].waitForExistence(timeout: 10))
        let frames = app.staticTexts["6 screens"]
        XCTAssertTrue(frames.waitForExistence(timeout: 20))
        app.buttons["Stop Recording"].tap()
        XCTAssertTrue(app.buttons["Save as Intent"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recording draft"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Save as Intent"].tap()
        XCTAssertTrue(app.navigationBars["Save as Intent"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.staticTexts["Daily 7 AM alarm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Review Demonstration"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["Review Demonstration"].tap()
        XCTAssertTrue(app.staticTexts["Unsure"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Fix"].tap()
        let note = app.descendants(matching: .any)["intent.step.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Tap the Add button")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Save Intent"].waitForExistence(timeout: 5))
        app.buttons["Save Intent"].tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 5))
        app.buttons["Run"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Skip Step"].waitForExistence(timeout: 40))
        app.buttons["Skip Step"].tap()
        XCTAssertTrue(app.buttons["Save Intent"].waitForExistence(timeout: 50))
        let completed = XCTAttachment(screenshot: app.screenshot())
        completed.name = "Saved intent execution completed"
        completed.lifetime = .keepAlways
        add(completed)
    }

    @MainActor func testCancelAllowsAnotherRecordingAndLargeTextSheet() {
        let app = launch(largeText: true)
        app.buttons["New intent"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "New Intent accessibility text"
        attachment.lifetime = .keepAlways
        add(attachment)
        let record = app.buttons.containing(.staticText, identifier: "Record me doing it").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        let newIntent = app.buttons["New intent"]
        XCTAssertTrue(newIntent.waitForExistence(timeout: 5))
        XCTAssertTrue(newIntent.isEnabled)
        newIntent.tap()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(record.isEnabled)
    }
    @MainActor func testInterruptedRecordingCanRecoverAfterRelaunch() {
        let app = launch()
        app.buttons["New intent"].tap()
        app.buttons.containing(.staticText, identifier: "Record me doing it").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["3 screens"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Create Draft Again"].waitForExistence(timeout: 5))
        app.buttons["Create Draft Again"].tap()
        XCTAssertTrue(app.buttons["Save as Intent"].waitForExistence(timeout: 10))
    }

    @MainActor func testMissingBoardExplainsWhyRecordingIsDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demoData", "NO", "-onboarded", "YES", "-sharePrivacyAsked", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 10))
        if app.buttons["Discard Recording"].exists { app.buttons["Discard Recording"].tap() }
        app.buttons["New intent"].tap()
        let record = app.buttons.containing(.staticText, identifier: "Record me doing it").firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertFalse(record.isEnabled)
        XCTAssertTrue(app.buttons["Connect the board"].exists)
    }

}
