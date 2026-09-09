import XCTest
final class InteractionTests: XCTestCase {
    func bubble(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "message.\(id).bubble").firstMatch
    }
    func chip(_ app: XCUIApplication, _ id: String, _ emoji: String) -> XCUIElement {
        app.buttons["message.\(id).reaction.\(emoji)"]
    }
    func testExistingBubbleUpdatesWithoutAnotherMessage() {
        let app = XCUIApplication(); app.launchArguments = ["--updates-qa"]; app.launch()
        let outgoing = bubble(app, "outgoing")
        XCTAssertTrue(outgoing.waitForExistence(timeout: 5))
        app.buttons["Deliver"].tap()
        XCTAssertTrue(outgoing.staticTexts["Delivered"].waitForExistence(timeout: 3))
        app.buttons["Read"].tap()
        XCTAssertTrue(outgoing.staticTexts["Seen"].waitForExistence(timeout: 3))
        outgoing.press(forDuration: 0.7)
        let heart = app.buttons["React with ❤️"]
        XCTAssertTrue(heart.waitForExistence(timeout: 3)); heart.tap()
        XCTAssertTrue(chip(app, "outgoing", "❤️").waitForExistence(timeout: 3))
        app.buttons["Tombstone"].tap()
        XCTAssertTrue(outgoing.staticTexts["This message was deleted"].waitForExistence(timeout: 3))
        XCTAssertFalse(chip(app, "outgoing", "❤️").exists)
    }

    func testNativeReactionsAndActions() {
        let app = XCUIApplication(); app.launch()
        let outgoing = bubble(app, "outgoing")
        XCTAssertTrue(outgoing.waitForExistence(timeout: 5))
        XCTAssertLessThan(outgoing.frame.width, 300)
        XCTAssertLessThan(bubble(app, "quote").frame.height, 180)
        outgoing.press(forDuration: 0.7)
        let heart = app.buttons["React with ❤️"]
        XCTAssertTrue(heart.waitForExistence(timeout: 3)); heart.tap()
        XCTAssertTrue(chip(app, "outgoing", "❤️").waitForExistence(timeout: 3))
        chip(app, "outgoing", "❤️").tap()
        XCTAssertTrue(chip(app, "outgoing", "❤️").waitForNonExistence(timeout: 3))
        let incoming = bubble(app, "incoming")
        incoming.press(forDuration: 0.7)
        XCTAssertTrue(heart.waitForExistence(timeout: 3)); heart.tap()
        XCTAssertTrue(chip(app, "incoming", "❤️").label.contains("2 reactions"))
        chip(app, "incoming", "❤️").tap()
        XCTAssertTrue(chip(app, "incoming", "❤️").label.contains("1 reaction"))
        incoming.press(forDuration: 0.7)
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 3)); reply.tap()
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Reply incoming")
    }
    func testMoreReactionsAndEmojiSheet() {
        let app = XCUIApplication(); app.launch()
        bubble(app, "outgoing").press(forDuration: 0.7)
        let more = app.buttons["More reactions"]
        XCTAssertTrue(more.waitForExistence(timeout: 3)); more.tap()
        let fire = app.buttons["React with 🔥"]
        XCTAssertTrue(fire.waitForExistence(timeout: 3)); fire.tap()
        XCTAssertTrue(chip(app, "outgoing", "🔥").waitForExistence(timeout: 3))
        bubble(app, "outgoing").press(forDuration: 0.7)
        XCTAssertTrue(more.waitForExistence(timeout: 3)); more.tap()
        let all = app.buttons["All emoji…"]
        XCTAssertTrue(all.waitForExistence(timeout: 3)); all.tap()
        XCTAssertTrue(app.navigationBars["Choose emoji"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(bubble(app, "outgoing").exists)
    }
    func testReplyGestureAndDeletedMessageActions() {
        let app = XCUIApplication(); app.launch()
        let incoming = bubble(app, "incoming")
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        let start = incoming.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0)))
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Reply incoming")
        let outgoing = bubble(app, "outgoing")
        let outgoingStart = outgoing.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        outgoingStart.press(forDuration: 0.05, thenDragTo: outgoingStart.withOffset(CGVector(dx: -120, dy: 0)))
        XCTAssertEqual(app.staticTexts["lastAction"].label, "Reply outgoing")
        bubble(app, "deleted").press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["React with ❤️"].exists)
        XCTAssertFalse(app.buttons["Reply"].exists)
    }

}
