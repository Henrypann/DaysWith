import XCTest
import UIKit

/// Opt-in only. Edits synthetic, unsubmitted form values; never verifies or disconnects a connection.
@MainActor
final class CredentialLifecycleUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")
    private let identifier = "SyntheticLifecycleID"
    private let secret = "SyntheticLifecycleKey"
    private let token = "SyntheticLifecycleToken"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["JINBAO_CREDENTIAL_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit JINBAO_CREDENTIAL_UI_ACCEPTANCE=1 is required.")
        }
    }

    func testUnsubmittedCredentialsSurviveTwoAppSwitchesAndCancelClearsThem() throws {
        app.launchEnvironment["JINBAO_CREDENTIAL_UI_PROBE"] = "1"
        app.launch()
        try tap(app.buttons["tabMy"])
        try tap(app.buttons["openSettings"])
        guard app.buttons["settingsDisconnect"].waitForExistence(timeout: 5) else {
            throw XCTSkip("An existing connected session is required; this test does not configure one.")
        }
        try tap(app.buttons["editConnection"])
        try requireEmptyFields()
        try type(identifier, into: app.secureTextFields["secretID"])
        XCTAssertTrue(app.secureTextFields["secretKey"].label == "fixture-empty")
        XCTAssertTrue(app.secureTextFields["sessionToken"].label == "fixture-empty")
        try type(secret, into: app.secureTextFields["secretKey"])
        try assertSyntheticValueRetained("secretID", expected: identifier)
        XCTAssertTrue(app.secureTextFields["sessionToken"].label == "fixture-empty")
        try type(token, into: app.secureTextFields["sessionToken"])
        // Re-enter an existing secure field: UIKit must append rather than replace its value.
        let keyField = app.secureTextFields["secretKey"]
        try tap(keyField)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        keyField.typeText("X")
        XCTAssertTrue(keyField.label == "fixture-appended", "First edit must append to the exact synthetic secret.")
        keyField.typeText(XCUIKeyboardKey.delete.rawValue)
        try dismissKeyboard(keyField)
        try assertSyntheticValueRetained("secretKey", expected: secret)
        for cycle in 0..<2 {
            if cycle == 0 {
                try tap(app.secureTextFields["sessionToken"])
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            }
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "App must return to the foreground.")
            if app.keyboards.firstMatch.exists {
                try dismissKeyboard(app.secureTextFields["sessionToken"])
            }
            try assertSyntheticValueRetained("secretID", expected: identifier)
            try assertSyntheticValueRetained("secretKey", expected: secret)
            try assertSyntheticValueRetained("sessionToken", expected: token)
        }
        try tap(app.buttons["cancelCloudConfiguration"])
        XCTAssertTrue(app.buttons["editConnection"].waitForExistence(timeout: 5), "Cancel must return to Settings.")
        XCTAssertTrue(app.buttons["settingsDisconnect"].exists, "Cancel must preserve the existing connection.")
        try tap(app.buttons["editConnection"])
        try requireEmptyFields()
        try tap(app.buttons["cancelCloudConfiguration"])
        let result = XCTAttachment(string: "twoAppSwitchesRetainedInput=true; cancelClearedPendingInput=true; existingConnectionPreserved=true; verificationInvoked=false; disconnectInvoked=false")
        result.name = "Credential lifecycle result"
        result.lifetime = .keepAlways
        add(result)
    }

    private func requireEmptyFields() throws {
        for id in ["secretID", "secretKey", "sessionToken"] {
            let field = app.secureTextFields[id]
            try reveal(field)
            XCTAssertTrue(field.label == "fixture-empty", "The test-only probe must confirm an empty field before synthetic input.")
        }
    }

    private func assertSyntheticValueRetained(_ id: String, expected: String) throws {
        let field = app.secureTextFields[id]
        try reveal(field)
        let state = ["fixture-empty", "fixture-exact", "fixture-other"].contains(field.label) ? field.label : "probe-unavailable"
        XCTAssertTrue(state == "fixture-exact", "Exact synthetic probe: " + id + "=" + state)
        // The probe checks the full known fixture without exposing secure contents.
        // Also exercise the identifier reveal control and verify its rendered synthetic text.
        if id == "secretID" {
            try tap(app.buttons["显示密钥编号"])
            let revealed = app.textFields["secretID"]
            try reveal(revealed)
            XCTAssertTrue(revealed.value as? String == expected, "Revealed synthetic identifier must be unchanged.")
            try tap(app.buttons["隐藏密钥编号"])
        }
    }

    private func type(_ value: String, into field: XCUIElement) throws {
        try tap(field)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The tapped credential input must own the keyboard.")
        field.typeText(value)
        try dismissKeyboard(field)
        try assertSyntheticValueRetained(field.identifier, expected: value)
    }

    private func dismissKeyboard(_ field: XCUIElement) throws {
        let done = app.buttons["dismissCloudKeyboard"]
        if done.waitForExistence(timeout: 3), done.isHittable { done.tap() }
        else { field.typeText("\n") }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Connection keyboard must dismiss before navigation.")
    }

    private func tap(_ element: XCUIElement) throws { try reveal(element); element.tap() }

    private func reveal(_ element: XCUIElement) throws {
        for _ in 0..<10 {
            let bottomTab = app.buttons["tabMy"]
            let isBottomTab = element.identifier == "tabMy"
            let bottom = bottomTab.exists && !isBottomTab ? bottomTab.frame.minY - 12 : app.frame.maxY
            if element.exists && element.isHittable && app.frame.contains(element.frame) && element.frame.midY < bottom { return }
            let above = element.exists && element.frame.maxY > 0 && element.frame.midY < app.frame.midY
            if app.scrollViews.firstMatch.exists {
                if above { app.scrollViews.firstMatch.swipeDown() } else { app.scrollViews.firstMatch.swipeUp() }
            } else if app.collectionViews.firstMatch.exists {
                if above { app.collectionViews.firstMatch.swipeDown() } else { app.collectionViews.firstMatch.swipeUp() }
            } else {
                if above { app.swipeDown() } else { app.swipeUp() }
            }
        }
        XCTFail("Required credential lifecycle control is not reachable.")
        throw LifecycleUIFailure()
    }
}

private struct LifecycleUIFailure: Error {}
