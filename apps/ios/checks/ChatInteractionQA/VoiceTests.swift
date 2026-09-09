import XCTest
final class VoiceTests: XCTestCase {
    func testVoiceLayoutPlaybackAndScrubbing() {
        let app = XCUIApplication(); app.launchArguments = ["--voice-qa"]; app.launch()
        let play = app.buttons["voice.qa-incoming.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isEnabled)
        let slider = app.sliders["voice.qa-incoming.scrubber"]
        let time = app.staticTexts["voice.qa-incoming.time"]
        XCTAssertTrue(slider.exists)
        XCTAssertLessThanOrEqual(play.frame.maxX, slider.frame.minX + 1)
        XCTAssertGreaterThanOrEqual(time.frame.minX, slider.frame.maxX - 1)
        XCTAssertLessThanOrEqual(slider.frame.maxX, 386)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        play.tap()
        XCTAssertEqual(play.label, "Pause voice message")
        play.tap()
        XCTAssertEqual(play.label, "Play voice message")
        // The accessible value is spoken time, not a percentage. Exercise real thumb
        // tracking instead of XCTest’s percentage-string interpretation.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Ready", "Seeking must not reply")
        XCTAssertTrue(["0:09", "0:10", "0:11"].contains { time.label.contains($0) }, time.label)
        play.tap()
        let outgoing = app.buttons["voice.qa-outgoing.play"]
        outgoing.tap()
        XCTAssertEqual(outgoing.label, "Pause voice message")
        XCTAssertEqual(play.label, "Play voice message", "Only one note may play")
        outgoing.tap()
        XCTAssertEqual(outgoing.label, "Play voice message")
        let bubble = app.descendants(matching: .any).matching(identifier: "message.incoming.bubble").firstMatch
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0)))
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Reply incoming")
        let failed = app.buttons["voice.qa-missing.play"]
        XCTAssertEqual(failed.label, "Retry voice message")
        XCTAssertTrue(failed.isEnabled)
    }
    func testDeleteRecordingAndLargeText() {
        let app = XCUIApplication(); app.launchArguments = ["--voice-qa", "--large-text"]; app.launch()
        let play = app.buttons["voice.qa-incoming.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let slider = app.sliders["voice.qa-incoming.scrubber"]
        let time = app.staticTexts["voice.qa-incoming.time"]
        XCTAssertLessThanOrEqual(play.frame.maxX, slider.frame.minX + 1)
        XCTAssertGreaterThanOrEqual(time.frame.minX, slider.frame.maxX - 1)
        let delete = app.buttons["voice.recording.delete"]
        if !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        XCTAssertGreaterThanOrEqual(delete.frame.width, 44)
        delete.tap()
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Recording deleted")
    }
}
