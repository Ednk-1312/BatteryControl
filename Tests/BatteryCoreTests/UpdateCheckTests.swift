import XCTest
@testable import BatteryCore

/// Tests for the passive update check: GitHub API parsing (drafts and
/// prereleases refused), honest semver comparison (unparseable versions
/// never claim "newer"), and the daily check cadence.
final class UpdateCheckTests: XCTestCase {

    // MARK: Parsing

    func testParseLatestRelease() throws {
        let json = """
        {"tag_name": "1.1.0", "html_url": "https://github.com/Ednk-1312/BatteryControl/releases/tag/1.1.0", "draft": false, "prerelease": false}
        """.data(using: .utf8)!
        let release = try UpdateCheck.parseLatestRelease(fromData: json)
        XCTAssertEqual(release.tagName, "1.1.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/Ednk-1312/BatteryControl/releases/tag/1.1.0")
    }

    func testParseRefusesDraftAndPrerelease() {
        let draft = """
        {"tag_name": "1.1.0", "html_url": "https://x", "draft": true, "prerelease": false}
        """.data(using: .utf8)!
        let pre = """
        {"tag_name": "1.1.0", "html_url": "https://x", "draft": false, "prerelease": true}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateCheck.parseLatestRelease(fromData: draft)) { error in
            XCTAssertEqual(error as? UpdateCheck.ParseError, .notARelease)
        }
        XCTAssertThrowsError(try UpdateCheck.parseLatestRelease(fromData: pre)) { error in
            XCTAssertEqual(error as? UpdateCheck.ParseError, .notARelease)
        }
    }

    func testParseRefusesGarbage() {
        XCTAssertThrowsError(try UpdateCheck.parseLatestRelease(fromData: Data("{}".utf8)))
        XCTAssertThrowsError(try UpdateCheck.parseLatestRelease(fromData: Data("not json".utf8)))
    }

    // MARK: Version comparison

    func testNewerVersionsCompareCorrectly() {
        XCTAssertTrue(UpdateCheck.isNewer("1.1.0", than: "1.0.2"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.1.0", than: "1.0.2"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.3", than: "1.0.2"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0", than: "1.9.9"))
        // Equal is not newer.
        XCTAssertFalse(UpdateCheck.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.2-beta1", than: "1.0.2"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.2"))
        // Older.
        XCTAssertFalse(UpdateCheck.isNewer("1.0.1", than: "1.0.2"))
    }

    func testUnparseableVersionsNeverTriggerNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("banana", than: "1.0.2"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.0", than: "banana"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "1.0.2"))
        XCTAssertFalse(UpdateCheck.isNewer("1.x.y", than: "1.0.2"))
    }

    // MARK: Cadence

    func testCheckDue() {
        let now = Date()
        // Never checked: due.
        XCTAssertTrue(UpdateCheck.isCheckDue(lastCheck: nil, now: now))
        // Checked just now: not due.
        XCTAssertFalse(UpdateCheck.isCheckDue(lastCheck: now.addingTimeInterval(-60), now: now))
        // Checked 25 hours ago: due.
        XCTAssertTrue(UpdateCheck.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    }
}
