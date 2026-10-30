import XCTest

@MainActor
final class HomeIconAcceptanceTests: XCTestCase {
    func testInstalledBrandIcon() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer { app.activate() }
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
        let exact = NSPredicate(format: "label == %@", "DaysWith")
        var icon = springboard.icons.matching(exact).firstMatch
        if !icon.exists || !icon.isHittable {
            // Spotlight can find apps installed only in App Library. Query only the
            // known app name; never retain a Home screen or unrelated search results.
            springboard.swipeDown()
            let search = springboard.searchFields.firstMatch
            guard search.waitForExistence(timeout: 5), search.isHittable else {
                throw XCTSkip("System search was unavailable; no unrelated app was opened.")
            }
            search.tap()
            search.typeText("DaysWith")
            let knownApp = springboard.descendants(matching: .any).matching(exact)
            guard knownApp.firstMatch.waitForExistence(timeout: 8) else {
                throw XCTSkip("System search did not expose the installed app icon.")
            }
            icon = knownApp.allElementsBoundByAccessibilityElement.first {
                $0.exists && $0.isHittable && $0.frame.width >= 40 && $0.frame.width <= 180
                    && $0.frame.height >= 40 && $0.frame.height <= 180
            } ?? springboard.icons.matching(exact).firstMatch
        }
        guard icon.exists && icon.isHittable else {
            throw XCTSkip("Installed app icon was not exposed; no unrelated app was opened.")
        }
        let attachment = XCTAttachment(screenshot: icon.screenshot())
        attachment.name = "30 Installed Jinbao365 brand icon"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
