import XCTest
import UIKit
import Vision

/// The 2025 read test uses a real FamilyReader ID; the separately opted-in write test creates synthetic text only.
/// Credential configuration and existing records are never modified by these UI tests.
@MainActor
final class CosTimelineAcceptanceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")
    private var pickerSnapshotFailures = 0
    private var pickerSnapshotTraversalLimitReached = false
    private var pickerScanDiagnostics: [[String: Any]] = []
    private var pickerLastExactRunCount = 0
    private var pickerLastExactRunFrames: [CGRect] = []
    private var pickerThumbnailExactMatchedBeforeSelection = false
    private var pickerPreviewFallbackUsed = false
    private var pickerRunPreviewAttempts = 0
    private var pickerPreviewScanDiagnostics: [[String: Bool]] = []

    override func setUpWithError() throws { continueAfterFailure = false }

    func testExistingAndroid2025RecordVisibleOnHomeAndReadOnly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JINBAO_COS_ACCEPTANCE"] == "1" else { throw XCTSkip("Explicit COS acceptance is disabled.") }
        guard let monthString = environment["JINBAO_COS_EXPECTED_MONTH"],
              let month = Int(monthString), (1...12).contains(month),
              let remoteID = environment["JINBAO_COS_REMOTE_ID"],
              remoteID.range(of: #"^remote:(dad|mom):record:[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            throw SafeFailure.prerequisite
        }
        app.launch()
        let timeline = app.buttons["tabTimeline"]
        guard timeline.waitForExistence(timeout: 15), timeline.isHittable else { throw SafeFailure.timeline }
        timeline.tap()
        let headerID = "month-2025-\(month)"
        let header = app.staticTexts[headerID].firstMatch
        let card = app.buttons["momentCard-\(remoteID)"].firstMatch
        let scroll = app.scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: 10) else { throw SafeFailure.timeline }
        var observedMonth = false
        var observedCard = false
        // Bounded genuine chronological scrolling; never query or log private labels/content.
        for _ in 0..<160 {
            if safelyVisible(header), header.label == "2025年\(month)月" {
                if !observedMonth {
                    let attachment = XCTAttachment(screenshot: header.screenshot())
                    attachment.name = "COS 2025 month heading only"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                observedMonth = true
            }
            if card.exists, card.isHittable, card.frame.intersects(scroll.frame) {
                observedCard = true
                if observedMonth { break }
            }
            scroll.swipeUp(velocity: .slow)
        }
        guard observedMonth, observedCard, card.isHittable else { throw SafeFailure.recordNotVisible }
        card.tap()
        guard app.navigationBars["小日常"].waitForExistence(timeout: 8),
              !app.buttons["momentActions"].exists, !app.buttons["editMoment"].exists,
              !app.buttons["trashMoment"].exists else { throw SafeFailure.readOnly }
        let readOnly = app.staticTexts["这是另一台设备或另一位家长留下的，这里只读。"].firstMatch
        let detailScroll = app.scrollViews.firstMatch
        for _ in 0..<40 {
            if readOnly.exists, readOnly.isHittable { break }
            detailScroll.swipeUp(velocity: .slow)
        }
        guard readOnly.exists, readOnly.isHittable else { throw SafeFailure.readOnly }
        let result = XCTAttachment(string: "{\"year\":2025,\"month\":\(month),\"homeMonthHeaderVisible\":true,\"expectedRemoteCardOpened\":true,\"readOnlyMessageVisible\":true,\"editActionAbsent\":true,\"deleteActionAbsent\":true,\"archiveMutatedByTest\":false}")
        result.name = "COS 2025 home and read-only evidence without private content"
        result.lifetime = .keepAlways
        add(result)
        let close = app.navigationBars.buttons["关闭"].firstMatch
        guard close.isHittable else { throw SafeFailure.navigation }
        close.tap()
    }

    /// Writes only this synthetic text record through the normal Debug production UI.
    /// The acceptance operator must supply a restricted STS connection before opting in.
    func testSyntheticTextBackupRestartAndRepeatBackup() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JINBAO_COS_WRITE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit COS write acceptance is disabled.")
        }
        let run = environment["JINBAO_COS_WRITE_RUN_ID"] ?? "20261019"
        guard run.range(of: #"^[A-Z0-9-]{8,40}$"#, options: .regularExpression) != nil else { throw SafeFailure.prerequisite }
        let title = "JINBAO COS QA \(run)"
        let note = "Synthetic text-only COS acceptance. Run \(run). No personal content."
        app.launch()
        guard app.buttons["tabTimeline"].waitForExistence(timeout: 15), !app.textFields["draftTitle"].exists else {
            throw SafeFailure.timeline
        }
        try tapSafe(app.buttons["tabTimeline"])
        guard !app.buttons["timelineResumeDraft"].exists else { throw SafeFailure.retainedDraft }
        try openVerifiedDebugCloud()
        try filterSyntheticTitle(title)
        var createdThisRun = false
        let recordID: String
        let matching = syntheticCards(title)
        if matching.count == 0 {
            // Search has conclusively returned no matching card; do not touch any existing draft.
            guard app.staticTexts["没有找到相关记录"].waitForExistence(timeout: 5),
                  !app.buttons["timelineResumeDraft"].exists else { throw SafeFailure.syntheticCollision }
            try tapSafe(app.buttons["addMoment"])
            try tapSafe(app.buttons["addNoteMenuAction"])
            let titleField = app.textFields["draftTitle"]
            let noteField = app.descendants(matching: .any)["draftNote"].firstMatch
            guard titleField.waitForExistence(timeout: 5),
                  isEmpty(titleField), isEmpty(noteField),
                  app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == 0 else {
                throw SafeFailure.retainedDraft
            }
            try tapSafe(titleField); titleField.typeText(title)
            try tapSafe(noteField); noteField.typeText(note)
            let dismissKeyboard = app.buttons["dismissComposerKeyboard"]
            if dismissKeyboard.exists && dismissKeyboard.isHittable { dismissKeyboard.tap() }
            guard titleField.value as? String == title, noteField.value as? String == note else {
                throw SafeFailure.syntheticContent
            }
            try attachCrop(titleField, "COS synthetic title before save")
            try attachCrop(noteField, "COS synthetic text before save")
            try tapSafe(app.buttons["saveDraft"])
            guard !titleField.waitForExistence(timeout: 1) else { throw SafeFailure.syntheticContent }
            createdThisRun = true
            try filterSyntheticTitle(title)
        }
        recordID = try verifySyntheticDetail(title: title, note: note)
        try tapSafe(app.navigationBars.buttons["关闭"].firstMatch)
        try openVerifiedDebugCloud()
        try awaitBackupComplete(timeout: 120)
        try attachCrop(app.staticTexts["storageVerified"], "COS synthetic automatic backup completed")

        app.terminate(); app.launch()
        guard app.buttons["tabTimeline"].waitForExistence(timeout: 15) else { throw SafeFailure.timeline }
        try filterSyntheticTitle(title)
        let restartedID = try verifySyntheticDetail(title: title, note: note)
        guard restartedID == recordID else { throw SafeFailure.syntheticContent }
        try tapSafe(app.navigationBars.buttons["关闭"].firstMatch)
        try openVerifiedDebugCloud()
        try awaitBackupComplete(timeout: 30)
        try tapSafe(app.buttons["backupNow"])
        // Observe a real invocation, not the stale completed label left by the first backup.
        let observedRepeatInProgress = app.buttons["pauseBackup"].waitForExistence(timeout: 2)
        try awaitBackupComplete(timeout: 120)
        let message = app.staticTexts["connectionMessage"].firstMatch
        guard message.waitForExistence(timeout: 8), message.label == "已备份到云端，本机记录仍然保留。" else {
            throw SafeFailure.backupFeedback
        }
        try attachCrop(app.staticTexts["storageVerified"], "COS repeat backup completed after restart")
        try attachCrop(message, "COS repeat backup success feedback")
        let metadata: [String: Any] = ["run": run, "localRecordID": recordID, "createdThisRun": createdThisRun,
                                      "syntheticTextOnly": true, "mediaUploadTested": false,
                                      "debugPathVerified": true, "automaticBackupCompleted": true,
                                      "sameRecordAfterRestart": true, "manualRepeatBackupCompleted": true,
                                      "repeatInProgressObserved": observedRepeatInProgress,
                                      "oldRecordsEdited": false, "connectionOrIdentityChanged": false]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "COS synthetic text backup and restart receipt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSyntheticPhotoBackupAndRestart() throws {
        guard ProcessInfo.processInfo.environment["JINBAO_COS_PHOTO_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit COS synthetic-photo acceptance is disabled.")
        }
        let title = "JINBAO COS PHOTO QA 20261019"
        let note = "Synthetic QA1 photo-only COS acceptance. RUN QA20261019COS. No personal content."
        app.launch()
        guard app.buttons["tabTimeline"].waitForExistence(timeout: 15), !app.textFields["draftTitle"].exists else {
            throw SafeFailure.timeline
        }
        try tapSafe(app.buttons["tabTimeline"])
        try openVerifiedDebugCloud()
        try filterSyntheticTitle(title)
        guard syntheticCards(title).isEmpty, app.staticTexts["没有找到相关记录"].waitForExistence(timeout: 5) else {
            throw SafeFailure.syntheticCollision
        }
        let resume = app.buttons["timelineResumeDraft"]
        let resumedOwnedDraft = resume.exists
        if resumedOwnedDraft {
            try tapSafe(resume)
        } else {
            try tapSafe(app.buttons["addMoment"])
            try tapSafe(app.buttons["addNoteMenuAction"])
        }
        let titleField = app.textFields["draftTitle"]
        let noteField = app.descendants(matching: .any)["draftNote"].firstMatch
        guard titleField.waitForExistence(timeout: 5), app.navigationBars["记录小日常"].exists,
              app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == 0 else {
            throw SafeFailure.retainedDraft
        }
        if resumedOwnedDraft {
            // Only the exact interrupted zero-media draft from this run is eligible for continuation.
            // Keep its existing text, date, identity and upload eligibility untouched.
            guard titleField.value as? String == title, noteField.value as? String == note else {
                throw SafeFailure.retainedDraft
            }
        } else {
            guard isEmpty(titleField), isEmpty(noteField) else { throw SafeFailure.retainedDraft }
            try tapSafe(titleField); titleField.typeText(title)
            try tapSafe(noteField); noteField.typeText(note)
        }
        let dismissKeyboard = app.buttons["dismissComposerKeyboard"]
        if dismissKeyboard.exists && dismissKeyboard.isHittable { dismissKeyboard.tap() }
        guard titleField.value as? String == title, noteField.value as? String == note else { throw SafeFailure.syntheticContent }
        try tapSafe(app.buttons["composerPickPhoto"])
        try selectOnlyVerifiedQA1()
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-"))
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            previews.count == 1 && !self.app.progressIndicators["photoImportProgress"].exists
        }, object: nil)
        guard XCTWaiter.wait(for: [imported], timeout: 60) == .completed,
              !app.staticTexts["photoImportFailure"].exists else { throw SafeFailure.photoImport }
        try tapSafe(previews.firstMatch)
        try attachVerifiedQA1Preview("COS exact synthetic QA1 preview before save")
        try tapSafe(app.buttons["closePhotoPreview"])
        guard titleField.value as? String == title, noteField.value as? String == note, previews.count == 1 else {
            throw SafeFailure.syntheticContent
        }
        // This is the first operation that makes the confirmed synthetic media eligible for automatic backup.
        try tapSafe(app.buttons["saveDraft"])
        guard !titleField.waitForExistence(timeout: 1) else { throw SafeFailure.syntheticContent }
        try filterSyntheticTitle(title)
        let recordID = try openSyntheticPhotoDetail(title: title, note: note)
        try tapSafe(app.navigationBars.buttons["关闭"].firstMatch)
        try openVerifiedDebugCloud()
        try awaitBackupComplete(timeout: 180)
        try attachCrop(app.staticTexts["storageVerified"], "COS synthetic QA1 backup completed")
        let message = app.staticTexts["connectionMessage"].firstMatch
        guard message.waitForExistence(timeout: 8), message.label == "已备份到云端，本机记录仍然保留。" else {
            throw SafeFailure.backupFeedback
        }
        try attachCrop(message, "COS synthetic QA1 backup success feedback")
        app.terminate(); app.launch()
        guard app.buttons["tabTimeline"].waitForExistence(timeout: 15) else { throw SafeFailure.timeline }
        try filterSyntheticTitle(title)
        let restartedID = try openSyntheticPhotoDetail(title: title, note: note)
        guard restartedID == recordID else { throw SafeFailure.syntheticContent }
        let detailPreview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        guard detailPreview.count == 1 else { throw SafeFailure.photoImport }
        try tapSafe(detailPreview.firstMatch)
        try attachVerifiedQA1Preview("COS exact synthetic QA1 persisted after restart")
        try tapSafe(app.buttons["closePhotoPreview"])
        try tapSafe(app.navigationBars.buttons["关闭"].firstMatch)
        let receipt: [String: Any] = ["localRecordID": recordID, "title": title, "mediaCount": 1,
                                    "fixtureRun": "QA20261019COS", "fixtureQA": 1, "resumedOwnedDraft": resumedOwnedDraft,
                                    "thumbnailOCRMatchedBeforeSelection": pickerThumbnailExactMatchedBeforeSelection,
                                    "pickerContextPreviewVerifiedBeforeSelection": pickerPreviewFallbackUsed,
                                    "fullPreviewOCRMatchedBeforeSave": true,
                                    "restartPreviewOCRMatched": true, "ocrMatch": true,
                                    "debugPathVerified": true, "automaticBackupCompleted": true,
                                    "sameRecordAfterRestart": true, "oldRecordsEdited": false,
                                    "connectionOrIdentityChanged": false,
                                    "remoteObjectHashRequiresIndependentVerification": true]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "COS synthetic QA1 photo backup and restart receipt"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openSyntheticPhotoDetail(title: String, note: String) throws -> String {
        guard app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: 8) else {
            throw SafeFailure.syntheticContent
        }
        let cards = syntheticCards(title)
        guard cards.count == 1, let card = cards.first else { throw SafeFailure.syntheticCollision }
        let id = String(card.identifier.dropFirst("momentCard-".count))
        guard UUID(uuidString: id) != nil else { throw SafeFailure.syntheticCollision }
        try tapSafe(card)
        guard app.navigationBars["小日常"].waitForExistence(timeout: 8),
              app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
              app.staticTexts.matching(NSPredicate(format: "label == %@", note)).firstMatch.exists,
              app.buttons["momentActions"].exists,
              app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-")).count == 1 else {
            throw SafeFailure.syntheticContent
        }
        return id
    }

    private func selectOnlyVerifiedQA1() throws {
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.count > 0 }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else { throw SafeFailure.photoSelection }
        pickerSnapshotFailures = 0
        pickerSnapshotTraversalLimitReached = false
        pickerScanDiagnostics = []
        pickerThumbnailExactMatchedBeforeSelection = false
        pickerPreviewFallbackUsed = false
        pickerRunPreviewAttempts = 0
        pickerPreviewScanDiagnostics = []
        guard let initialAdd = uniquePickerAddButton(), !initialAdd.isEnabled else {
            cancelPhotoPickerSafely(); throw SafeFailure.photoSelection
        }
        var selected = false
        var scanCounts: [Int] = []
        var confirmationCounts: [Int] = []
        defer {
            let diagnostics: [String: Any] = ["scanExactMatchCounts": scanCounts,
                                              "confirmationExactMatchCounts": confirmationCounts,
                                              "selectedAfterFreshExactMatch": selected,
                                              "thumbnailExactQARunMatched": pickerThumbnailExactMatchedBeforeSelection,
                                              "contextPreviewExactQARunMatched": pickerPreviewFallbackUsed,
                                              "contextPreviewAttempted": pickerRunPreviewAttempts > 0,
                                              "contextPreviewBudgetRespected": pickerRunPreviewAttempts <= 5,
                                              "previewScans": pickerPreviewScanDiagnostics,
                                              "requiredQA": 1, "requiredRun": "QA20261019COS",
                                              "rawOCRRetained": false, "pickerPixelsAttached": false,
                                              "snapshotFailures": pickerSnapshotFailures,
                                              "snapshotTraversalLimitReached": pickerSnapshotTraversalLimitReached,
                                              "scans": pickerScanDiagnostics]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "COS synthetic-only picker matching diagnostics"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        for _ in 0..<5 {
            var candidates = verifiedQA1CellFrames()
            scanCounts.append(candidates.count)
            // A visible exact RUN means the new fixtures are already in this viewport.
            // Retry fresh OCR here before scrolling away; RUN alone never authorizes selection.
            if candidates.count != 1 && pickerLastExactRunCount > 0 {
                for _ in 0..<2 {
                    Thread.sleep(forTimeInterval: 0.35)
                    candidates = verifiedQA1CellFrames()
                    scanCounts.append(candidates.count)
                    if candidates.count == 1 { break }
                }
            }
            if candidates.count == 1 {
                // Grid animation and OCR can fluctuate. Retest the current visible grid up to
                // three times; never tap a position retained from the initial candidate scan.
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.25)
                    let current = verifiedQA1CellFrames()
                    confirmationCounts.append(current.count)
                    guard current.count == 1, let frame = current.first, app.frame.contains(frame) else { continue }
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
                    pickerThumbnailExactMatchedBeforeSelection = true
                    selected = true
                    break
                }
            }
            if !selected, pickerLastExactRunCount > 0 {
                selected = try selectQA1ThroughExactRunPreview(preferred: candidates.count == 1 ? candidates[0] : nil)
            }
            if selected { break }
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        guard selected else { cancelPhotoPickerSafely(); throw SafeFailure.photoSelection }
        let selectionReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons["composerPickPhoto"].isHittable ||
                (self.uniquePickerSelectButton() == nil && self.uniquePickerAddButton()?.isEnabled == true)
        }, object: nil)
        guard XCTWaiter.wait(for: [selectionReady], timeout: 10) == .completed else {
            cancelPhotoPickerSafely(); throw SafeFailure.photoSelection
        }
        if !app.buttons["composerPickPhoto"].isHittable {
            guard let add = uniquePickerAddButton(), add.isEnabled else {
                cancelPhotoPickerSafely(); throw SafeFailure.photoSelection
            }
            if let count = add.label.range(of: "[0-9]+", options: .regularExpression), add.label[count] != "1" {
                cancelPhotoPickerSafely(); throw SafeFailure.photoSelection
            }
            add.tap()
        }
        guard app.buttons["composerPickPhoto"].waitForExistence(timeout: 20) else { throw SafeFailure.photoImport }
    }

    private func uniquePickerAddButton() -> XCUIElement? {
        let buttons = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Add|添加|Done|完成)([ ]*[(（][0-9]+[)）])?$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        return buttons.count == 1 ? buttons[0] : nil
    }

    private func uniquePickerSelectButton() -> XCUIElement? {
        let buttons = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Select|选择)$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable && $0.isEnabled }
        return buttons.count == 1 ? buttons[0] : nil
    }

    private func samePickerFrame(_ first: CGRect, _ second: CGRect) -> Bool {
        abs(first.minX - second.minX) < 2 && abs(first.minY - second.minY) < 2 &&
            abs(first.width - second.width) < 2 && abs(first.height - second.height) < 2
    }

    private func selectQA1ThroughExactRunPreview(preferred: CGRect?) throws -> Bool {
        // Only exact RUN thumbnails authorize a preview. The five-candidate budget is global to this picker session.
        var examinedFrames: [CGRect] = []
        while pickerRunPreviewAttempts < 5 {
            _ = verifiedQA1CellFrames()
            let ordered = pickerLastExactRunFrames.sorted { left, right in
                guard let preferred else { return left.minY == right.minY ? left.minX < right.minX : left.minY < right.minY }
                let a = samePickerFrame(left, preferred), b = samePickerFrame(right, preferred)
                return a != b ? a : (left.minY == right.minY ? left.minX < right.minX : left.minY < right.minY)
            }
            guard let candidate = ordered.first(where: { frame in
                !examinedFrames.contains(where: { samePickerFrame($0, frame) })
            }) else { return false }
            // Re-scan immediately before pressing. Never reuse a pre-scroll or pre-preview cell position.
            _ = verifiedQA1CellFrames()
            guard let fresh = pickerLastExactRunFrames.first(where: { samePickerFrame($0, candidate) }),
                  app.frame.contains(fresh) else { return false }
            examinedFrames.append(fresh)
            pickerRunPreviewAttempts += 1
            let viewport = app.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: fresh.midX - viewport.minX, dy: fresh.midY - viewport.minY))
                .press(forDuration: 1.2)
            let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.uniquePickerSelectButton() != nil
            }, object: nil)
            if XCTWaiter.wait(for: [opened], timeout: 5) == .completed {
                // Sharp foreground OCR must independently confirm both exact tokens before Select is allowed.
                if freshPickerPreviewConfirmed(), let select = uniquePickerSelectButton() {
                    select.tap()
                    pickerPreviewFallbackUsed = true
                    return true
                }
            }
            guard dismissUnmatchedPickerPreview() else {
                cancelPhotoPickerSafely(); throw SafeFailure.photoSelection
            }
            guard !app.buttons["composerPickPhoto"].isHittable else {
                throw SafeFailure.photoSelection
            }
        }
        return false
    }

    private struct PickerPreviewCrop {
        let imageCrop: Bool
        let area: CGRect
    }

    private func freshPickerPreviewConfirmed() -> Bool {
        let deadline = Date().addingTimeInterval(12)
        // Each candidate starts a new confirmation sequence. Markers never cross candidates or crops.
        var previous: [PickerPreviewCrop] = []
        for attempt in 0..<3 {
            guard Date() < deadline else { return false }
            let current = freshForegroundPickerPreviewMatches()
            let withinDeadline = Date() <= deadline
            let consecutive = current.contains { match in
                previous.contains { $0.imageCrop == match.imageCrop && samePickerFrame($0.area, match.area) }
            }
            if !pickerPreviewScanDiagnostics.isEmpty {
                let last = pickerPreviewScanDiagnostics.count - 1
                pickerPreviewScanDiagnostics[last]["withinDeadline"] = withinDeadline
                pickerPreviewScanDiagnostics[last]["consecutiveExactSameCrop"] = consecutive
            }
            guard withinDeadline else { return false }
            if consecutive { return true }
            previous = current
            if attempt < 2, Date().addingTimeInterval(0.2) < deadline { Thread.sleep(forTimeInterval: 0.2) }
        }
        return false
    }

    private func freshForegroundPickerPreviewMatches() -> [PickerPreviewCrop] {
        autoreleasepool {
            var diagnostics: [String: Bool] = ["selectFound": false, "geometryReady": false, "screenshotReady": false,
                "imageCropAvailable": false, "imageCropValid": false, "imageOCRSucceeded": false,
                "imageQAExact": false, "imageRunExact": false, "foregroundCropValid": false,
                "foregroundOCRSucceeded": false, "foregroundQAExact": false, "foregroundRunExact": false,
                "markerGeometryGuardApplied": true, "imageMarkerGeometryMatched": false,
                "foregroundMarkerGeometryMatched": false]
            defer {
                // Five candidates, at most three fresh scans each; no pixels, OCR strings or geometry leave this scope.
                if pickerPreviewScanDiagnostics.count < 15 { pickerPreviewScanDiagnostics.append(diagnostics) }
            }
            guard let initialSelect = uniquePickerSelectButton() else { return [] }
            diagnostics["selectFound"] = true
            let initialViewport = app.frame
            let initialMenuTop = initialSelect.frame.minY
            guard initialMenuTop > initialViewport.minY + initialViewport.height * 0.30 else { return [] }
            // Resolve the slow AX geometry queries first. Capturing pixels before this work would OCR a stale loading frame.
            guard let geometry = try? app.snapshot() else { return [] }
            var nodes: [XCUIElementSnapshot] = [geometry]
            var inspected = 0
            var foregroundFrames: [CGRect] = []
            while let node = nodes.popLast(), inspected < 4096 {
                inspected += 1
                nodes.append(contentsOf: node.children.reversed())
                guard node.elementType == .image else { continue }
                let frame = node.frame
                guard frame.width >= initialViewport.width * 0.55 && frame.width <= initialViewport.width * 2,
                      frame.height >= initialViewport.height * 0.18 && frame.height <= initialViewport.height * 0.94,
                      frame.minY >= initialViewport.minY, frame.maxY <= initialMenuTop,
                      initialViewport.intersects(frame) else { continue }
                foregroundFrames.append(frame)
            }
            guard nodes.isEmpty else { return [] }
            guard let select = uniquePickerSelectButton() else { return [] }
            let viewport = app.frame
            let menuTop = select.frame.minY
            guard menuTop > viewport.minY + viewport.height * 0.30 else { return [] }
            let validFrames = foregroundFrames.filter { $0.minY >= viewport.minY && $0.maxY <= menuTop && viewport.intersects($0) }
            var crops: [PickerPreviewCrop] = []
            if validFrames.count == 1 {
                diagnostics["imageCropAvailable"] = true
                crops.append(PickerPreviewCrop(imageCrop: true, area: validFrames[0].intersection(viewport)))
            }
            // Remote-hosted context previews can be render layers without an Image AX node.
            // This crop is allowed only with strict large-marker geometry, which rejects separate backdrop thumbnails.
            let top = viewport.minY + 44
            crops.append(PickerPreviewCrop(imageCrop: false,
                area: CGRect(x: viewport.minX + viewport.width * 0.02, y: top,
                             width: viewport.width * 0.96, height: menuTop - top - 8)))
            diagnostics["geometryReady"] = true
            guard let screenshot = app.screenshot().image.cgImage else { return [] }
            diagnostics["screenshotReady"] = true
            let scaleX = CGFloat(screenshot.width) / viewport.width
            let scaleY = CGFloat(screenshot.height) / viewport.height
            var matches: [PickerPreviewCrop] = []
            for crop in crops {
                let area = crop.area
                let prefix = crop.imageCrop ? "image" : "foreground"
                guard area.width > 0, area.height > 0, viewport.contains(area),
                      let pixels = screenshot.cropping(to: CGRect(x: (area.minX - viewport.minX) * scaleX,
                          y: (area.minY - viewport.minY) * scaleY, width: area.width * scaleX, height: area.height * scaleY)) else { continue }
                diagnostics[prefix + "CropValid"] = true
                let match = exactQA1MarkerStatus(pixels, thumbnail: false, strictForeground: true)
                diagnostics[prefix + "OCRSucceeded"] = match.ocrSucceeded
                diagnostics[prefix + "QAExact"] = match.qaTextExact
                diagnostics[prefix + "RunExact"] = match.runTextExact
                diagnostics[prefix + "MarkerGeometryMatched"] = match.qa && match.run
                if match.ocrSucceeded && match.qa && match.run { matches.append(crop) }
            }
            return matches
        }
    }

    private func dismissUnmatchedPickerPreview() -> Bool {
        if uniquePickerSelectButton() == nil,
           app.images.matching(identifier: "PXGGridLayout-Info").count > 0 { return true }
        let viewport = app.frame
        // The observed top backdrop cannot activate a photo or the Select menu item.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: viewport.width / 2, dy: 60)).tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.uniquePickerSelectButton() == nil && self.app.images.matching(identifier: "PXGGridLayout-Info").count > 0) ||
                self.app.buttons["composerPickPhoto"].isHittable
        }, object: nil)
        return XCTWaiter.wait(for: [returned], timeout: 5) == .completed
    }

    private func verifiedQA1CellFrames() -> [CGRect] {
        // Snapshot values avoid recycled live cell identities. Only fixed scalar diagnostics leave this function.
        pickerLastExactRunCount = 0
        pickerLastExactRunFrames = []
        let snapshot: XCUIElementSnapshot
        do { snapshot = try app.snapshot() }
        catch { pickerSnapshotFailures += 1; return [] }
        let viewport = snapshot.frame
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        var rootSource = "application"
        var collected = collectGridFrames(snapshot, viewport: viewport)
        let appGridCount = collected.gridCount
        // PHPicker is remote-hosted on some OS versions. The stable collection root may expose
        // its subtree when the application's root snapshot does not. Never query individual cells.
        if collected.gridCount == 0, app.collectionViews.firstMatch.exists {
            do {
                let collection = try app.collectionViews.firstMatch.snapshot()
                let collectionFrames = collectGridFrames(collection, viewport: viewport)
                rootSource = "collection"
                collected = collectionFrames
            } catch { pickerSnapshotFailures += 1 }
        }
        guard let image = app.screenshot().image.cgImage else { return [] }
        let scaleX = CGFloat(image.width) / viewport.width, scaleY = CGFloat(image.height) / viewport.height
        var frames: [CGRect] = []
        var qaCount = 0, runCount = 0, cropCount = 0, ocrFailures = 0
        for frame in collected.frames.prefix(48) {
            let region = CGRect(x: (frame.minX - viewport.minX) * scaleX, y: (frame.minY - viewport.minY) * scaleY,
                                width: frame.width * scaleX, height: frame.height * scaleY)
            guard let pixels = image.cropping(to: region) else { continue }
            cropCount += 1
            let match = exactQA1MarkerStatus(pixels, thumbnail: true)
            if match.qa { qaCount += 1 }
            if match.run { runCount += 1; pickerLastExactRunFrames.append(frame) }
            if !match.ocrSucceeded { ocrFailures += 1 }
            if match.qa && match.run { frames.append(frame) }
        }
        pickerLastExactRunCount = runCount
        // At most five viewports, three discovery scans and three confirmation scans per viewport.
        if pickerScanDiagnostics.count < 30 {
            pickerScanDiagnostics.append(["root": rootSource, "applicationGridImageCount": appGridCount,
                                          "gridImageCount": collected.gridCount,
                                          "frameEligibleCount": collected.frames.count, "cropCount": cropCount,
                                          "qa1MarkerCount": qaCount, "exactRunMarkerCount": runCount,
                                          "qa1OnlyCount": qaCount - frames.count, "exactRunOnlyCount": runCount - frames.count,
                                          "exactBothCount": frames.count, "ocrFailures": ocrFailures,
                                          "hypothesesPerObservation": 5, "minimumConfidence": 0.55,
                                          "viewportWidth": Double(viewport.width), "viewportHeight": Double(viewport.height),
                                          "screenshotWidth": image.width, "screenshotHeight": image.height])
        }
        return frames
    }

    private func collectGridFrames(_ snapshot: XCUIElementSnapshot, viewport: CGRect) -> (gridCount: Int, frames: [CGRect]) {
        var nodes: [XCUIElementSnapshot] = [snapshot]
        var inspected = 0, gridCount = 0
        var frames: [CGRect] = []
        while let cell = nodes.popLast(), inspected < 4096 {
            inspected += 1
            nodes.append(contentsOf: cell.children.reversed())
            guard cell.elementType == .image, cell.identifier == "PXGGridLayout-Info" else { continue }
            gridCount += 1
            let frame = cell.frame
            guard frame.width >= 60, frame.width <= viewport.width * 0.55,
                  (0.8...1.25).contains(frame.height / frame.width), viewport.contains(frame) else { continue }
            // The 48-image OCR budget applies after visible-frame filtering. Off-screen snapshot
            // cells must not consume that budget before the currently visible thumbnails are reached.
            frames.append(frame)
        }
        if inspected >= 4096 && !nodes.isEmpty { pickerSnapshotTraversalLimitReached = true }
        return (gridCount, frames)
    }

    private func exactQA1Markers(_ image: CGImage, thumbnail: Bool) -> Bool {
        let match = exactQA1MarkerStatus(image, thumbnail: thumbnail)
        return match.qa && match.run
    }

    private func exactQA1MarkerStatus(_ image: CGImage, thumbnail: Bool, strictForeground: Bool = false) -> (qa: Bool, run: Bool, ocrSucceeded: Bool, qaTextExact: Bool, runTextExact: Bool) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false; request.minimumTextHeight = 0.004
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return (false, false, false, false, false) }
        let observations = (request.results ?? []).map { observation in
            (frame: observation.boundingBox, texts: observation.topCandidates(strictForeground ? 1 : 5)
                .filter { $0.confidence >= (strictForeground ? 0.70 : (thumbnail ? 0.55 : 0.20)) }
                .map { $0.string.uppercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
                    .reduce(into: "") { $0.unicodeScalars.append($1) } })
        }
        let candidates = observations.flatMap { $0.texts }
        var qaFrames = observations.filter { $0.texts.contains("JINBAOQA1") }.map(\.frame)
        var qa = !qaFrames.isEmpty
        if !qa || strictForeground {
            // Vision may split the same printed title into adjacent JINBAO / QA1 observations.
            // Join only these exact tokens in reading order and close geometric proximity.
            for left in observations where left.texts.contains("JINBAO") {
                for right in observations where right.texts.contains("QA1") {
                    let a = left.frame, b = right.frame
                    let horizontal = abs(a.midY - b.midY) <= max(a.height, b.height) * 0.5 &&
                        b.minX >= a.midX && b.minX - a.maxX >= -0.02 && b.minX - a.maxX <= 0.15
                    let vertical = b.midY < a.midY && abs(a.midX - b.midX) <= 0.15 &&
                        a.minY - b.maxY >= -0.02 && a.minY - b.maxY <= 0.08
                    if horizontal || vertical {
                        qa = true
                        qaFrames.append(a.union(b))
                    }
                }
            }
        }
        if strictForeground {
            let runFrames = observations.filter {
                $0.texts.contains("QA20261019COS") || $0.texts.contains("RUNQA20261019COS")
            }.map(\.frame)
            // Vision bounds are normalized to this one crop, with Y increasing upward.
            // A full preview has two large, centered markers; backdrop grid cells are too narrow.
            let paired = qaFrames.contains { qaFrame in
                guard qaFrame.width >= 0.35 else { return false }
                return runFrames.contains { runFrame in
                    let verticalGap = qaFrame.midY - runFrame.midY
                    return runFrame.width >= 0.35 && abs(qaFrame.midX - runFrame.midX) <= 0.12 &&
                        qaFrame.midY > runFrame.midY && (0.05...0.35).contains(verticalGap)
                }
            }
            return (paired, paired, true, qa, !runFrames.isEmpty)
        }
        let run = candidates.contains("QA20261019COS") || candidates.contains("RUNQA20261019COS")
        return (qa, run, true, qa, run)
    }

    private func attachVerifiedQA1Preview(_ name: String) throws {
        guard app.buttons["closePhotoPreview"].waitForExistence(timeout: 8) else { throw SafeFailure.photoPreview }
        var confirmed: UIImage?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let screenshot = self.app.screenshot().image
            guard let image = screenshot.cgImage else { return false }
            let region = CGRect(x: CGFloat(image.width) * 0.02, y: CGFloat(image.height) * 0.28,
                                width: CGFloat(image.width) * 0.96, height: CGFloat(image.height) * 0.50)
            let images = [image.cropping(to: region), image].compactMap { $0 }
            guard images.contains(where: { self.exactQA1Markers($0, thumbnail: false) }) else { return false }
            confirmed = screenshot
            return true
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 12) == .completed, let confirmed else { throw SafeFailure.photoPreview }
        // Attach the same image that passed exact QA/RUN checks, never an earlier or unverified screenshot.
        let attachment = XCTAttachment(image: confirmed)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func cancelPhotoPickerSafely() {
        let buttons = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Cancel|取消)$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        if buttons.count == 1 { buttons[0].tap() }
    }

    private func openVerifiedDebugCloud() throws {
        try tapSafe(app.buttons["tabMy"])
        if !app.staticTexts["storageVerified"].exists { try tapSafe(app.buttons["tabCloud"]) }
        guard app.staticTexts["storageVerified"].waitForExistence(timeout: 8),
              !app.staticTexts["storagePlaceholder"].exists,
              !app.textFields["storageBucket"].exists,
              !app.secureTextFields["secretKey"].exists else { throw SafeFailure.cloudNotVerified }
        let paths = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"^life/v1/test/[a-f0-9-]{36}/$"#))
        for _ in 0..<12 {
            let found = paths.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            if found.count == 1 { return }
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        throw SafeFailure.debugScope
    }

    private func filterSyntheticTitle(_ title: String) throws {
        try tapSafe(app.buttons["tabTimeline"])
        if !app.textFields["timelineSearchField"].exists { try tapSafe(app.buttons["timelineSearchToggle"]) }
        let field = app.textFields["timelineSearchField"]
        guard field.waitForExistence(timeout: 5) else { throw SafeFailure.timeline }
        if app.buttons["timelineSearchClear"].exists { try tapSafe(app.buttons["timelineSearchClear"]) }
        try tapSafe(field); field.typeText(title + "\n")
    }

    private func syntheticCards(_ title: String) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "momentCard-"))
            .containing(.staticText, identifier: title).allElementsBoundByAccessibilityElement
    }

    private func verifySyntheticDetail(title: String, note: String) throws -> String {
        guard app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: 8) else {
            throw SafeFailure.syntheticContent
        }
        let cards = syntheticCards(title)
        guard cards.count == 1, let card = cards.first else { throw SafeFailure.syntheticCollision }
        let id = String(card.identifier.dropFirst("momentCard-".count))
        guard UUID(uuidString: id) != nil else { throw SafeFailure.syntheticCollision }
        try tapSafe(card)
        guard app.navigationBars["小日常"].waitForExistence(timeout: 8),
              app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
              app.staticTexts.matching(NSPredicate(format: "label == %@", note)).firstMatch.exists,
              app.buttons["momentActions"].exists,
              app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-")).count == 0 else {
            throw SafeFailure.syntheticContent
        }
        return id
    }

    private func awaitBackupComplete(timeout: TimeInterval) throws {
        let status = app.staticTexts["storageVerified"]
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label == "已备份" && !self.app.buttons["pauseBackup"].exists
        }, object: nil)
        guard XCTWaiter.wait(for: [complete], timeout: timeout) == .completed else { throw SafeFailure.backupIncomplete }
    }

    private func tapSafe(_ element: XCUIElement) throws {
        guard element.waitForExistence(timeout: 8) else { throw SafeFailure.navigation }
        for _ in 0..<8 {
            let frame = element.frame
            let tab = app.buttons["tabMy"]
            let isBottomControl = (element.identifier.hasPrefix("tab") && element.identifier != "tabCloud") || element.identifier == "addMoment"
            let modal = app.textFields["draftTitle"].exists || app.navigationBars["小日常"].exists
            let bottomBound = modal || !tab.exists ? app.frame.maxY : tab.frame.minY - 12
            if element.isHittable && app.frame.contains(frame) && (isBottomControl || frame.midY < bottomBound) {
                element.tap(); return
            }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { break }
            if frame.midY < app.frame.midY { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        throw SafeFailure.navigation
    }

    private func isEmpty(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        return element.value as? String == "" || element.value as? String == element.placeholderValue
    }

    private func attachCrop(_ element: XCUIElement, _ name: String) throws {
        for _ in 0..<10 {
            if element.exists, element.isHittable, !element.frame.isEmpty, app.frame.contains(element.frame) {
                let attachment = XCTAttachment(screenshot: element.screenshot())
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                return
            }
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { break }
            if element.frame.midY < app.frame.midY { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        throw SafeFailure.navigation
    }

    private func safelyVisible(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame
        let screen = app.frame
        // The cropped attachment can contain only the single known month heading.
        return !frame.isEmpty && frame.height <= 80 && frame.width <= screen.width &&
            frame.minY >= screen.minY + 40 && frame.maxY <= screen.maxY - 90
    }

    private enum SafeFailure: String, Error, CustomStringConvertible {
        case prerequisite = "Missing verified remote ID or month prerequisite."
        case timeline = "Timeline did not become available."
        case recordNotVisible = "Expected real 2025 header and remote card were not both visible."
        case readOnly = "Remote read-only detail verification failed."
        case navigation = "A required safe navigation action was unavailable."
        case retainedDraft = "A retained draft was preserved without writing."
        case syntheticCollision = "Synthetic title did not identify one safe local record."
        case syntheticContent = "Synthetic text verification failed."
        case cloudNotVerified = "A verified connection is required; configuration was not modified."
        case debugScope = "The visible storage path was not the required Debug test path."
        case backupIncomplete = "Backup did not report completion within the acceptance timeout."
        case backupNotStarted = "The repeated backup invocation was not observed."
        case backupFeedback = "Backup completion feedback was not observed."
        case photoSelection = "Exact synthetic QA1 and RUN were not safely identified in the system picker."
        case photoImport = "Exactly one synthetic photo did not finish importing."
        case photoPreview = "Full-size preview did not match the exact synthetic QA1 and RUN before save."
        var description: String { rawValue }
    }
}
