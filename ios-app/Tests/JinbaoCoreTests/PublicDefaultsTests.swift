import XCTest
@testable import JinbaoCore

final class PublicDefaultsTests: XCTestCase {
    func testFreshInstallHasOnlyYearlessPublicHolidaysAndDoesNotWriteRows() throws {
        let state = AppSession(deviceID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", testBuild: true, identity: .dad)
        XCTAssertEqual(state.anniversaryEntries().map(\.title), ["儿童节", "国庆节", "元旦"])
        XCTAssertEqual(state.anniversaryEntries().map(\.date), ["0004-06-01", "0004-10-01", "0004-01-01"])
        XCTAssertTrue(state.anniversaryEntries().allSatisfy { !$0.yearKnown })
        XCTAssertTrue(state.anniversaries.isEmpty)
        XCTAssertEqual(state.anniversaryEntries(), state.anniversaryEntries())
        XCTAssertThrowsError(try StorageConfiguration().validate())
        XCTAssertNil(JinbaoCalendar.age(on: DateParts(year: 2030, month: 2, day: 3)))
    }
    func testBlankFirstRunFieldsEnterOnlyLocalPlaceholder() throws {
        var state = AppSession(deviceID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", testBuild: true, identity: .dad)
        XCTAssertThrowsError(try state.connectVerified(bucket: "", region: ""))
        try state.connectPlaceholder(bucket: "", region: "")
        guard case .placeholder(let bucket, let region) = state.link else {
            return XCTFail("Expected a local placeholder")
        }
        XCTAssertEqual(bucket, "example-1234567890")
        XCTAssertEqual(region, "ap-shanghai")
        XCTAssertTrue(state.anniversaries.isEmpty)
        XCTAssertThrowsError(try BackupPlan.manifest(session: state, now: 1))
    }
    func testUpgradeKeepsSavedLegacyRowsOverridesAndDeletion() throws {
        var state = AppSession(deviceID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", testBuild: true, identity: .dad)
        let legacy = LocalAnniversary(id: "00000000-0000-4000-8000-000000000001", owner: .dad,
                                     title: "用户已保存", date: "2000-02-03", updatedAt: 1)
        state.anniversaries.append(legacy)
        try state.saveAnniversary(id: AnniversaryCalendar.defaults[0].id, title: "用户改过", date: "--02-14", now: 2)
        try state.deleteAnniversary(id: AnniversaryCalendar.defaults[1].id, now: 3)
        let saved = state.anniversaries
        let entries = state.anniversaryEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first { $0.id == legacy.id }?.date, "2000-02-03")
        XCTAssertEqual(entries.first { $0.title == "用户改过" }?.date, "0004-02-14")
        XCTAssertFalse(entries.contains { $0.title == "国庆节" })
        XCTAssertEqual(state.anniversaryEntries(), entries)
        XCTAssertEqual(state.anniversaries, saved)
        let bytes = try JSONEncoder().encode(PersistedArchive(session: state))
        let reloaded = try JSONDecoder().decode(PersistedArchive.self, from: bytes).session()
        XCTAssertEqual(reloaded.anniversaryEntries(), entries)
        XCTAssertEqual(reloaded.anniversaries, saved)
    }
}
