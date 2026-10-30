import XCTest

/// Explicit physical-device setup and read-only handoff checks. Never submits credentials.
@MainActor
final class DeviceSetupSmokeUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")

    func testInitializeExplicitParent() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JINBAO_DEVICE_INITIAL_SETUP"] == "1",
              let parent = environment["JINBAO_DEVICE_PARENT"], ["dad", "mom"].contains(parent) else {
            throw XCTSkip("Explicit initial setup and parent selection are required.")
        }
        let networkMonitor = addUIInterruptionMonitor(withDescription: "Explicit app network permission") { alert in
            guard alert.label.contains("DaysWith"), alert.label.contains("使用无线数据") else { return false }
            for label in ["仅无线局域网", "无线局域网"] {
                let button = alert.buttons[label].firstMatch
                if button.exists && button.isHittable { button.tap(); return true }
            }
            XCTFail("App network permission needs an explicitly recognized allow action.")
            return true
        }
        defer { removeUIInterruptionMonitor(networkMonitor) }
        app.launch()
        let choice = app.buttons[parent == "dad" ? "chooseDad" : "chooseMom"]
        guard choice.waitForExistence(timeout: 10) else {
            throw XCTSkip("Device is already initialized; existing identity was preserved.")
        }
        choice.tap()
        let confirm = app.buttons["confirmParent"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let placeholder = app.buttons["placeholderConnect"]
        for _ in 0..<8 {
            if placeholder.exists && placeholder.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(placeholder.exists && placeholder.isHittable)
        placeholder.tap()
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 10))
    }

    func testNormalAppRestartAndConnectedSettings() throws {
        guard ProcessInfo.processInfo.environment["JINBAO_DEVICE_SMOKE"] == "1" else {
            throw XCTSkip("Explicit device smoke acceptance is required.")
        }
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 15))
            app.buttons["tabMy"].tap()
            let settings = app.buttons["openSettings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            XCTAssertTrue(app.buttons["settingsDisconnect"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["editConnection"].exists)
        }
        app.buttons["tabTimeline"].tap()
        let result = XCTAttachment(string: "twoProcessRestarts=true; connectedSettingsVisible=true; credentialEntryRequired=false; recordsEdited=false")
        result.name = "Normal installed app smoke result"
        result.lifetime = .keepAlways
        add(result)
    }
}
