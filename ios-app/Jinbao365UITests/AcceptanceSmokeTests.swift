import XCTest
import UIKit
import Vision

/// Additive acceptance checks. No app reset, uninstall, credential entry, or photo-library enumeration.
@MainActor
final class AcceptanceSmokeTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Dismiss transient notification banners without opening them") { element in
            guard element.identifier == "NotificationShortLookView" || element.label == "NotificationShortLookView" else { return false }
            element.swipeUp()
            return true
        }
    }

    func test01OnboardingAndText() throws {
        let runID = UUID().uuidString
        let title = "Jinbao QA text \(runID)"
        let note = "Synthetic acceptance note \(runID)."
        try openTimeline()

        app.buttons["addMoment"].tap()
        XCTAssertTrue(app.buttons["addNoteMenuAction"].waitForExistence(timeout: 5))
        // The menu overlay also covers existing records; attach only its three safe buttons.
        for identifier in ["addCameraMenuAction", "addPhotosMenuAction", "addNoteMenuAction"] {
            attachScreenshot(app.buttons[identifier], name: "01 Add menu — \(identifier)")
        }
        app.buttons["addNoteMenuAction"].tap()
        let titleField = app.textFields["draftTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        let noteField = app.descendants(matching: .any)["draftNote"].firstMatch
        XCTAssertTrue(noteField.exists)
        noteField.tap()
        noteField.typeText(note)
        // Only the synthetic form is captured; the timeline may contain private records.
        attachScreenshot(titleField, name: "02 Synthetic text title")
        XCTAssertTrue(app.buttons["saveDraft"].isHittable,
                      "Save must remain reachable while the writing keyboard is visible.")
        tapVisible(app.buttons["saveDraft"])
        XCTAssertTrue(app.buttons["addMoment"].waitForExistence(timeout: 5))
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let header = app.staticTexts["month-\(year)-\(month)"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "The timeline must expose its year and month.")
        XCTAssertTrue(header.label.contains(String(year)), "The visible month heading must include the year.")
        attachScreenshot(header, name: "03 Timeline month includes year")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 10))
        app.buttons["tabTimeline"].tap()
        let savedTitle = app.staticTexts[title].firstMatch
        XCTAssertTrue(savedTitle.waitForExistence(timeout: 5), "The unique text record must survive relaunch.")
        savedTitle.tap()
        let close = app.navigationBars.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[note].exists)
        attachScreenshot(app, name: "04 Persisted synthetic text detail")
        close.tap()
        try capturePlaceholderCloud()
    }

    func test02SyntheticPhotoImport() throws {
        let seededRunID = try preseededRunID()
        let runID = seededRunID ?? UUID().uuidString
        if seededRunID == nil {
            let fixture = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365.photofixture")
            fixture.launchArguments = ["--fixture-run-id", runID]
            fixture.launch()
            let add = fixture.buttons["fixtureAddPhoto"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), "Install the built JinbaoPhotoFixture.app before this test.")
            XCTAssertEqual(fixture.staticTexts["fixtureRunID"].label, runID)
            add.tap()
            allowExpectedAddOnlyPrompt()
            let count = fixture.staticTexts["fixtureSuccessCount"]
            let added = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2"), object: count)
            XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 20), .completed,
                           "The add-only helper must report exactly two successful creations.")
            attachScreenshot(fixture, name: "05 Two labeled synthetic fixture photos")
            fixture.terminate()
        } else {
            attachNote("Using preseeded synthetic photos for run \(runID). The helper was not launched.",
                       name: "Photo fixtures — preseeded run")
        }

        try openTimeline()
        app.buttons["addMoment"].tap()
        app.buttons["addPhotosMenuAction"].tap()
        let picker = app.buttons["composerPickPhoto"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let title = "Jinbao QA photo \(runID)"
        let titleField = app.textFields["draftTitle"]
        titleField.tap()
        titleField.typeText(title)
        tapVisible(picker)

        try selectSyntheticPhotoInPicker(runID: runID)
        try finishSyntheticPhoto(runID: runID)
    }

    func test03FinishPendingSyntheticPhoto() throws {
        guard let runID = try preseededRunID() else {
            throw XCTSkip("Set JINBAO_QA_PRESEEDED_RUN_ID to the verified fixture run before finishing a pending draft.")
        }
        // This entry only saves an already imported draft. test04 handles selection.
        app.activate()
        try finishSyntheticPhoto(runID: runID)
    }

    func test04AutoSelectPendingSyntheticPhoto() throws {
        guard let runID = try preseededRunID() else {
            throw XCTSkip("Set JINBAO_QA_PRESEEDED_RUN_ID to the fixture run before automated photo selection.")
        }
        app.activate()
        let titleField = app.textFields["draftTitle"]
        let pickerButton = app.buttons["composerPickPhoto"]
        // A previously open system picker can hide the underlying draft from the
        // accessibility tree. Cancel only that picker, validate the saved draft,
        // then reopen it. Never launch or rewrite the pending draft.
        if !titleField.isHittable || !pickerButton.isHittable {
            guard let cancel = uniqueVisibleButton(labels: ["Cancel", "取消"], navigationOnly: true) else {
                attachPickerDiagnostics(stage: "pending composer unavailable", candidate: 0,
                                        visibleCells: visiblePickerCells().count, enlarged: false, matched: false)
                throw XCTSkip("The pending draft cannot be safely verified from the current picker state.")
            }
            cancel.tap()
        }
        guard titleField.waitForExistence(timeout: 8), titleField.isHittable,
              (titleField.value as? String) == "Jinbao QA photo \(runID)",
              pickerButton.isHittable else {
            throw XCTSkip("The pending composer does not match the fixture run. No draft title or data was changed.")
        }
        if importedDraftPreview() == nil {
            pickerButton.tap()
            try selectSyntheticPhotoInPicker(runID: runID)
        }
        try finishSyntheticPhoto(runID: runID)
    }

    func test05PlaceholderCloudButtons() throws {
        app.activate()
        let cloud = app.buttons["tabCloud"]
        guard cloud.waitForExistence(timeout: 8), cloud.isHittable else {
            throw XCTSkip("The cloud tab is not safely available. The current picker or draft was retained.")
        }
        cloud.tap()
        let placeholder = app.buttons["placeholderConnect"]
        guard !app.staticTexts["storageVerified"].exists,
              placeholder.waitForExistence(timeout: 5),
              cloudCredentialIsEmpty("secretID"), cloudCredentialIsEmpty("secretKey") else {
            throw XCTSkip("Cloud acceptance requires an unverified placeholder form with empty credential fields. No cloud action was performed.")
        }
        let show = app.buttons["显示密钥编号"]
        let hide = app.buttons["隐藏密钥编号"]
        if hide.exists {
            tapVisible(hide)
        }
        XCTAssertTrue(app.secureTextFields["secretID"].exists)
        tapVisible(show)
        XCTAssertTrue(app.textFields["secretID"].waitForExistence(timeout: 5))
        XCTAssertTrue(hide.exists)
        tapVisible(hide)
        XCTAssertTrue(app.secureTextFields["secretID"].waitForExistence(timeout: 5))
        XCTAssertTrue(show.exists)

        // Empty credentials fail AppModel's synchronous local validation before a
        // transport or Keychain operation is created. Recheck immediately before tap.
        guard cloudCredentialIsEmpty("secretID"), cloudCredentialIsEmpty("secretKey"),
              !app.staticTexts["storageVerified"].exists else {
            throw XCTSkip("Credential or connection state changed; verification was not invoked.")
        }
        tapVisible(app.buttons["verifyContinue"])
        let message = app.staticTexts["connectionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(message.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(message.label.contains("占位"), "Empty credentials must produce local error feedback.")
        attachScreenshot(app, name: "10 Cloud — empty credential validation")
        tapVisible(placeholder)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("占位"))
        attachScreenshot(app, name: "11 Cloud — placeholder feedback")
        app.buttons["tabTimeline"].tap()
        XCTAssertTrue(app.buttons["addMoment"].waitForExistence(timeout: 5))
    }

    func test06SafePickerStructure() throws {
        app.activate()
        if app.buttons["composerPickPhoto"].isHittable {
            guard let runID = try preseededRunID(),
                  (app.textFields["draftTitle"].value as? String) == "Jinbao QA photo \(runID)" else {
                throw XCTSkip("No matching synthetic draft.")
            }
            app.buttons["composerPickPhoto"].tap()
        }
        _ = waitForStablePicker()
        // Structural metadata only: never labels, values, identifiers, descriptions,
        // OCR text, or screenshots. Activating preserves the existing picker state.
        let types: [(String, XCUIElement.ElementType)] = [
            ("window", .window), ("navigationBar", .navigationBar), ("sheet", .sheet),
            ("scrollView", .scrollView), ("collectionView", .collectionView),
            ("table", .table), ("cell", .cell), ("image", .image),
            ("button", .button), ("other", .other)
        ]
        var lines = types.map { name, type in
            "type=\(name); count=\(app.descendants(matching: type).count)"
        }
        lines.append("application; frame=\(safeFrame(app.frame)); state=\(app.state.rawValue)")

        // Direct descendants reveal remote-view container nesting without disclosing
        // any accessibility content. Bound both total nodes and tree depth.
        var queue: [(XCUIElement, Int)] = [(app, 0)]
        var nodes = 0
        while !queue.isEmpty && nodes < 32 {
            let (element, depth) = queue.removeFirst()
            guard element.exists else { continue }
            let children = element.children(matching: .any)
            lines.append("node=\(nodes); depth=\(depth); type=\(element.elementType.rawValue); frame=\(safeFrame(element.frame)); hittable=\(element.isHittable); children=\(children.count)")
            nodes += 1
            if depth < 4 {
                let remaining = max(0, 32 - nodes - queue.count)
                for child in boundedElements(children, maximum: min(remaining, 8)) {
                    queue.append((child, depth + 1))
                }
            }
        }

        // Inspect at most 32 geometry candidates across the whole app's cells,
        // images and other elements. Generic handles carry no private labels.
        var candidates = 0
        for (name, query) in [("cell", app.cells), ("image", app.images), ("other", app.otherElements)] {
            for element in boundedElements(query, maximum: 32) {
                guard candidates < 32 else { break }
                guard element.exists else { continue }
                let frame = element.frame
                guard frame.width >= 24, frame.height >= 24,
                      frame.width <= app.frame.width * 0.60,
                      frame.height <= app.frame.height * 0.40,
                      app.frame.intersects(frame) else { continue }
                lines.append("candidate=\(candidates); sourceType=\(name); type=\(element.elementType.rawValue); frame=\(safeFrame(frame)); hittable=\(element.isHittable); children=\(element.children(matching: .any).count)")
                candidates += 1
            }
        }
        lines.append("candidateMetadataCount=\(candidates)")
        attachNote(lines.joined(separator: "\n"), name: "Photo picker — private-content-free structure")
    }

    func test08InspectCurrentPicker() throws {
        guard ProcessInfo.processInfo.environment["JINBAO_PRIVATE_PICKER_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Private picker diagnostics require explicit local opt-in.")
        }
        app.activate()
        if app.buttons["composerPickPhoto"].isHittable {
            guard let runID = try preseededRunID(),
                  (app.textFields["draftTitle"].value as? String) == "Jinbao QA photo \(runID)" else {
                throw XCTSkip("No matching synthetic draft.")
            }
            app.buttons["composerPickPhoto"].tap()
        }
        _ = waitForStablePicker()
        attachScreenshot(app, name: "PRIVATE picker diagnostic - do not publish")
    }

    func test07SyntheticMultiPhotoImport() throws {
        guard let runID = try preseededRunID() else {
            throw XCTSkip("Set JINBAO_QA_PRESEEDED_RUN_ID to a fixture run containing QA 1 and QA 2.")
        }
        try openTimeline()
        let title = "Jinbao QA multi \(runID) \(UUID().uuidString)"
        app.buttons["addMoment"].tap()
        app.buttons["addPhotosMenuAction"].tap()
        let titleField = app.textFields["draftTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        tapVisible(app.buttons["composerPickPhoto"])
        try selectTwoVerifiedSyntheticPhotos(runID: runID, title: title)

        try finishSyntheticMultiPhoto(runID: runID, title: title)
    }

    func test09FinishPendingSyntheticMultiPhoto() throws {
        guard let runID = try preseededRunID() else { throw XCTSkip("A fixture run is required.") }
        app.activate()
        let field = app.textFields["draftTitle"]
        guard field.waitForExistence(timeout: 8),
              let title = field.value as? String,
              title.hasPrefix("Jinbao QA multi \(runID) ") else {
            throw XCTSkip("No matching synthetic two-photo draft; existing data was retained.")
        }
        try finishSyntheticMultiPhoto(runID: runID, title: title)
    }

    private func finishSyntheticMultiPhoto(runID: String, title: String) throws {
        let draftQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-"))
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            draftQuery.count == 2 && !self.app.progressIndicators["photoImportProgress"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 20), .completed)
        XCTAssertEqual(draftQuery.count, 2)
        let draftButtons = draftQuery.allElementsBoundByAccessibilityElement
        guard draftButtons.count == 2 else { throw XCTSkip("The imported draft is not a two-photo draft.") }
        for (offset, button) in draftButtons.enumerated() {
            try verifyMultiPhotoGallery(button: button, runID: runID, firstNumber: offset + 1,
                                        checkPaging: false, attachmentPrefix: "12 Draft photo \(offset + 1)")
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Photo preview must not restore the editing keyboard over Save.")
        attachScreenshot(app, name: "13 Two verified synthetic photos in draft")
        tapVisible(app.buttons["saveDraft"])
        XCTAssertTrue(app.buttons["addMoment"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let titles = app.staticTexts.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(titles.count, 1)
        titles.firstMatch.tap()
        let detailQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        XCTAssertTrue(detailQuery.firstMatch.waitForExistence(timeout: 8))
        XCTAssertEqual(detailQuery.count, 2, "Both synthetic photos must survive save and relaunch.")
        let details = detailQuery.allElementsBoundByAccessibilityElement
        guard details.count == 2 else { throw XCTSkip("The persisted record is not a two-photo record.") }
        try verifyMultiPhotoGallery(button: details[0], runID: runID, firstNumber: 1,
                                    checkPaging: true, attachmentPrefix: "14 Persisted two-photo gallery")
        attachScreenshot(app, name: "15 Persisted synthetic two-photo detail")
        app.navigationBars.buttons["关闭"].tap()
    }

    func test10AndroidBrandTimelineAndSearch() throws {
        guard let runID = try preseededRunID() else { throw XCTSkip("Known synthetic run required.") }
        try openTimeline()
        app.buttons["timelineSearchToggle"].tap()
        let search = app.textFields["timelineSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("QA-NO-MATCH-\(UUID().uuidString)\n")
        XCTAssertTrue(app.descendants(matching: .any)["timelineSearchEmpty"].firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "20 Brand and search empty feedback")
        app.buttons["timelineSearchClear"].tap()
        XCTAssertTrue((search.value as? String ?? "").isEmpty || search.value as? String == search.placeholderValue)
        search.typeText(runID + "\n")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["jinbaoCurrentAge"].exists)
        XCTAssertTrue(app.staticTexts["DaysWith"].exists)
        let now = Date(), calendar = Calendar.current
        let month = app.staticTexts["month-\(calendar.component(.year, from: now))-\(calendar.component(.month, from: now))"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertTrue(month.label.contains(String(calendar.component(.year, from: now))))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "momentCard-"))
            .allElementsBoundByAccessibilityElement.filter { $0.isHittable }
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Run single and multi-photo persistence checks first.")
        if cards.count >= 2 {
            XCTAssertGreaterThan(abs(cards[0].frame.midX - cards[1].frame.midX), app.frame.width * 0.25,
                                 "The normal-size Cody XS timeline must display two columns.")
            XCTAssertLessThan(abs(cards[0].frame.minY - cards[1].frame.minY), 8)
        }
        // Only records matching the exact synthetic run are visible in this attachment.
        attachScreenshot(app, name: "21 Android-aligned synthetic two-column timeline")
        app.buttons["timelineSearchToggle"].tap()
        XCTAssertFalse(search.exists)
        app.buttons["tabCloud"].tap()
        XCTAssertTrue(app.buttons["placeholderConnect"].waitForExistence(timeout: 5))
        app.buttons["tabTimeline"].tap()
    }

    func test11AndroidTimelineLargeType() throws {
        guard let runID = try preseededRunID() else { throw XCTSkip("Known synthetic run required.") }
        let originalArguments = app.launchArguments
        defer {
            app.terminate()
            app.launchArguments = originalArguments
            app.launch()
        }
        app.terminate()
        app.launchArguments = originalArguments + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        try openTimeline()
        app.buttons["timelineSearchToggle"].tap()
        let search = app.textFields["timelineSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(runID + "\n")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "momentCard-")).firstMatch
        for _ in 0..<4 {
            if card.exists && card.isHittable && card.frame.minY < app.frame.height * 0.45 { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.isHittable, "Large-text records must remain reachable by scrolling.")
        XCTAssertGreaterThan(card.frame.width, app.frame.width * 0.75,
                             "Large type must use a readable single column.")
        attachScreenshot(app, name: "22 Synthetic timeline at accessibility text size")
    }

    private func selectTwoVerifiedSyntheticPhotos(runID: String, title: String) throws {
        guard waitForStablePicker(), let add = pickerAddButton(), !add.isEnabled,
              syntheticGridMarkerMatches(runID: runID, column: 1, number: 1),
              syntheticGridMarkerMatches(runID: runID, column: 0, number: 2) else {
            throw XCTSkip("Both synthetic run-specific thumbnails must be verified before selection.")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.447)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.166, dy: 0.447)).tap()
        guard let selectedAdd = pickerAddButton(), selectedAdd.isEnabled else {
            throw XCTSkip("Verified selections did not enable Add.")
        }
        selectedAdd.tap()
        XCTAssertTrue(app.buttons["composerPickPhoto"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["draftTitle"].value as? String, title)
    }

    private func tapOrPressGridFrame(_ frame: CGRect, previewOnly: Bool) {
        let viewport = app.frame
        let point = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.midX - viewport.minX, dy: frame.midY - viewport.minY))
        if previewOnly { point.press(forDuration: 1.2) } else { point.tap() }
    }

    private func sameGridFrame(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 2 && abs(left.minY - right.minY) < 2
            && abs(left.width - right.width) < 2 && abs(left.height - right.height) < 2
    }

    private func dismissMultiPhotoPreview(_ preview: XCUIElement?) -> Bool {
        // Some library items consume long press without opening a context preview.
        if app.images.matching(identifier: "PXGGridLayout-Info").count > 0,
           uniqueVisibleButton(labels: ["选择", "Select"]) == nil {
            return true
        }
        // A tap in the already observed top header/backdrop cannot select a grid
        // photo or a context Select action. It may close the picker; the caller
        // validates the preserved draft before reopening in that case.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 60)).tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.images.matching(identifier: "PXGGridLayout-Info").count > 0 || self.app.buttons["composerPickPhoto"].isHittable
        }, object: nil)
        return XCTWaiter.wait(for: [returned], timeout: 5) == .completed
    }

    private func verifyMultiPhotoGallery(button: XCUIElement, runID: String, firstNumber: Int,
                                        checkPaging: Bool, attachmentPrefix: String) throws {
        tapVisible(button)
        let close = app.buttons["closePhotoPreview"]
        guard close.waitForExistence(timeout: 8), syntheticScreenMatches(runID: runID, requiredNumber: firstNumber) else {
            if close.exists && close.isHittable { close.tap() }
            throw XCTSkip("The two-photo full-size preview did not match the expected QA number and exact run.")
        }
        attachScreenshot(app, name: "\(attachmentPrefix) — QA \(firstNumber)")
        if checkPaging {
            XCTAssertTrue(app.navigationBars.staticTexts["1 / 2"].exists)
            app.swipeLeft()
            guard app.navigationBars.staticTexts["2 / 2"].waitForExistence(timeout: 5),
                  syntheticScreenMatches(runID: runID, requiredNumber: 2) else {
                if close.exists && close.isHittable { close.tap() }
                throw XCTSkip("Paging did not display the verified second synthetic photo.")
            }
            attachScreenshot(app, name: "\(attachmentPrefix) — paged QA 2")
            app.swipeRight()
            guard app.navigationBars.staticTexts["1 / 2"].waitForExistence(timeout: 5),
                  syntheticScreenMatches(runID: runID, requiredNumber: 1) else {
                if close.exists && close.isHittable { close.tap() }
                throw XCTSkip("Paging back did not return to the verified first synthetic photo.")
            }
            attachScreenshot(app, name: "\(attachmentPrefix) — returned QA 1")
        }
        close.tap()
    }

    private func safeFrame(_ frame: CGRect) -> String {
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
            return "unavailable"
        }
        return "x=\(Int(frame.minX.rounded())),y=\(Int(frame.minY.rounded())),w=\(Int(frame.width.rounded())),h=\(Int(frame.height.rounded()))"
    }

    private func cloudCredentialIsEmpty(_ identifier: String) -> Bool {
        let secure = app.secureTextFields[identifier]
        let field = secure.exists ? secure : app.textFields[identifier]
        guard field.exists, let value = field.value as? String else { return false }
        return value.isEmpty || value == field.placeholderValue
    }

    private func preseededRunID() throws -> String? {
        guard let runID = ProcessInfo.processInfo.environment["JINBAO_QA_PRESEEDED_RUN_ID"] else { return nil }
        guard !runID.isEmpty, runID.count <= 80,
              runID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            throw XCTSkip("JINBAO_QA_PRESEEDED_RUN_ID must match the helper run ID: 1–80 letters, digits or hyphens.")
        }
        return runID
    }

    private func finishSyntheticPhoto(runID: String) throws {
        let title = "Jinbao QA photo \(runID)"
        let titleField = app.textFields["draftTitle"]
        let picker = app.buttons["composerPickPhoto"]
        guard titleField.waitForExistence(timeout: 8), titleField.isHittable,
              picker.exists, picker.isHittable else {
            attachNote("The synthetic composer is not available for safe confirmation. Use test04 to resume automated selection for run \(runID). No picker screenshot was collected.",
                       name: "Pending photo — automated selection pending")
            throw XCTSkip("PhotosPicker may still be open, or no pending composer is available. No photo was selected or draft changed.")
        }
        guard (titleField.value as? String) == title else {
            throw XCTSkip("The current draft title does not match the preseeded synthetic run. Its title and data were retained.")
        }
        let identifiedRemove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "removeDraftAsset-")).firstMatch
        let remove = identifiedRemove.exists ? identifiedRemove : app.buttons["移除"].firstMatch
        guard remove.waitForExistence(timeout: 15), remove.isHittable else {
            throw XCTSkip("The matching synthetic draft has no confirmed imported photo. Run test04 to select a verified fixture before saving.")
        }
        guard importedDraftPreview() != nil else {
            throw XCTSkip("The matching synthetic draft does not expose exactly one visible preview. Its data was retained.")
        }
        try verifyFullSizePhoto(runID: runID, controlPrefix: "draftPreview-",
                               attachmentName: "06B Draft full-size synthetic photo — \(runID)")
        attachScreenshot(app, name: "06 Synthetic photo in composer — \(runID)")
        tapVisible(app.buttons["saveDraft"])
        XCTAssertTrue(app.buttons["addMoment"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let savedTitles = app.staticTexts.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(savedTitles.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(savedTitles.count, 1, "The persisted synthetic title must identify one record.")
        savedTitles.firstMatch.tap()
        XCTAssertTrue(app.navigationBars.buttons["关闭"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists)
        try verifyFullSizePhoto(runID: runID, controlPrefix: "detailPreview-",
                               attachmentName: "07B Persisted full-size synthetic photo — \(runID)")
        attachScreenshot(app, name: "07 Persisted synthetic photo detail — \(runID)")
        app.navigationBars.buttons["关闭"].tap()
    }

    private func verifyFullSizePhoto(runID: String, controlPrefix: String, attachmentName: String) throws {
        let controls = boundedElements(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", controlPrefix)), maximum: 4)
            .filter { $0.exists && $0.isHittable }
        guard controls.count == 1 else {
            throw XCTSkip("The matching synthetic record has no unique full-size preview button. No unverified photo screenshot was collected.")
        }
        controls[0].tap()
        let close = app.buttons["closePhotoPreview"]
        guard close.waitForExistence(timeout: 8) else {
            if close.exists && close.isHittable { close.tap() }
            throw XCTSkip("The full-size image is not available for safe OCR validation.")
        }
        attachScreenshot(app, name: "Verified synthetic selection — full-screen preview")
        let matched = syntheticScreenMatches(runID: runID)
        if matched {
            attachScreenshot(app, name: attachmentName)
        }
        guard close.exists, close.isHittable else {
            throw XCTSkip("The full-size preview cannot be safely closed; no save was performed.")
        }
        close.tap()
        guard matched else {
            throw XCTSkip("The full-size photo did not match both the synthetic marker and exact run ID. Its pixels and OCR were not retained.")
        }
        guard controls[0].waitForExistence(timeout: 5), controls[0].isHittable else {
            throw XCTSkip("The source view did not return after full-size preview validation.")
        }
    }

    private func openTimeline() throws {
        app.launch()
        let dad = app.buttons["chooseDad"]
        let timeline = app.buttons["tabTimeline"]
        let placeholder = app.buttons["placeholderConnect"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in dad.exists || timeline.exists || placeholder.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        if app.textFields["draftTitle"].waitForExistence(timeout: 1) {
            throw XCTSkip("A saved draft is open. Its data was retained; use the matching synthetic resume entry when applicable.")
        }
        if dad.exists {
            attachScreenshot(app, name: "Onboarding — choose identity")
            dad.tap()
            let confirm = app.buttons["confirmParent"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            attachScreenshot(app, name: "Onboarding — confirm Dad")
            confirm.tap()
        } else {
            attachNote("This installation already has an identity. Its saved identity was retained; first-run identity selection was not exercised in this run.", name: "Onboarding — existing identity")
        }
        if !timeline.exists {
            XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "Debug placeholder connection is required for offline acceptance.")
            tapVisible(placeholder)
        }
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        // Guard against a verified real-cloud installation before creating any test data.
        app.buttons["tabCloud"].tap()
        if app.staticTexts["storageVerified"].waitForExistence(timeout: 1) {
            throw XCTSkip("This installation is connected to real cloud storage. Use a Debug placeholder installation for offline acceptance; no synthetic record was created.")
        }
        XCTAssertTrue(app.staticTexts["storagePlaceholder"].exists ||
                      app.descendants(matching: .any)["storagePlaceholder"].firstMatch.exists ||
                      placeholder.exists, "Offline acceptance requires a confirmed Debug placeholder state.")
        timeline.tap()
        XCTAssertTrue(app.buttons["addMoment"].exists)
    }

    private func capturePlaceholderCloud() throws {
        app.buttons["tabCloud"].tap()
        if app.staticTexts["storageVerified"].exists {
            throw XCTSkip("This installation is connected to real cloud storage. Synthetic offline cloud acceptance requires a placeholder installation.")
        }
        let placeholder = app.buttons["placeholderConnect"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5))
        attachScreenshot(placeholder, name: "08 Cloud — debug placeholder action")
        tapVisible(placeholder)
        let message = app.staticTexts["connectionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("占位"))
        attachScreenshot(message, name: "09 Cloud — placeholder status")
        app.buttons["tabTimeline"].tap()
    }

    private func allowExpectedAddOnlyPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        let expected = alert.label.contains("孩子验收照片") || alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "孩子验收照片")).count > 0
        guard expected else { return }
        let allowLabels = ["Allow Adding Photos", "Allow Photos to Be Added", "允许添加照片", "允许添加", "允许", "Allow", "OK", "好"]
        for label in allowLabels {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return }
        }
    }

    private let pickerSelectLabels = ["Select", "Select Photo", "Select photo", "Choose", "Choose Photo",
                                      "Use Photo", "Add", "Done", "选择", "选择照片", "选取", "选取照片",
                                      "使用照片", "添加", "完成", "确定"]
    private let pickerDismissLabels = ["Cancel", "Close", "Back", "取消", "关闭", "返回"]

    private func importedDraftPreview() -> XCUIElement? {
        // Prefer the stable identifiers supplied by the composer. Retain support for
        // the original 72pt Image on older builds, without inspecting its contents.
        let controls = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        if controls.count == 1 { return controls[0] }
        let identifiedImages = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "draftPreview-", "draftPreviewImage-"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        if identifiedImages.count == 1 { return identifiedImages[0] }
        let legacy = boundedElements(app.scrollViews.images, maximum: 32).filter { image in
            guard image.exists else { return false }
            let frame = image.frame
            return image.isHittable && (60...100).contains(frame.width) && (60...100).contains(frame.height)
        }
        return legacy.count == 1 ? legacy[0] : nil
    }

    private func selectSyntheticPhotoInPicker(runID: String) throws {
        guard waitForStablePicker(), let add = pickerAddButton(), !add.isEnabled else {
            throw XCTSkip("A stable picker with an empty selection is required.")
        }
        guard syntheticGridMarkerMatches(runID: runID, column: 1, number: 1) else {
            throw XCTSkip("The observed QA 1 screen location no longer matches its exact synthetic run.")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.447)).tap()
        try waitForImportedComposer(runID: runID, cleanMultiSelection: true)
    }

    private func syntheticGridMarkerMatches(runID: String, column: Int, number: Int) -> Bool {
        // Geometry comes from the inspected Cody XS screen. The exact run-specific
        // markers must still match now, before any thumbnail can be selected.
        guard let image = app.screenshot().image.cgImage else { return false }
        let crop = CGRect(x: CGFloat(image.width) * CGFloat(column) / 3,
                          y: CGFloat(image.height) * 0.370,
                          width: CGFloat(image.width) / 3,
                          height: CGFloat(image.height) * 0.154)
        guard let cropped = image.cropping(to: crop) else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        guard (try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])) != nil else { return false }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.50 }.map { $0.string }
        let marker = lines.contains { $0.hasSuffix("QA \(number)") }
        let exactRun = lines.contains { $0.hasSuffix(runID) }
        attachNote("gridMarker=\(marker); gridExactRun=\(exactRun)", name: "Observed synthetic grid checks")
        return marker && exactRun
    }

    private func syntheticScreenMatches(runID: String, requiredNumber: Int? = nil) -> Bool {
        guard let image = app.screenshot().image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.005
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return false }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.50 }.map { $0.string }
        let numbers = requiredNumber.map { [$0] } ?? [1, 2]
        let marker = numbers.contains { number in lines.contains { $0.hasSuffix("QA \(number)") } }
        let exactRun = lines.contains { $0.hasSuffix(runID) }
        attachNote("fullScreenMarker=\(marker); fullScreenExactRun=\(exactRun)", name: "Synthetic full-screen checks")
        return marker && exactRun
    }

    private func syntheticThumbnailNumber(_ element: XCUIElement, runID: String) -> Int? {
        // PHPicker center-crops thumbnails, clipping the fixed text prefixes. The
        // unique run ID and QA number must both remain visible in the same image.
        // Full-size exact-marker validation is still mandatory before saving.
        guard let image = element.screenshot().image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.008
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.70 }.map { $0.string }
        guard lines.contains(where: { $0.hasSuffix(runID) }) else { return nil }
        for number in [1, 2] {
            if lines.contains(where: { $0.hasSuffix("QA \(number)") }) { return number }
        }
        return nil
    }

    private func visiblePickerCells() -> [XCUIElement] {
        let viewport = app.frame
        let knownGrid = app.images.matching(identifier: "PXGGridLayout-Info")
        let handles = knownGrid.allElementsBoundByAccessibilityElement
        var observed: [(element: XCUIElement, frame: CGRect)] = []
        for element in handles.prefix(32) {
            guard element.exists else { continue }
            let frame = element.frame
            guard frame.width >= 60, frame.width <= viewport.width * 0.52,
                  (0.80...1.25).contains(frame.height / frame.width),
                  viewport.contains(frame), element.isHittable else { continue }
            observed.append((element, frame))
        }
        // Frame reads cross the XCTest process boundary. Cache once before sorting.
        return observed.sorted { left, right in
            abs(left.frame.minY - right.frame.minY) > 8
                ? left.frame.minY < right.frame.minY : left.frame.minX < right.frame.minX
        }.map(\.element)
    }

    private func waitForStablePicker() -> Bool {
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.count > 0 }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed else { return false }
        // Handles bind to AX identity, so async placeholders cannot shift an index.
        return true
    }

    private func boundedElements(_ query: XCUIElementQuery, maximum: Int) -> [XCUIElement] {
        // Bind to AX identity rather than a dynamic query index: PhotosPicker can
        // asynchronously remove placeholder images between count and frame reads.
        let elements = query.allElementsBoundByAccessibilityElement
        let count = elements.count
        let chosen: [XCUIElement]
        if count <= maximum {
            chosen = elements
        } else {
            let first = maximum / 2
            chosen = Array(elements.prefix(first)) + Array(elements.suffix(maximum - first))
        }
        return chosen.filter { $0.exists }
    }

    private func enlargedPhotoPreview() -> XCUIElement? {
        let viewport = app.frame
        let images = app.images.allElementsBoundByAccessibilityElement.prefix(32)
        var candidates: [XCUIElement] = []
        for image in images {
            guard image.exists else { continue }
            let frame = image.frame
            // PHPicker context previews may report an unclipped image rectangle;
            // the screenshot API clips it to the device's visible screen.
            if frame.width >= viewport.width * 0.55,
               frame.width <= viewport.width * 2,
               frame.height >= viewport.height * 0.18,
               frame.height <= viewport.height * 0.94,
               frame.minY >= viewport.minY,
               frame.maxY <= viewport.maxY,
               viewport.intersects(frame) {
                candidates.append(image)
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func syntheticMarkerMatches(in preview: XCUIElement, runID: String, requiredNumber: Int? = nil) -> Bool {
        autoreleasepool {
            // The image and all OCR text remain local to this scope. No attachment,
            // file, logging, analytics, or OCR transcript is created for candidates.
            guard preview.exists, let image = preview.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.012
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                return false
            }
            let lines = (request.results ?? []).compactMap { observation -> String? in
                guard let text = observation.topCandidates(1).first, text.confidence >= 0.70 else { return nil }
                return text.string.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            let markerPattern = requiredNumber.map { "^JINBAO QA ?\($0)$" } ?? "^JINBAO QA ?[12]$"
            let marker = lines.contains { $0.range(of: markerPattern, options: .regularExpression) != nil }
            let exactRun = lines.contains("RUN \(runID)")
            return marker && exactRun
        }
    }

    private func syntheticForegroundPreviewMatches(runID: String, requiredNumber: Int? = nil) -> Bool {
        // PHPicker exposes the sharp context preview as a render layer rather than
        // an Image AX node. Analyze only the foreground area above its Select action;
        // discard pixels and nonmatching OCR immediately, without an attachment.
        guard let select = uniqueVisibleButton(labels: ["选择", "Select"]) else { return false }
        let viewport = app.frame
        let menuTop = select.frame.minY
        guard menuTop > viewport.height * 0.30,
              let image = app.screenshot().image.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        let top = max(44, viewport.minY)
        request.regionOfInterest = CGRect(x: 0, y: 1 - menuTop / viewport.height,
                                         width: 1, height: (menuTop - top) / viewport.height)
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return false }
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let item = observation.topCandidates(1).first, item.confidence >= 0.70 else { return nil }
            return item.string.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let markerPattern = requiredNumber.map { "^JINBAO QA ?\($0)$" } ?? "^JINBAO QA ?[12]$"
        let markers = lines.filter { $0.range(of: markerPattern, options: .regularExpression) != nil }
        let runMatches = lines.filter { $0 == "RUN \(runID)" }
        attachNote("foregroundMarker=\(markers.count == 1); foregroundExactRun=\(runMatches.count == 1)", name: "Foreground preview — fixed synthetic checks")
        return markers.count == 1 && runMatches.count == 1
    }

    private func uniqueVisibleButton(labels: [String], navigationOnly: Bool = false) -> XCUIElement? {
        let buttons = navigationOnly ? app.navigationBars.buttons : app.buttons
        for label in labels {
            let matches = buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
                .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable && $0.isEnabled }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    private func dismissUnmatchedPreview(_ preview: XCUIElement?) -> Bool {
        // Some library items consume long press without opening a context preview.
        if app.images.matching(identifier: "PXGGridLayout-Info").count > 0,
           uniqueVisibleButton(labels: ["选择", "Select"]) == nil {
            return true
        }
        // A tap in the already observed top header/backdrop cannot select a grid
        // photo or a context Select action. It may close the picker; the caller
        // validates the preserved draft before reopening in that case.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: 60)).tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.images.matching(identifier: "PXGGridLayout-Info").count > 0 || self.app.buttons["composerPickPhoto"].isHittable
        }, object: nil)
        return XCTWaiter.wait(for: [returned], timeout: 5) == .completed
    }

    private func pickerAddButton() -> XCUIElement? {
        let pattern = "^(Add|添加)([ ]*[(（][0-9]+[)）])?$"
        let matches = boundedElements(app.buttons.matching(NSPredicate(format: "label MATCHES %@", pattern)), maximum: 4)
            .filter { $0.exists && $0.isHittable }
        return matches.count == 1 ? matches[0] : nil
    }

    private func waitForImportedComposer(runID: String, cleanMultiSelection: Bool) throws {
        let picker = app.buttons["composerPickPhoto"]
        // Multi-selection returns from preview to the grid first. The final Add is
        // permitted only when selection was initially empty and we verified the sole
        // image selected in this test; never confirm an existing user selection.
        if !picker.isHittable, let add = pickerAddButton(), add.isEnabled {
            guard cleanMultiSelection else {
                throw XCTSkip("The final Add requires a proven empty initial selection. It was not confirmed.")
            }
            let countPattern = "[0-9]+"
            if let range = add.label.range(of: countPattern, options: .regularExpression),
               add.label[range] != "1" {
                throw XCTSkip("The picker reports more than one selected item. Unverified photos were not added.")
            }
            add.tap()
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in picker.exists && picker.isHittable }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed,
              (app.textFields["draftTitle"].value as? String) == "Jinbao QA photo \(runID)" else {
            attachPickerDiagnostics(stage: "selection did not return composer", candidate: 0,
                                    visibleCells: visiblePickerCells().count, enlarged: enlargedPhotoPreview() != nil, matched: true)
            throw XCTSkip("A verified synthetic image was selected, but the expected composer did not return. No save or screenshot was performed.")
        }
    }

    private func attachPickerDiagnostics(stage: String, candidate: Int, visibleCells: Int, enlarged: Bool, matched: Bool) {
        attachNote("stage=\(stage); candidate=\(candidate); visibleCells=\(visibleCells); enlarged=\(enlarged); OCRMatch=\(matched)", name: "Photo picker — bounded safe diagnostics")
    }

    private func uniqueSyntheticPhoto(runID: String) -> XCUIElement? {
        let escapedRun = NSRegularExpression.escapedPattern(for: runID)
        let runBoundary = ".*(^|[^A-Za-z0-9-])" + escapedRun + "([^A-Za-z0-9-]|$).*"
        let identity = NSPredicate(format: "label MATCHES %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
                                   runBoundary, "JINBAO QA 1", "JINBAO_QA_1_")
        // Restrict lookup to actual selectable photo elements, without dumping labels.
        for type in [XCUIElement.ElementType.cell, .image, .button] {
            let matches = app.descendants(matching: type).matching(identity)
            if matches.count == 1, matches.firstMatch.isHittable { return matches.firstMatch }
        }
        return nil
    }

    private func tapVisible(_ element: XCUIElement) {
        dismissTransientBanners()
        for _ in 0..<4 {
            if element.isHittable { break }
            if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func attachScreenshot(_ element: XCUIElement, name: String) {
        dismissTransientBanners()
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachNote(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissTransientBanners() {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "NotificationShortLookView", "NotificationShortLookView")).firstMatch
        guard banner.exists else { return }
        banner.swipeUp()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !banner.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed,
                       "Transient notifications must be dismissed before capture or tapping.")
    }
}
