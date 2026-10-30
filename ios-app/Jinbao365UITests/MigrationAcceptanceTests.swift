import Photos
import ImageIO
import XCTest
import UIKit
import Vision

/// Additive device acceptance. Only run-specific synthetic fixtures and newly created QA records are edited.
/// A missing prerequisite fails visibly; no required scenario is silently skipped.
@MainActor
final class MigrationAcceptanceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.henrypann.jinbao365")
    private var fixtureRun: String { ProcessInfo.processInfo.environment["JINBAO_MIGRATION_RUN_ID"] ?? "QA20261019MIGRATE" }

    override func setUpWithError() throws { continueAfterFailure = false }

    func test00SeedSyntheticMedia() async throws {
        let fixture = PhotoFixture(runID: fixtureRun, fullMedia: true, automaticAddRequested: false)
        if fixture.addedCount != 4 {
            let seeding = Task { await fixture.addPhotos() }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deadline = Date().addingTimeInterval(120)
            var allowedExpectedPrompt = false
            while Date() < deadline {
                if fixture.addedCount == 4 && !fixture.busy { break }
                if !fixture.busy && fixture.status.hasPrefix("Full media creation failed:") { break }
                if !fixture.busy && fixture.status.hasPrefix("Photo access was not granted.") { break }
                let alert = springboard.alerts.firstMatch
                if alert.exists, !allowedExpectedPrompt, isExpectedAddOnlyPrompt(alert) {
                    let labels = ["Allow Photos to Be Added", "Allow Adding Photos", "允许添加照片", "允许添加", "允许", "Allow", "OK", "好"]
                    for label in labels {
                        let buttons = alert.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
                        if buttons.count == 1 { buttons[0].tap(); allowedExpectedPrompt = true; break }
                    }
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !fixture.busy, fixture.addedCount == 4 else {
                seeding.cancel()
                throw AcceptanceFailure("Runner synthetic seeding did not finish: \(fixture.status). No existing photo was read or deleted.")
            }
            await seeding.value
        }
        let summary = try fixture.verifiedFullMediaSummary()
        let attachment = XCTAttachment(string: String(decoding: summary, as: UTF8.self))
        attachment.name = "M00 runner synthetic-only fixture manifest and verified SHA-256"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(fixture.addedCount, 4)
    }

    private func isExpectedAddOnlyPrompt(_ alert: XCUIElement) -> Bool {
        // Only inspect the system alert locally. No unrelated alert, photo labels or OCR text are retained.
        let text = ([alert.label] + alert.staticTexts.allElementsBoundByAccessibilityElement.map(\.label)).joined(separator: " ").lowercased()
        let namesRunner = text.contains("jinbao") || text.contains("孩子") || text.contains("runner") || text.contains("uitests")
        let addsPhotos = (text.contains("添加") && text.contains("照片")) || (text.contains("add") && text.contains("photo"))
        return namesRunner && addsPhotos
    }

    private func requireSyntheticFixtures() throws {
        let fixture = PhotoFixture(runID: fixtureRun, fullMedia: true, automaticAddRequested: false)
        _ = try fixture.verifiedFullMediaSummary()
    }

    func test00ResumeInterruptedPhotoDraft() throws {
        try startOffline(allowPendingDraft: true)
        let resume = app.buttons["timelineResumeDraft"]
        guard resume.exists else {
            attachText("interruptedPhotoDraftPresent=false; recoveryRequired=false; pickerOrPhotoAcceptanceClaimed=false", "R00 recovery prerequisite")
            return
        }
        try requireSyntheticFixtures()
        try tap(resume)
        let field = app.textFields["draftTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let title = field.value as? String ?? ""
        let prefix = "Jinbao migration QA photos "
        let note = app.descendants(matching: .any)["draftNote"].firstMatch
        let noteValue = note.value as? String ?? ""
        guard title.hasPrefix(prefix), UUID(uuidString: String(title.dropFirst(prefix.count))) != nil,
              noteValue.isEmpty || noteValue == note.placeholderValue,
              app.navigationBars.staticTexts["记录小日常"].exists,
              app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == 2,
              !app.staticTexts["photoImportFailure"].exists else {
            throw AcceptanceFailure("The retained draft is not the two-photo synthetic scenario. It was not changed, discarded, or saved.")
        }
        attachText("pickerExecutedThisTest=false; resumedPreviousSuccessfulSystemPickerImport=true; expectedRun=\(fixtureRun); requiredLogicalAssets=2; bothFullSizeImagesAndRestartMustStillPass=true", "R01 interrupted synthetic import provenance")
        try verifySaveRestartTwoPhotos(title: title)
    }

    func test01FourTabsDraftEditTrashAndSettings() throws {
        try startOffline(allowPendingDraft: true)
        let note = "Synthetic migration acceptance. No personal content."
        let title: String
        let resume = app.buttons["timelineResumeDraft"]
        if resume.exists {
            try tap(resume)
            let field = app.textFields["draftTitle"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            let existingTitle = field.value as? String ?? ""
            let prefix = "Jinbao migration QA text "
            guard existingTitle.hasPrefix(prefix),
                  UUID(uuidString: String(existingTitle.dropFirst(prefix.count))) != nil,
                  app.descendants(matching: .any)["draftNote"].firstMatch.value as? String == note,
                  app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == 0,
                  app.navigationBars.staticTexts["记录小日常"].exists else {
                throw AcceptanceFailure("The existing draft is not the interrupted synthetic text scenario. It was retained without changing or discarding it.")
            }
            title = existingTitle
        } else {
            title = "Jinbao migration QA text \(UUID().uuidString)"
            try beginText()
            try typeNewTitle(title)
            app.descendants(matching: .any)["draftNote"].firstMatch.tap()
            app.descendants(matching: .any)["draftNote"].firstMatch.typeText(note)
        }
        dismissKeyboard()
        screenshot(app, "M01 synthetic text draft with date and time")
        app.navigationBars.buttons["关闭"].tap()
        try tap(app.buttons["保留草稿并关闭"])
        XCTAssertTrue(app.buttons["timelineResumeDraft"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["timelineResumeDraft"].waitForExistence(timeout: 10), "The retained draft must remain available after relaunch.")
        try tap(app.buttons["timelineResumeDraft"])
        XCTAssertTrue(app.textFields["draftTitle"].waitForExistence(timeout: 5), "Continue the persisted draft through its visible entry.")
        XCTAssertEqual(app.textFields["draftTitle"].value as? String, title)
        XCTAssertEqual(app.descendants(matching: .any)["draftNote"].firstMatch.value as? String, note)
        try tap(app.buttons["saveDraft"])
        let recordID = try openSyntheticRecord(title)
        XCTAssertTrue(app.staticTexts[note].exists)
        screenshot(app, "M02 saved synthetic text after draft relaunch")
        try openMomentActions()
        try tap(app.buttons["editMoment"])
        let field = app.textFields["draftTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, title)
        let editedTitle = try insertVerifiedSyntheticEdit(field, expected: title)
        dismissKeyboard()
        try tap(app.buttons["saveDraft"])
        app.terminate(); app.launch()
        try openSyntheticRecord(editedTitle)
        screenshot(app, "M03 edited record persisted after relaunch")
        try openMomentActions()
        try tap(app.buttons["trashMoment"])
        try tap(app.buttons["移到回收站"].firstMatch)
        try tap(app.buttons["tabMy"])
        screenshot(app, "M04 My archive overview")
        try tap(app.buttons["openSettings"])
        screenshot(app, "M05 settings connection and original download policy")
        let cellular = app.switches["allowCellularOriginals"]
        try reveal(cellular)
        let original = cellular.value as? String
        guard original == "0" || original == "1" else { throw AcceptanceFailure("The current download policy could not be read; it was retained.") }
        try setSwitch(cellular, to: original == "0" ? "1" : "0")
        try setSwitch(cellular, to: original!)
        try tap(app.buttons["openTrash"])
        XCTAssertTrue(app.staticTexts[editedTitle].waitForExistence(timeout: 5))
        let button = app.buttons["restoreMoment-\(recordID)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Restore must refer to the same unique record that this test saved.")
        screenshot(app, "M06 recoverable synthetic record in trash")
        try tap(button)
        XCTAssertFalse(app.staticTexts[editedTitle].exists)
        app.terminate(); app.launch()
        try openSyntheticRecord(editedTitle)
        screenshot(app, "M07 restored synthetic record after relaunch")
        try tap(app.navigationBars.buttons["关闭"])
        try filterTimeline("Jinbao migration QA")
        screenshot(app, "M08 four-tab timeline filtered to migration QA")
        try tap(app.buttons["tabReview"])
        screenshot(app.navigationBars.firstMatch, "M09 Review tab title")
        let months = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reviewMonth-"))
        XCTAssertTrue(months.firstMatch.waitForExistence(timeout: 5))
        try tap(months.firstMatch)
        XCTAssertTrue(app.navigationBars.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "年", "月")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app.navigationBars.firstMatch, "M10 month review drilldown includes year")
        try tap(app.buttons["tabAnniversaries"])
        screenshot(app.navigationBars.firstMatch, "M11 Anniversary tab title")
        try tap(app.buttons["tabMy"])
        // Navigate from My's retained settings stack by restarting, without resetting app data.
        app.terminate(); app.launch()
        try tap(app.buttons["tabMy"])
        try tap(app.buttons["tabCloud"])
        XCTAssertTrue(app.staticTexts["storagePlaceholder"].waitForExistence(timeout: 5))
        screenshot(app.staticTexts["storagePlaceholder"], "M12 cloud placeholder is explicitly local only")
    }

    func test02AnniversaryNoYearCreateEditDelete() throws {
        try startOffline(allowPendingDraft: true)
        let title = "Jinbao migration QA anniversary \(UUID().uuidString)"
        try tap(app.buttons["tabAnniversaries"])
        try tap(app.buttons["addAnniversary"])
        let name = app.textFields["anniversaryTitle"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        dismissKeyboard()
        let year = app.switches["anniversaryYearKnown"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        try setSwitch(year, to: "0")
        screenshot(app, "M13 synthetic anniversary with optional year disabled")
        try tap(app.buttons["saveAnniversary"])
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        try tap(app.buttons["tabAnniversaries"])
        try tap(app.staticTexts[title])
        XCTAssertEqual(app.switches["anniversaryYearKnown"].value as? String, "0")
        let editedTitle = try insertVerifiedSyntheticEdit(name, expected: title)
        dismissKeyboard()
        try tap(app.buttons["saveAnniversary"])
        try tap(app.staticTexts[editedTitle])
        screenshot(app, "M14 edited yearless anniversary persisted")
        try tap(app.buttons["deleteAnniversary"])
        try tap(app.buttons["删除"].firstMatch)
        XCTAssertFalse(app.staticTexts[editedTitle].exists)
        app.terminate(); app.launch()
        try tap(app.buttons["tabAnniversaries"])
        XCTAssertFalse(app.staticTexts[editedTitle].exists, "Deleted synthetic anniversary must stay hidden after relaunch.")
    }

    func test03SystemPickerTwoPhotosAutoDateSaveAndRestart() throws {
        try requireSyntheticFixtures()
        try startOffline()
        let title = "Jinbao migration QA photos \(UUID().uuidString)"
        try beginText(); try typeNewTitle(title); dismissKeyboard()
        try tap(app.buttons["composerPickPhoto"])
        // Select the later photo first: record time must still be the earlier 10:30 capture.
        try selectVerifiedFixtures([2, 1])
        try verifySaveRestartTwoPhotos(title: title)
    }

    private func verifySaveRestartTwoPhotos(title: String) throws {
        try waitForImportedAssets(2)
        try assertImportedDateAndTime()
        let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).allElementsBoundByAccessibilityElement
        XCTAssertEqual(buttons.count, 2)
        for (index, number) in [2, 1].enumerated() {
            try reveal(buttons[index]); buttons[index].tap()
            XCTAssertTrue(app.buttons["closePhotoPreview"].waitForExistence(timeout: 5))
            try waitForVerifiedFullScreen(number: number)
            screenshot(app, "M15 full-size draft QA \(number)")
            try tap(app.buttons["closePhotoPreview"])
        }
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        try tap(app.buttons["saveDraft"])
        app.terminate(); app.launch()
        try openSyntheticRecord(title)
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        XCTAssertEqual(previews.count, 2)
        try tap(previews.firstMatch)
        try waitForVerifiedFullScreen(number: 2)
        screenshot(app, "M16 persisted two-photo gallery first image")
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars.staticTexts["2 / 2"].waitForExistence(timeout: 5))
        try waitForVerifiedFullScreen(number: 1)
        screenshot(app, "M17 persisted two-photo gallery second image")
        try tap(app.buttons["closePhotoPreview"])
        screenshot(app, "M18 persisted two-photo detail")
        try tap(app.navigationBars.buttons["关闭"])
    }

    func test04VideoAndLivePhotoSavePlaybackAndRestart() throws {
        try requireSyntheticFixtures()
        try startOffline()
        let title = "Jinbao migration QA motion \(UUID().uuidString)"
        try beginText(); try typeNewTitle(title); dismissKeyboard()
        try tap(app.buttons["composerPickPhoto"])
        try selectVerifiedFixtures([3, 4])
        try waitForImportedAssets(2)
        try tap(app.buttons["saveDraft"])
        app.terminate(); app.launch()
        try openSyntheticRecord(title)
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        XCTAssertEqual(previews.count, 2, "A Live Photo must count as one logical media item.")
        try tap(previews.element(boundBy: 0))
        let play = app.buttons["videoTogglePlayback"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Video requires a real playback control.")
        try waitForVerifiedFullScreen(number: 3)
        if play.value as? String != "播放中" { play.tap() }
        let videoPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "播放中"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [videoPlaying], timeout: 5), .completed)
        screenshot(app, "M19 synthetic video playing")
        let time = app.descendants(matching: .any)["videoPlaybackTime"].firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = time.label.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { return false }
            return parts[0] * 60 + parts[1] >= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 6), .completed, "Real player time must advance.")
        screenshot(app, "M20 synthetic video playback advanced")
        app.swipeLeft()
        let live = app.buttons["playLivePhoto"]
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        try waitForVerifiedFullScreen(number: 4)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: live)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Both Live Photo resources must resolve into a playable pair.")
        let playing = app.staticTexts["livePhotoPlaybackStatus"]
        XCTAssertTrue(playing.waitForExistence(timeout: 5), "Live Photo must expose its actual delegate playback state.")
        live.tap()
        let livePlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "播放中"), object: playing)
        XCTAssertEqual(XCTWaiter.wait(for: [livePlaying], timeout: 4), .completed)
        screenshot(app, "M21 synthetic Live Photo delegate-confirmed playback")
        try tap(app.buttons["closePhotoPreview"])
        screenshot(app, "M22 persisted video and Live Photo detail")
        try tap(app.navigationBars.buttons["关闭"])
    }

    func test05FourTabScreensCloudFeedbackAndEntryCancellation() throws {
        try startOffline()
        // Reset navigation stacks only; retain all records and the checked placeholder connection.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 10))
        guard !app.buttons["timelineResumeDraft"].exists, !app.textFields["draftTitle"].exists else {
            throw AcceptanceFailure("Entry cancellation requires no pre-existing draft. Existing draft was retained without edits.")
        }
        for (id, name) in [("tabTimeline", "时光"), ("tabAnniversaries", "纪念"), ("tabReview", "回顾"), ("tabMy", "我的")] {
            try test05Tap(app.buttons[id])
            screenshot(app, "T05 full device tab — \(name)")
            if id == "tabReview" {
                let month = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reviewMonth-")).firstMatch
                try test05Tap(month)
                XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "年", "月")).firstMatch.waitForExistence(timeout: 5))
                screenshot(app, "T05 full year-month review page")
                try test05Tap(app.navigationBars.buttons["回顾"].firstMatch)
            }
        }
        try test05Tap(app.buttons["tabCloud"])
        guard app.descendants(matching: .any)["storagePlaceholder"].firstMatch.waitForExistence(timeout: 5),
              !app.staticTexts["storageVerified"].exists,
              test05CredentialIsEmpty("secretID"), test05CredentialIsEmpty("secretKey") else {
            throw AcceptanceFailure("Cloud feedback requires placeholder and empty credentials. No credential or connection change was attempted.")
        }
        if app.buttons["隐藏密钥编号"].exists { try test05Tap(app.buttons["隐藏密钥编号"]) }
        XCTAssertTrue(app.secureTextFields["secretID"].exists)
        try test05Tap(app.buttons["显示密钥编号"])
        XCTAssertTrue(app.textFields["secretID"].waitForExistence(timeout: 5))
        try test05Tap(app.buttons["隐藏密钥编号"])
        XCTAssertTrue(app.secureTextFields["secretID"].waitForExistence(timeout: 5))
        guard test05CredentialIsEmpty("secretID"), test05CredentialIsEmpty("secretKey") else {
            throw AcceptanceFailure("Credential state changed; verification was not invoked.")
        }
        try test05Tap(app.buttons["verifyContinue"])
        let message = app.staticTexts["connectionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(message.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(message.label.contains("占位"), "Empty credentials must show the actual local validation failure.")
        screenshot(app, "T05 cloud empty-credential error feedback")
        try test05Tap(app.buttons["placeholderConnect"])
        let placeholderFeedback = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "占位"), object: message)
        XCTAssertEqual(XCTWaiter.wait(for: [placeholderFeedback], timeout: 5), .completed)
        screenshot(app, "T05 cloud placeholder action feedback")
        try test05Tap(app.navigationBars.buttons["我的"].firstMatch)
        try test05Tap(app.buttons["openSettings"])
        try test05Tap(app.buttons["importFiles"])
        // No screenshot or enumeration of the system document browser's private list.
        try test05CancelSystemPicker(context: "document")
        try test05AssertEmptyOwnedDraft()
        let syntheticTitle = "Jinbao migration QA cancellation \(UUID().uuidString)"
        let syntheticNote = "Synthetic entry cancellation check. No personal content."
        let titleField = app.textFields["draftTitle"]
        titleField.tap(); titleField.typeText(syntheticTitle)
        let body = app.descendants(matching: .any)["draftNote"].firstMatch
        body.tap(); body.typeText(syntheticNote)
        dismissKeyboard()
        screenshot(app, "T05 owned synthetic draft survives document-picker cancellation")
        try test05Tap(app.navigationBars.buttons["关闭"].firstMatch)
        try test05Tap(app.buttons["保留草稿并关闭"].firstMatch)
        try test05Tap(app.buttons["tabTimeline"])
        XCTAssertTrue(app.buttons["timelineResumeDraft"].waitForExistence(timeout: 5))
        try test05Tap(app.buttons["addMoment"])
        try test05Tap(app.buttons["addPhotosMenuAction"])
        // Only cancel. Never inspect or select any system-library image in this test.
        try test05CancelSystemPicker(context: "photo")
        XCTAssertEqual(app.textFields["draftTitle"].value as? String, syntheticTitle)
        XCTAssertEqual(app.descendants(matching: .any)["draftNote"].firstMatch.value as? String, syntheticNote)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count, 0)
        screenshot(app, "T05 synthetic draft remains unchanged after plus-picker cancellation")
        try test05Tap(app.navigationBars.buttons["关闭"].firstMatch)
        try test05Tap(app.buttons["放弃草稿"].firstMatch)
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["timelineResumeDraft"].exists, "Only this test's newly created synthetic draft was explicitly discarded.")
        attachText("filePickerOpened=true; filePickerCancelled=true; plusPhotoPickerOpened=true; plusPhotoPickerCancelled=true; mediaSelected=false; syntheticDraftPreservedAcrossCancel=true; syntheticDraftDiscardedThroughUI=true; preexistingDraftModified=false; cloudCredentialSubmission=emptyLocalValidationOnly; cloudConnection=placeholder", "T05 entry-cancellation and cloud-feedback results")
    }

    func test06ManualDateAppendReorderRemoveSaveAndRestart() throws {
        try requireSyntheticFixtures()
        try startOffline()
        let title = "Jinbao migration QA editmedia \(UUID().uuidString)"
        let note = "Synthetic manual-date and media-edit acceptance."
        try beginText(); try typeNewTitle(title)
        let body = app.descendants(matching: .any)["draftNote"].firstMatch
        try tap(body); body.typeText(note); dismissKeyboard()
        try tap(app.buttons["composerPickPhoto"])
        try selectVerifiedFixtures([1])
        try waitForImportedAssets(1)
        try assertImportedDateAndTime()
        do {
            try test06SetNativeDateToOctober18()
            try test06SetNativeTimeTo0915()
            try test06AssertManualDateAndTime()
        } catch {
            screenshot(app, "T06 native date-time interaction failed — retained synthetic editor")
            throw error
        }
        screenshot(app, "T06 manually selected October18 09h15 before append")
        try tap(app.buttons["composerPickPhoto"])
        try selectVerifiedFixtures([2])
        try waitForImportedAssets(2)
        try test06AssertManualDateAndTime()
        screenshot(app, "T06 appended later capture without overwriting manual date-time")
        let previewQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-"))
        let original = previewQuery.allElementsBoundByAccessibilityElement
        guard original.count == 2 else { throw AcceptanceFailure("The new synthetic media editor did not contain exactly two items.") }
        let firstID = original[0].identifier, secondID = original[1].identifier
        for (index, number) in [1, 2].enumerated() {
            try tap(original[index]); try waitForVerifiedFullScreen(number: number)
            try tap(app.buttons["closePhotoPreview"])
        }
        try tap(app.buttons["后移第1项媒体"].firstMatch)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            previewQuery.allElementsBoundByAccessibilityElement.map(\.identifier) == [secondID, firstID]
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed, "The real media order must change.")
        let reorderedButtons = previewQuery.allElementsBoundByAccessibilityElement
        try tap(reorderedButtons[0]); try waitForVerifiedFullScreen(number: 2)
        try tap(app.buttons["closePhotoPreview"])
        let removedAsset = String(firstID.dropFirst("draftPreview-".count))
        guard UUID(uuidString: removedAsset) != nil else { throw AcceptanceFailure("The new synthetic asset could not be uniquely identified for removal.") }
        try tap(app.buttons["removeDraftAsset-\(removedAsset)"])
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            previewQuery.count == 1 && previewQuery.firstMatch.identifier == secondID
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        try test06AssertManualDateAndTime()
        screenshot(app, "T06 reordered and removed only the new QA1 attachment")
        try tap(app.buttons["saveDraft"])
        app.terminate(); app.launch()
        try openSyntheticRecord(title)
        XCTAssertTrue(app.staticTexts[note].exists)
        let date = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "2026年10月18日", "09:15")).firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 5), "The manually selected date and time must survive save and restart.")
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        XCTAssertEqual(details.count, 1)
        screenshot(app, "T06 saved manual date-time and single remaining media after restart")
        try tap(details.firstMatch); try waitForVerifiedFullScreen(number: 2)
        screenshot(app, "T06 remaining QA2 original after reorder removal save and restart")
        try tap(app.buttons["closePhotoPreview"])
        try tap(app.navigationBars.buttons["关闭"].firstMatch)
        attachText("newSyntheticRecordOnly=true; firstImport=QA1; manualDate=2026-10-18; manualTime=09:15; append=QA2; manualTimePreserved=true; reordered=true; removed=QA1; remainingAfterRestart=QA2; cloudActionsTested=false", "T06 media editor regression result")
    }

    func test06RResumeExactManualDateDraftAppendReorderRemoveAndRestart() throws {
        try requireSyntheticFixtures()
        try startOffline(allowPendingDraft: true)
        let title = "Jinbao migration QA editmedia 1DBB608D-96D2-4953-ADAE-B23E9C4A9358"
        let note = "Synthetic manual-date and media-edit acceptance."
        let expectedAssetID = "496A01E4-90BB-4838-9643-FC25B20B3156"
        guard fixtureRun == "QA20261019MIGRATE", app.buttons["timelineResumeDraft"].exists else {
            throw AcceptanceFailure("The exact R5 interrupted synthetic draft is unavailable; no other draft was created or edited.")
        }
        try tap(app.buttons["timelineResumeDraft"])
        let field = app.textFields["draftTitle"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-"))
        guard field.value as? String == title,
              app.descendants(matching: .any)["draftNote"].firstMatch.value as? String == note,
              previews.count == 1, previews.firstMatch.identifier == "draftPreview-" + expectedAssetID,
              app.navigationBars.staticTexts["记录小日常"].exists else {
            throw AcceptanceFailure("The retained draft does not exactly match R5's title, note and sole synthetic asset. Nothing was changed, discarded or saved.")
        }
        try reveal(app.descendants(matching: .any)["draftDate"].firstMatch)
        let date = test06Observed("draftDate")
        guard date.contains("2026"), date.contains("18"), date.contains("10月") || date.localizedCaseInsensitiveContains("oct") else {
            throw AcceptanceFailure("The retained R5 draft no longer shows the already-selected October18 date.")
        }
        try tap(previews.firstMatch); try waitForVerifiedFullScreen(number: 1)
        try tap(app.buttons["closePhotoPreview"])
        attachText("recoveredExactR5Draft=true; pickerImportAndOctober18SelectionCompletedInPriorRun=true; expectedRun=QA20261019MIGRATE; expectedInitialMedia=QA1; priorManualDateRetained=true", "T06R exact interrupted-stage provenance")
        do {
            try test06SetNativeTimeTo0915()
            try test06AssertManualDateAndTime()
        } catch {
            screenshot(app, "T06R native time interaction failed — exact retained synthetic draft")
            throw error
        }
        screenshot(app, "T06R recovered October18 draft manually changed to 09h15")
        try tap(app.buttons["composerPickPhoto"])
        try selectVerifiedFixtures([2]); try waitForImportedAssets(2)
        try test06AssertManualDateAndTime()
        let original = previews.allElementsBoundByAccessibilityElement
        guard original.count == 2, original[0].identifier == "draftPreview-" + expectedAssetID else {
            throw AcceptanceFailure("The recovery append did not retain QA1 in its original first position.")
        }
        let qa1ID = original[0].identifier, qa2ID = original[1].identifier
        try tap(original[1]); try waitForVerifiedFullScreen(number: 2)
        try tap(app.buttons["closePhotoPreview"])
        screenshot(app, "T06R QA2 appended without changing manual date-time")
        try tap(app.buttons["后移第1项媒体"].firstMatch)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            previews.allElementsBoundByAccessibilityElement.map(\.identifier) == [qa2ID, qa1ID]
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        try tap(previews.firstMatch); try waitForVerifiedFullScreen(number: 2)
        try tap(app.buttons["closePhotoPreview"])
        try tap(app.buttons["removeDraftAsset-" + expectedAssetID])
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in previews.count == 1 && previews.firstMatch.identifier == qa2ID }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        try test06AssertManualDateAndTime()
        screenshot(app, "T06R real reorder and QA1 removal with manual date-time retained")
        try tap(app.buttons["saveDraft"])
        app.terminate(); app.launch()
        try openSyntheticRecord(title)
        XCTAssertTrue(app.staticTexts[note].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "2026年10月18日", "09:15")).firstMatch.waitForExistence(timeout: 5))
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        XCTAssertEqual(details.count, 1)
        screenshot(app, "T06R manual date-time and single media persisted after restart")
        try tap(details.firstMatch); try waitForVerifiedFullScreen(number: 2)
        screenshot(app, "T06R QA2 zoom baseline — exact synthetic run verified")
        // The verified 4:3 fixture occupies the viewer's center. Deliver real gestures,
        // but leave the before/after pixel evidence for independent visual acceptance.
        app.doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        screenshot(app, "T06R QA2 after real double-tap zoom — visual review required")
        app.pinch(withScale: 1.25, velocity: 1)
        Thread.sleep(forTimeInterval: 0.5)
        screenshot(app, "T06R QA2 after real pinch zoom — visual review required")
        XCTAssertTrue(app.buttons["closePhotoPreview"].exists)
        XCTAssertTrue(app.buttons["closePhotoPreview"].isHittable, "The preview close action must remain available after zoom gestures.")
        attachText("realGestures=doubleTap,pinch; exactSyntheticPhotoVerifiedBeforeGestures=true; beforeAfterScreenshotsCaptured=true; zoomVisualPassClaimed=false; independentPixelReviewRequired=true; closePreviewAvailable=true", "T06R zoom evidence status")
        try tap(app.buttons["closePhotoPreview"])
        try tap(app.navigationBars.buttons["关闭"].firstMatch)
        attachText("exactR5DraftRecovered=true; newRecordOrPrivateDraftOverwritten=false; manualDate=2026-10-18; manualTime=09:15; appendPreservedTime=true; reordered=true; removed=QA1; savedAndRelaunched=true; remainingMedia=QA2", "T06R media-edit recovery result")
    }

    func test07SavedSyntheticPhotoZoomScreenEvidence() throws {
        try startOffline()
        try openSyntheticRecord("Jinbao migration QA editmedia 1DBB608D-96D2-4953-ADAE-B23E9C4A9358")
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detailPreview-"))
        guard previews.count == 1 else { throw AcceptanceFailure("The exact saved synthetic record must contain only QA2.") }
        try tap(previews.firstMatch); try waitForVerifiedFullScreen(number: 2)
        func screen(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        screen("T07 entire device screen before photo zoom")
        app.doubleTap(); Thread.sleep(forTimeInterval: 2)
        screen("T07 entire device screen after double-tap zoom")
        Thread.sleep(forTimeInterval: 12) // Allow independent devicectl capture of the same verified synthetic screen.
        screenshot(app, "T07 app capture after double-tap zoom")
        app.pinch(withScale: 1.25, velocity: 1); Thread.sleep(forTimeInterval: 2)
        screen("T07 entire device screen after pinch zoom")
        Thread.sleep(forTimeInterval: 12)
        XCTAssertTrue(app.buttons["closePhotoPreview"].isHittable)
        try tap(app.buttons["closePhotoPreview"])
        XCTAssertTrue(app.navigationBars.buttons["关闭"].waitForExistence(timeout: 5))
        screen("T07 exited zoom to saved synthetic detail")
        try tap(app.navigationBars.buttons["关闭"].firstMatch)
    }

    private func test06Observed(_ id: String) -> String {
        let element = app.descendants(matching: .any)[id].firstMatch
        guard element.exists else { return "" }
        return ([element] + Array(element.descendants(matching: .any).allElementsBoundByAccessibilityElement.prefix(32)))
            .map { $0.label + " " + ($0.value as? String ?? "") }.joined(separator: " ")
    }
    private func test06AssertManualDateAndTime() throws {
        try reveal(app.descendants(matching: .any)["draftDate"].firstMatch)
        try reveal(app.descendants(matching: .any)["draftTime"].firstMatch)
        let date = test06Observed("draftDate"), time = test06Observed("draftTime")
        let month = date.localizedCaseInsensitiveContains("oct") || date.contains("10月") || date.contains("10/18") || date.contains("18/10")
        guard date.contains("2026"), date.contains("18"), month,
              !time.localizedCaseInsensitiveContains("pm"), !time.contains("下午"), !time.contains("晚上"),
              time.range(of: #"(?:^|[^0-9])0?9[:：点时\s]+15(?:[^0-9]|$)"#, options: .regularExpression) != nil else {
            throw AcceptanceFailure("The native controls do not show the required manual 2026-10-18 09:15. No date-preservation pass was claimed.")
        }
    }
    private func test06OpenNativeDateControl(_ id: String) throws {
        let control = app.descendants(matching: .any)[id].firstMatch
        try reveal(control)
        let buttons = control.buttons.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable && control.frame.intersects($0.frame) }
        if buttons.count == 1 { buttons[0].tap() }
        else {
            let frame = control.frame
            guard frame.width > 100, frame.height >= 20, unobscuredViewport(for: control).contains(frame) else {
                throw AcceptanceFailure("The native date/time control has no safe trailing activation region.")
            }
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        }
    }
    private func test06SetNativeDateToOctober18() throws {
        let before = test06Observed("draftDate")
        guard before.contains("2026"), before.contains("19") else { throw AcceptanceFailure("Manual-date test requires its newly imported October19 fixture date.") }
        try test06OpenNativeDateControl("draftDate")
        let wheels = app.pickerWheels.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        let dayWheel = wheels.filter { test06NumericValue($0.value as? String ?? "") == 19 }
        if wheels.count >= 3, dayWheel.count == 1 {
            let value = dayWheel[0].value as? String ?? "19"
            dayWheel[0].adjust(toPickerWheelValue: value.replacingOccurrences(of: "19", with: "18"))
        } else {
            // The compact calendar remains on the imported October2026 month. Accept
            // only its unique visible day18 action, never an arbitrary coordinate.
            let candidates = app.buttons.allElementsBoundByAccessibilityElement.filter { element in
                guard element.exists, element.isHittable else { return false }
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if label == "18" { return true }
                let hasDay = label.range(of: #"(?:^|[^0-9])18(?:[^0-9]|$)"#, options: .regularExpression) != nil
                return hasDay && (label.localizedCaseInsensitiveContains("oct") || label.contains("10月"))
            }
            guard candidates.count == 1, let day = candidates.first else {
                throw AcceptanceFailure("Native calendar did not expose one unambiguous October18 day button. The synthetic draft was retained.")
            }
            day.tap()
        }
        try test06DismissDateOverlay()
        let updated = test06Observed("draftDate")
        guard updated.contains("2026"), updated.contains("18") else { throw AcceptanceFailure("The manual native date change was not reflected by the record form.") }
    }
    private func test06SetNativeTimeTo0915() throws {
        let before = test06Observed("draftTime")
        guard before.contains("10:30") || before.contains("10点30") || before.contains("10 30") else {
            throw AcceptanceFailure("Manual-time test requires its newly imported 10:30 fixture time.")
        }
        try test06OpenNativeDateControl("draftTime")
        let wheelsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.pickerWheels.count >= 2 }, object: nil)
        _ = XCTWaiter.wait(for: [wheelsReady], timeout: 2)
        let wheels = app.pickerWheels.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        let hours = wheels.filter { test06NumericValue($0.value as? String ?? "") == 10 }
        let minutes = wheels.filter { test06NumericValue($0.value as? String ?? "") == 30 }
        if hours.count == 1, minutes.count == 1 {
            // UIKit labels the current values with Chinese units but exposes
            // zero-padded numeric options to XCTest on Cody XS.
            hours[0].adjust(toPickerWheelValue: "09")
            minutes[0].adjust(toPickerWheelValue: "15")
        } else {
            let numeric = app.textFields.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            let hour = numeric.filter { $0.value as? String == "10" }
            let minute = numeric.filter { $0.value as? String == "30" }
            guard hour.count == 1, minute.count == 1 else {
                throw AcceptanceFailure("Native time picker exposed neither unique hour/minute wheels nor numeric fields. No manual-time pass was claimed.")
            }
            hour[0].doubleTap(); hour[0].typeText("9")
            minute[0].doubleTap(); minute[0].typeText("15")
        }
        try test06DismissDateOverlay()
    }
    private func test06NumericValue(_ text: String) -> Int? {
        guard let range = text.range(of: #"[0-9]+"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }
    private func test06DismissDateOverlay() throws {
        let wheelsBefore = app.pickerWheels.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }.count
        let daysBefore = test06VisibleCalendarDays().count
        let done = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Done|完成)$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        if done.count == 1 { done[0].tap() }
        else {
            let bar = app.navigationBars.matching(identifier: "记录小日常").firstMatch
            let heading = bar.staticTexts["记录小日常"].firstMatch
            guard bar.exists, heading.exists else {
                throw AcceptanceFailure("The native date/time overlay has no identified editor navigation title for outside dismissal.")
            }
            let frame = heading.frame
            guard frame.width > 0, frame.height > 0, app.frame.contains(frame),
                  bar.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                throw AcceptanceFailure("The editor title has no nonempty visible frame inside its navigation bar; no outside tap was performed.")
            }
            // R5's genuine screenshot places the native popover below this title.
            // Modal AX blocks the underlay's isHittable; use only the identified title's frame.
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        }
        let title = app.textFields["draftTitle"]
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            title.exists && title.isHittable &&
            self.app.pickerWheels.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }.isEmpty &&
            self.test06VisibleCalendarDays().isEmpty
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "The calendar/time picker must disappear and the retained editor fields become interactive.")
        XCTAssertTrue(app.descendants(matching: .any)["draftDate"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["draftTime"].firstMatch.exists)
        attachText("nativeWheelsBefore=\(wheelsBefore); calendarDayButtonsBefore=\(daysBefore); nativePickerDismissed=true; editorFieldsRetained=true", "T06 native date-time popover dismissal")
    }
    private func test06VisibleCalendarDays() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(0?[1-9]|[12][0-9]|3[01])$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
    }

    private func test05CredentialIsEmpty(_ identifier: String) -> Bool {
        let secure = app.secureTextFields[identifier]
        let field = secure.exists ? secure : app.textFields[identifier]
        guard field.exists, let value = field.value as? String else { return false }
        return value.isEmpty || value == field.placeholderValue
    }
    private func test05AssertEmptyOwnedDraft() throws {
        let title = app.textFields["draftTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let note = app.descendants(matching: .any)["draftNote"].firstMatch
        let titleValue = title.value as? String ?? ""
        let noteValue = note.value as? String ?? ""
        guard titleValue.isEmpty || titleValue == title.placeholderValue,
              noteValue.isEmpty || noteValue == note.placeholderValue,
              app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == 0 else {
            throw AcceptanceFailure("The file-import entry did not return this test's empty draft. It was retained without changes.")
        }
    }
    private func test05CancelSystemPicker(context: String) throws {
        let cancelQuery = app.navigationBars.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Cancel|取消)$"))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cancelQuery.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed, "The \(context) picker must expose a visible native Cancel action.")
        let buttons = cancelQuery.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        guard buttons.count == 1, let cancel = buttons.first, app.frame.contains(cancel.frame) else {
            throw AcceptanceFailure("The \(context) picker Cancel action could not be safely identified; no coordinate or content selection was attempted.")
        }
        cancel.tap()
        let title = app.textFields["draftTitle"]
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in title.exists && title.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed, "Cancelling \(context) selection must return to the visible retained composer.")
    }
    private func test05Tap(_ element: XCUIElement) throws {
        try reveal(element)
        element.tap()
    }

    private func startOffline(allowPendingDraft: Bool = false) throws {
        app.launch()
        XCTAssertTrue(app.buttons["tabTimeline"].waitForExistence(timeout: 12), "Use the existing initialized Cody XS installation.")
        guard !app.textFields["draftTitle"].exists else { throw AcceptanceFailure("A pre-existing draft is open. It was retained without editing.") }
        try tap(app.buttons["tabMy"])
        try tap(app.buttons["tabCloud"])
        guard app.staticTexts["storagePlaceholder"].waitForExistence(timeout: 5), !app.staticTexts["storageVerified"].exists else {
            throw AcceptanceFailure("Offline migration checks require the existing placeholder connection. Credentials were not changed.")
        }
        try tap(app.buttons["tabTimeline"])
        guard allowPendingDraft || !app.buttons["timelineResumeDraft"].exists else {
            throw AcceptanceFailure("A retained draft already exists. This scenario did not open, modify, or treat it as a newly imported media record.")
        }
    }
    private func beginText() throws { try tap(app.buttons["addMoment"]); try tap(app.buttons["addNoteMenuAction"]); XCTAssertTrue(app.textFields["draftTitle"].waitForExistence(timeout: 5)) }
    private func typeNewTitle(_ title: String) throws {
        let field = app.textFields["draftTitle"]
        guard field.value as? String == "" || field.value as? String == field.placeholderValue else { throw AcceptanceFailure("A nonempty existing draft was retained without rewriting.") }
        field.tap(); field.typeText(title)
    }
    private func filterTimeline(_ text: String) throws {
        try tap(app.buttons["tabTimeline"])
        if !app.textFields["timelineSearchField"].exists { try tap(app.buttons["timelineSearchToggle"]) }
        let field = app.textFields["timelineSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let clear = app.buttons["timelineSearchClear"]
        if clear.exists { clear.tap() }
        field.tap()
        field.typeText(text + "\n")
    }
    @discardableResult
    private func openSyntheticRecord(_ title: String) throws -> String {
        try filterTimeline(title)
        let label = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 8))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "momentCard-"))
            .containing(.staticText, identifier: title).allElementsBoundByAccessibilityElement
        guard cards.count == 1, let card = cards.first else { throw AcceptanceFailure("The synthetic title did not identify exactly one timeline record.") }
        let recordID = String(card.identifier.dropFirst("momentCard-".count))
        guard UUID(uuidString: recordID) != nil else { throw AcceptanceFailure("The synthetic record has no stable UUID UI identifier.") }
        try tap(card)
        XCTAssertTrue(app.navigationBars.buttons["关闭"].waitForExistence(timeout: 5))
        return recordID
    }
    private func dismissKeyboard() {
        let done = app.buttons["dismissComposerKeyboard"]
        if done.exists && done.isHittable { done.tap(); return }
        guard app.keyboards.firstMatch.exists else { return }
        let submit = app.keyboards.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Return|return|Done|完成|换行|下一项|Next)$")).firstMatch
        if submit.exists && submit.isHittable { submit.tap() }
        else if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
    }
    private func setSwitch(_ element: XCUIElement, to value: String) throws {
        try reveal(element)
        guard element.value as? String != value else { return }
        // SwiftUI Form exposes the entire row as a Switch. Tap the native trailing thumb,
        // rather than its central text label, and wait for the resulting accessibility state.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, "The switch must reach its requested visible state.")
    }
    private func insertVerifiedSyntheticEdit(_ element: XCUIElement, expected: String) throws -> String {
        let marker = " edited"
        guard element.value as? String == expected, expected.hasPrefix("Jinbao migration QA "), !expected.contains(marker) else {
            throw AcceptanceFailure("The editor does not contain the expected unedited synthetic title; no insertion was performed.")
        }
        element.tap()
        element.typeText(marker)
        let actual = element.value as? String ?? ""
        guard actual.count == expected.count + marker.count, let range = actual.range(of: marker) else {
            throw AcceptanceFailure("The actual synthetic edit was not a single insertion. It was retained for inspection, not reported as passed.")
        }
        var restored = actual
        restored.removeSubrange(range)
        guard restored == expected else { throw AcceptanceFailure("The title edit changed content beyond the inserted marker.") }
        return actual
    }

    private func openMomentActions() throws {
        let button = app.buttons["momentActions"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let bar = app.navigationBars.matching(identifier: "小日常").firstMatch
        guard bar.waitForExistence(timeout: 5) else { throw AcceptanceFailure("The record detail navigation bar is not visible.") }
        let frame = button.frame
        let visible = frame.width >= 20 && frame.height >= 20 && app.frame.contains(frame)
            && bar.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY))
        guard visible else { throw AcceptanceFailure("The identified record-actions button has no valid visible frame inside its navigation bar.") }
        // M02's genuine device screenshot confirms this ellipsis is visible. XCTest may
        // expose SwiftUI Menu's AX proxy as non-hittable; tap only its verified frame.
        screenshot(app, "Record-actions visible synthetic detail before menu tap")
        attachText("momentActionsFrame=\(NSCoder.string(for: frame)); navigationBarFrame=\(NSCoder.string(for: bar.frame)); accessibilityHittable=\(button.isHittable)", "Record-actions visible geometry")
        if button.isHittable { button.tap() }
        else {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
        }
        XCTAssertTrue(app.buttons["editMoment"].waitForExistence(timeout: 5), "The real edit menu must open.")
        XCTAssertTrue(app.buttons["trashMoment"].exists, "The real recycle-bin action must also be present.")
    }

    private func waitForImportedAssets(_ count: Int) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draftPreview-")).count == count && !self.app.progressIndicators["photoImportProgress"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        guard !app.staticTexts["photoImportFailure"].exists else { throw AcceptanceFailure("A synthetic media import failed; the draft was retained.") }
    }
    private func assertImportedDateAndTime() throws {
        let date = app.descendants(matching: .any)["draftDate"].firstMatch
        let time = app.descendants(matching: .any)["draftTime"].firstMatch
        try reveal(date); try reveal(time)
        func observed(_ element: XCUIElement) -> String {
            ([element] + Array(element.descendants(matching: .any).allElementsBoundByAccessibilityElement.prefix(24)))
                .map { $0.label + " " + ($0.value as? String ?? "") }.joined(separator: " ")
        }
        let dateText = observed(date), timeText = observed(time)
        XCTAssertTrue(dateText.contains("2026") && (dateText.contains("19") || dateText.contains("十九")), "Selected media must auto-fill 2026-10-19.")
        XCTAssertTrue(timeText.contains("10:30") || timeText.contains("10点30") || timeText.contains("10 30"), "First batch must choose the earlier valid capture, 10:30 +08.")
        screenshot(date, "M23 automatically filled synthetic capture date")
        screenshot(time, "M24 automatically filled earliest capture time")
    }

    private struct VerifiedCell { let number: Int; let frame: CGRect }
    private func selectVerifiedFixtures(_ numbers: [Int]) throws {
        let grid = app.images.matching(identifier: "PXGGridLayout-Info")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.count > 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        var found: [Int: CGRect] = [:]
        for _ in 0..<5 {
            let cells = verifiedCells()
            for cell in cells where numbers.contains(cell.number) { found[cell.number] = cell.frame }
            if numbers.allSatisfy({ found[$0] != nil }) { break }
            // Only scroll the already-present picker; no library labels or pixels are retained.
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
            found.removeAll()
        }
        guard numbers.allSatisfy({ found[$0] != nil }) else {
            cancelPickerIfPresent()
            throw AcceptanceFailure("The exact run-specific synthetic thumbnails were not all visible. No unverified media was selected.")
        }
        for number in numbers {
            // Reverify the same current frame immediately before selecting, after selection badges may change.
            guard let cell = verifiedCells().first(where: { $0.number == number }) else { cancelPickerIfPresent(); throw AcceptanceFailure("Synthetic thumbnail changed before selection.") }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cell.frame.midX - app.frame.minX, dy: cell.frame.midY - app.frame.minY)).tap()
        }
        let adds = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^(Add|添加|Done|完成)([ ]*[(（][0-9]+[)）])?$"))
            .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
        guard adds.count == 1, let add = adds.first, add.isEnabled else { cancelPickerIfPresent(); throw AcceptanceFailure("Verified picker selections did not enable Add.") }
        add.tap()
        XCTAssertTrue(app.buttons["composerPickPhoto"].waitForExistence(timeout: 20))
    }
    private func verifiedCells() -> [VerifiedCell] {
        guard let screen = app.screenshot().image.cgImage else { return [] }
        let viewport = app.frame
        let scaleX = CGFloat(screen.width) / viewport.width, scaleY = CGFloat(screen.height) / viewport.height
        var result: [VerifiedCell] = []
        for cell in app.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByAccessibilityElement.prefix(48) {
            guard cell.exists else { continue }
            let frame = cell.frame
            guard frame.width >= 60, frame.width <= viewport.width * 0.55, (0.8...1.25).contains(frame.height / frame.width), viewport.contains(frame), cell.isHittable else { continue }
            let crop = CGRect(x: (frame.minX - viewport.minX) * scaleX, y: (frame.minY - viewport.minY) * scaleY, width: frame.width * scaleX, height: frame.height * scaleY)
            guard let pixels = screen.cropping(to: crop), let number = verifiedNumber(pixels) else { continue }
            result.append(VerifiedCell(number: number, frame: frame))
        }
        return result
    }
    private func verifiedNumber(_ image: CGImage) -> Int? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false; request.minimumTextHeight = 0.004
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.55 }.map { $0.string }
        guard lines.contains(where: { $0.hasSuffix(fixtureRun) }) else { return nil }
        return (1...4).first { number in lines.contains { $0.hasSuffix("QA \(number)") } }
    }
    private func waitForVerifiedFullScreen(number: Int) throws {
        // This helper is used only after exact-run picker selection or the explicitly
        // identified interrupted synthetic draft. Preserve the real displayed result
        // even when OCR fails; never attach a system-picker grid or unrelated library.
        screenshot(app, "Synthetic full-size preview before strict OCR — QA \(number)")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.verifiedFullScreen(number: number) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Full-size media must render the exact synthetic run and QA number.")
    }
    private func verifiedFullScreen(number: Int) -> Bool {
        let data = app.screenshot().pngRepresentation
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        // In the original whole-screen request, tall black letterboxing shrinks the marker
        // relative to the screen. Also analyze the center media area at its own resolution.
        let region = CGRect(x: CGFloat(image.width) * 0.02, y: CGFloat(image.height) * 0.28,
                            width: CGFloat(image.width) * 0.96, height: CGFloat(image.height) * 0.50)
        let images = [image.cropping(to: region), image].compactMap { $0 }
        for pixels in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.004
            guard (try? VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])) != nil else { continue }
            let candidates = (request.results ?? []).flatMap { $0.topCandidates(5) }
                .filter { $0.confidence >= 0.20 }.map { normalizedMarker($0.string) }
            let exactQA = candidates.contains("JINBAOQA\(number)")
            let run = normalizedMarker(fixtureRun)
            let exactRun = candidates.contains(run) || candidates.contains("RUN" + run)
            if exactQA && exactRun { return true }
        }
        return false
    }
    private func normalizedMarker(_ text: String) -> String {
        text.uppercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }
    private func attachText(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func uniqueVisibleButton(_ labels: [String]) -> XCUIElement? {
        for label in labels {
            let found = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            if found.count == 1 { return found[0] }
        }
        return nil
    }
    private func cancelPickerIfPresent() { uniqueVisibleButton(["取消", "Cancel"])?.tap() }
    private func reveal(_ element: XCUIElement) throws {
        // Form rows can be absent until realized. Never tap a body control through
        // the floating bottom navigation, even if its AX proxy claims hittability.
        for _ in 0..<12 {
            var above = false
            if element.exists {
                let frame = element.frame
                let viewport = unobscuredViewport(for: element)
                if frame.width > 0 && frame.height > 0 && element.isHittable && viewport.contains(frame) { return }
                if frame.width > 0 && frame.height > 0 {
                    above = frame.maxY <= viewport.minY || frame.midY < viewport.minY + viewport.height * 0.25
                }
            }
            guard let container = scrollContainer(containing: element) else { break }
            if above { container.swipeDown() } else { container.swipeUp() }
        }
        guard element.exists, element.frame.width > 0, element.frame.height > 0,
              element.isHittable, unobscuredViewport(for: element).contains(element.frame) else {
            throw AcceptanceFailure("Required UI control was not present and unobscured after bounded scrolling; no tap through the bottom navigation was performed.")
        }
    }
    private func unobscuredViewport(for element: XCUIElement) -> CGRect {
        let barIDs = ["tabTimeline", "tabAnniversaries", "tabReview", "tabMy", "addMoment"]
        var viewport = app.frame
        guard !barIDs.contains(element.identifier) else { return viewport }
        let barFrames = barIDs.compactMap { id -> CGRect? in
            let button = app.buttons[id].firstMatch
            guard button.exists, button.isHittable, app.frame.intersects(button.frame) else { return nil }
            return button.frame
        }
        if let top = barFrames.map(\.minY).min(), top > viewport.minY {
            viewport.size.height = max(0, min(viewport.maxY, top - 4) - viewport.minY)
        }
        return viewport
    }
    private func scrollContainer(containing element: XCUIElement) -> XCUIElement? {
        if element.exists, !element.identifier.isEmpty {
            let id = element.identifier
            let owned = [app.tables.containing(element.elementType, identifier: id),
                         app.collectionViews.containing(element.elementType, identifier: id),
                         app.scrollViews.containing(element.elementType, identifier: id)]
                .flatMap { $0.allElementsBoundByAccessibilityElement }
                .filter { $0.exists && $0.isHittable && app.frame.intersects($0.frame) }
            if let container = owned.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) { return container }
        }
        return [app.tables.firstMatch, app.collectionViews.firstMatch, app.scrollViews.firstMatch]
            .first { $0.exists && $0.isHittable }
    }
    private func tap(_ element: XCUIElement) throws { try reveal(element); element.tap() }
    private func screenshot(_ element: XCUIElement, _ name: String) { let attachment = XCTAttachment(screenshot: element.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
}

private struct AcceptanceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
