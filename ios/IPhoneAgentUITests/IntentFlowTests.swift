import XCTest

final class IntentFlowTests: XCTestCase {
    @MainActor private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Keep the live release feed from presenting a firmware update over this unrelated UI flow.
        app.launchArguments = ["-mock", "-mockFirmware", "99.0.0", "-freshRecordings", "-onboarded", "YES", "-sharePrivacyAsked", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 10))
        if app.buttons["Discard Recording"].exists { app.buttons["Discard Recording"].tap() }
        return app
    }

    /// Opens the New Intent sheet; the button may still be settling right after launch (mock board connecting).
    @MainActor private func openNewIntent(_ app: XCUIApplication) {
        let record = app.buttons["Record me doing it"]
        for _ in 0..<3 where !record.exists {
            app.buttons["New intent"].tap()
            _ = record.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(record.exists)
    }

    @MainActor func testLastRunCreatesANewIntent() {
        let app = launch()
        openNewIntent(app)
        let saveRun = app.buttons["Save last run as intent"]
        XCTAssertTrue(saveRun.waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "New Intent"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        saveRun.tap()
        XCTAssertTrue(app.navigationBars["Save as Intent"].waitForExistence(timeout: 15))
        let name = "Saved run \(UUID().uuidString.prefix(6))"
        let field = app.textFields["intent.name"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        field.typeText(name)
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 15))
        for _ in 0..<5 where !app.staticTexts[name].isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(app.staticTexts[name].isHittable)
    }

    @MainActor func testRecordingCreatesDraftAndReopensDemonstration() {
        let app = launch()
        openNewIntent(app)
        app.buttons["Record me doing it"].tap()
        XCTAssertTrue(app.buttons["Stop Recording"].waitForExistence(timeout: 10))
        let frames = app.staticTexts["6 screens"]
        XCTAssertTrue(frames.waitForExistence(timeout: 20))
        app.buttons["Stop Recording"].tap()
        XCTAssertTrue(app.buttons["Save as Intent"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Recording draft"
        attachment.lifetime = .keepAlways
        add(attachment)
        // a recording is a run: its review can go on from where the person stopped
        XCTAssertTrue(app.buttons["Continue from Here"].exists, app.debugDescription)
        app.buttons["Save as Intent"].tap()
        XCTAssertTrue(app.navigationBars["Save as Intent"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["New intent"].waitForExistence(timeout: 15))
        let alarm = app.staticTexts["Daily 7 AM alarm"].firstMatch
        for _ in 0..<5 where !alarm.isHittable { app.swipeUp(velocity: .slow) }  // one fast swipe could overshoot it
        alarm.tap()
        let review = app.buttons["Review Demonstration"]
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 10))
        // below the script's steps, and clear of the floating Run bar: "hittable" under it still taps Run (2026-11-06)
        let run = app.buttons["Run"]
        for _ in 0..<6 where !review.isHittable || review.frame.maxY > run.frame.minY { app.swipeUp(velocity: .slow) }
        review.tap()
        let unsure = app.staticTexts["Unsure"].firstMatch
        // a tap while the last swipe is still settling can miss (CI, 2026-11-05): tap again once if still there
        if !unsure.waitForExistence(timeout: 15), review.exists, review.isHittable { review.tap() }
        XCTAssertTrue(unsure.waitForExistence(timeout: 30))
        app.buttons["Wrong"].tap()
        let note = app.descendants(matching: .any)["intent.step.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        note.tap()
        note.typeText("Tap the Add button")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Save Intent"].waitForExistence(timeout: 15))
        app.buttons["Save Intent"].tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Run"].waitForExistence(timeout: 15))
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
        openNewIntent(app)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "New Intent accessibility text"
        attachment.lifetime = .keepAlways
        add(attachment)
        let record = app.buttons["Record me doing it"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        let newIntent = app.buttons["New intent"]
        XCTAssertTrue(newIntent.waitForExistence(timeout: 15))
        XCTAssertTrue(newIntent.isEnabled)
        newIntent.tap()
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertTrue(record.isEnabled)
    }
    @MainActor func testInterruptedRecordingCanRecoverAfterRelaunch() {
        let app = launch()
        openNewIntent(app)
        app.buttons["Record me doing it"].tap()
        XCTAssertTrue(app.staticTexts["3 screens"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-freshRecordings" }  // this time the unfinished recording must stay
        app.launch()
        XCTAssertTrue(app.buttons["Create Draft Again"].waitForExistence(timeout: 30))  // a cold relaunch on CI is slow
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
        openNewIntent(app)
        let record = app.buttons["Record me doing it"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        XCTAssertFalse(record.isEnabled)
        XCTAssertTrue(app.buttons["Connect the board"].exists)
    }

}
/// TestFlight 1.0.3 on iOS 27.3: activating the model search in its sheet hit a UIKit assertion
/// (-[UISearchController _setInlineSearchAccessoryEnabled:]). The sheet's search must open and filter.
final class ModelSearchTests: XCTestCase {
    @MainActor func testModelSearchActivatesInSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-mockFirmware", "99.0.0", "-onboarded", "YES", "-sharePrivacyAsked", "YES",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model'")).firstMatch.tap()
        let llm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Large Language Model'")).firstMatch
        if llm.waitForExistence(timeout: 3) { llm.tap() }
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model,' OR label BEGINSWITH 'Model '"))
            .firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        picker.tap()
        XCTAssertTrue(app.navigationBars["Choose Model"].waitForExistence(timeout: 5))
        let field = app.searchFields["Search models"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zz-no-such-model")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'zz-no-such-model'")).firstMatch
            .waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
