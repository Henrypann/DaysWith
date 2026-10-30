import XCTest
import UIKit

/// Run on a dedicated empty simulator. Existing installations are inspected without reset,
/// and cannot satisfy the first-run acceptance case.
@MainActor
final class SimulatorOnboardingTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")

    override func setUpWithError() throws { continueAfterFailure = false }

    func test01FreshIdentityPlaceholderAndFourTabs() throws {
        try requireSimulator()
        app.launch()
        try waitForKnownRoot()
        guard app.buttons["chooseDad"].exists, app.buttons["chooseMom"].exists else {
            let existing = app.buttons["tabTimeline"].exists
            attachText("onboardingExecuted=false; existingInitializedShell=\(existing); existingDataReset=false", "S00 first-run prerequisite")
            if existing { try verifyFourTabs() }
            throw SimulatorAcceptanceFailure("First-run onboarding was not executed: this simulator already has an identity or is in another state. Existing data and identity were preserved. Use a dedicated empty simulator.")
        }
        screenshot(app, "S01 fresh identity selection")
        try tap(app.buttons["chooseDad"])
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "爸爸")).firstMatch.exists)
        screenshot(confirmation, "S02 explicit Dad identity confirmation")
        try tap(confirmation.buttons["confirmParent"].firstMatch)
        let placeholder = app.buttons["placeholderConnect"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "Identity confirmation must enter the cloud-connection step.")
        XCTAssertFalse(app.buttons["tabTimeline"].exists)
        screenshot(app, "S03 mandatory connection with empty credentials")
        try tap(placeholder)
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 8))
        try verifyFourTabs()
        try openPlaceholderStatus()
        screenshot(app.descendants(matching: .any)["storagePlaceholder"].firstMatch, "S04 explicit local-only placeholder")
        try leaveCloudStatus()
        try tap(app.buttons["tabTimeline"])
        attachText("onboardingExecuted=true; identityConfirmed=dad; connection=placeholder; fourTabsExercised=true; existingDataReset=false", "S05 first-run result")
    }

    func test02AccessibilityXXXLFourTabsEditorSaveMonthAndSettings() throws {
        try requireSimulator()
        let originalArguments = app.launchArguments
        defer {
            app.terminate()
            app.launchArguments = originalArguments
            app.launch()
        }
        app.terminate()
        app.launchArguments = originalArguments + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        try waitForKnownRoot()
        guard app.buttons["tabTimeline"].exists else {
            throw SimulatorAcceptanceFailure("Complete test01 on the dedicated simulator first. Large-type acceptance did not choose or alter an existing identity.")
        }
        guard !app.textFields["draftTitle"].exists else { throw SimulatorAcceptanceFailure("An existing open draft was retained. No synthetic text was appended.") }
        try verifyFourTabs()
        try openPlaceholderStatus()
        try leaveCloudStatus()
        try tap(app.buttons["tabTimeline"])
        guard !app.buttons["timelineResumeDraft"].exists else { throw SimulatorAcceptanceFailure("A retained draft already exists. Large-type acceptance did not overwrite it.") }
        try tap(app.buttons["addMoment"])
        for id in ["addCameraMenuAction", "addPhotosMenuAction", "addNoteMenuAction"] {
            let action = app.buttons[id]
            try reveal(action)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertTrue(action.isHittable)
        }
        screenshot(app, "S06 XXXL four-tab add menu")
        try tap(app.buttons["addNoteMenuAction"])
        let title = "Jinbao simulator QA \(UUID().uuidString)"
        let note = "Synthetic accessibility acceptance. No personal content."
        let field = app.textFields["draftTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        guard field.value as? String == field.placeholderValue || field.value as? String == "" else { throw SimulatorAcceptanceFailure("The editor was not empty. The existing draft was retained.") }
        field.tap(); field.typeText(title)
        let body = app.descendants(matching: .any)["draftNote"].firstMatch
        try tap(body); body.typeText(note)
        let save = app.buttons["saveDraft"]
        XCTAssertTrue(save.isHittable, "Save must remain available while the writing keyboard is open at XXXL.")
        XCTAssertTrue(app.frame.contains(save.frame))
        let done = app.buttons["dismissComposerKeyboard"]
        if done.exists && done.isHittable { done.tap() }
        for identifier in ["draftTitle", "draftNote", "draftDate", "draftTime"] {
            let control = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(control.exists)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, "XXXL control must not overflow the leading screen edge: \(identifier)")
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, "XXXL control must not overflow the trailing screen edge: \(identifier)")
        }
        screenshot(app, "S07 XXXL synthetic editor with reachable save")
        try tap(app.navigationBars.buttons["关闭"])
        try tap(app.buttons["保留草稿并关闭"])
        XCTAssertTrue(app.buttons["timelineResumeDraft"].waitForExistence(timeout: 5))
        try tap(app.buttons["timelineResumeDraft"])
        XCTAssertEqual(app.textFields["draftTitle"].value as? String, title)
        XCTAssertEqual(app.descendants(matching: .any)["draftNote"].firstMatch.value as? String, note)
        try tap(app.buttons["saveDraft"])
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 5))
        try filterSyntheticTimeline(title)
        let record = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        try reveal(record)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "momentCard-"))
            .containing(.staticText, identifier: title)
        XCTAssertEqual(cards.count, 1)
        XCTAssertGreaterThan(cards.firstMatch.frame.width, app.frame.width * 0.75, "XXXL timeline must use one readable column.")
        let calendar = Calendar.current, now = Date()
        let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
        let heading = app.staticTexts["month-\(year)-\(month)"]
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(heading.label.contains("\(year)年"))
        screenshot(app, "S08 XXXL synthetic timeline and year-month heading")
        try tap(record)
        XCTAssertTrue(app.staticTexts[note].waitForExistence(timeout: 5))
        screenshot(app, "S09 XXXL saved synthetic detail")
        try tap(app.navigationBars.buttons["关闭"])
        try tap(app.buttons["tabMy"])
        try tap(app.buttons["openSettings"])
        XCTAssertTrue(app.navigationBars.staticTexts["设置"].waitForExistence(timeout: 5))
        let cellular = app.switches["allowCellularOriginals"]
        try reveal(cellular)
        XCTAssertTrue(cellular.isEnabled)
        screenshot(cellular, "S10 XXXL original-download policy reachable by scrolling")
        let trash = app.buttons["openTrash"]
        try tap(trash)
        XCTAssertTrue(app.navigationBars.staticTexts["回收站"].waitForExistence(timeout: 5))
        screenshot(app, "S11 XXXL trash entry opens its real screen")
        attachText("dynamicType=UICTContentSizeCategoryAccessibilityXXXL; override=launchArgumentsOnly; fourTabsExercised=true; syntheticRecordSaved=true; retainedDraftReopened=true; monthIncludesYear=true; settingsAndTrashReachable=true; globalAccessibilitySettingsChanged=false", "S12 XXXL result")
    }

    private func requireSimulator() throws {
        #if !targetEnvironment(simulator)
        throw SimulatorAcceptanceFailure("This suite is simulator-only. It did not operate the physical device.")
        #endif
    }
    private func waitForKnownRoot() throws {
        let root = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["chooseDad"].exists || self.app.buttons["tabTimeline"].exists || self.app.buttons["placeholderConnect"].exists || self.app.descendants(matching: .any)["archiveRecovery"].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [root], timeout: 12), .completed)
        guard !app.descendants(matching: .any)["archiveRecovery"].firstMatch.exists else { throw SimulatorAcceptanceFailure("The existing archive needs recovery. No reset or onboarding replacement was performed.") }
    }
    private func verifyFourTabs() throws {
        for (id, title) in [("tabTimeline", "时光"), ("tabAnniversaries", "纪念"), ("tabReview", "回顾"), ("tabMy", "我的")] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
            if XCTWaiter.wait(for: [ready], timeout: 8) != .completed {
                screenshot(app, "S tab hit-testing failure"); attachText(app.debugDescription, "S tab accessibility tree")
                throw SimulatorAcceptanceFailure("Tab did not become interactive: \(id)")
            }
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertTrue(app.frame.contains(button.frame))
            button.tap()
            if id == "tabTimeline" { XCTAssertTrue(app.staticTexts["jinbaoCurrentAge"].exists) }
            else { XCTAssertTrue(app.navigationBars.staticTexts[title].waitForExistence(timeout: 5)) }
        }
        try tap(app.buttons["tabTimeline"])
    }
    private func openPlaceholderStatus() throws {
        try tap(app.buttons["tabMy"])
        try tap(app.buttons["tabCloud"])
        guard app.descendants(matching: .any)["storagePlaceholder"].firstMatch.waitForExistence(timeout: 5), !app.staticTexts["storageVerified"].exists else {
            throw SimulatorAcceptanceFailure("The simulator is not using the required placeholder connection. Credentials were not changed and no synthetic record was created.")
        }
    }
    private func leaveCloudStatus() throws {
        let back = app.navigationBars.buttons["我的"]
        guard back.waitForExistence(timeout: 5) else { throw SimulatorAcceptanceFailure("The cloud status did not expose its My navigation return action.") }
        try tap(back)
    }
    private func filterSyntheticTimeline(_ text: String) throws {
        if !app.textFields["timelineSearchField"].exists { try tap(app.buttons["timelineSearchToggle"]) }
        let field = app.textFields["timelineSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if app.buttons["timelineSearchClear"].exists { app.buttons["timelineSearchClear"].tap() }
        field.tap(); field.typeText(text + "\n")
    }
    private func reveal(_ element: XCUIElement) throws {
        // Form rows outside the viewport may not exist in the accessibility tree yet.
        for _ in 0..<12 {
            if element.exists && element.isHittable && app.frame.contains(element.frame) { return }
            let above = element.exists && element.frame.maxY > 0 && element.frame.midY < app.frame.midY
            if app.tables.firstMatch.exists {
                if above { app.tables.firstMatch.swipeDown() } else { app.tables.firstMatch.swipeUp() }
            } else if app.collectionViews.firstMatch.exists {
                if above { app.collectionViews.firstMatch.swipeDown() } else { app.collectionViews.firstMatch.swipeUp() }
            } else if app.scrollViews.firstMatch.exists {
                if above { app.scrollViews.firstMatch.swipeDown() } else { app.scrollViews.firstMatch.swipeUp() }
            } else { app.swipeUp() }
        }
        guard element.exists, element.isHittable, app.frame.intersects(element.frame) else { screenshot(app, "S failure required control"); attachText(app.debugDescription, "S failure accessibility tree"); throw SimulatorAcceptanceFailure("A required control was not reachable at this text size: \(element.identifier)") }
    }
    private func tap(_ element: XCUIElement) throws { try reveal(element); element.tap() }
    private func screenshot(_ element: XCUIElement, _ name: String) { let attachment = XCTAttachment(screenshot: element.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
    private func attachText(_ text: String, _ name: String) { let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}

private struct SimulatorAcceptanceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
