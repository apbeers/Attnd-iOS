// BusinessLogicTests.swift
// AttndTests
//
// Unit tests for business logic that doesn't require a network connection:
//   - ScheduledItem.startsInText(relativeTo:)
//   - AppState.eventCode(from:)
//   - URL encoding for queries containing special characters like &

import XCTest
@testable import Attnd

final class BusinessLogicTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed anchor date used across all startsInText tests.
    /// Using a fixed point eliminates timing sensitivity — both the item's
    /// startTime and the `relativeTo` argument are derived from the same anchor.
    private let anchor = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00:00 UTC

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Build a ScheduledItem whose startTime is `seconds` after `anchor`.
    private func item(secondsFromAnchor seconds: TimeInterval) -> ScheduledItem {
        ScheduledItem(
            id: 1,
            name: "Test",
            description: "",
            startTime: fmt.string(from: anchor.addingTimeInterval(seconds)),
            locationId: 1,
            locationName: "Stage"
        )
    }

    private func item(startTime iso: String) -> ScheduledItem {
        ScheduledItem(id: 1, name: "Test", description: "", startTime: iso, locationId: 1, locationName: "Stage")
    }

    // MARK: - startsInText: future items

    func testStartsInText_HoursAndMinutes() {
        let result = item(secondsFromAnchor: (2 * 3600) + (30 * 60)).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starts in 2h 30m")
    }

    func testStartsInText_ExactlyOneHour() {
        let result = item(secondsFromAnchor: 3600).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starts in 1h")
    }

    func testStartsInText_ExactlyTwoHours() {
        let result = item(secondsFromAnchor: 7200).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starts in 2h")
    }

    func testStartsInText_MinutesOnly() {
        let result = item(secondsFromAnchor: 45 * 60).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starts in 45m")
    }

    func testStartsInText_OneMinute() {
        let result = item(secondsFromAnchor: 90).startsInText(relativeTo: anchor) // 1m 30s → 1m
        XCTAssertEqual(result, "Starts in 1m")
    }

    func testStartsInText_LessThanOneMinute_ReturnsStartingNow() {
        let result = item(secondsFromAnchor: 30).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starting now")
    }

    func testStartsInText_ExactlyZeroSeconds_ReturnsNil() {
        // anchor == startTime → seconds == 0 → guard seconds > 0 fails → nil
        let result = item(secondsFromAnchor: 0).startsInText(relativeTo: anchor)
        XCTAssertNil(result)
    }

    // MARK: - startsInText: past items

    func testStartsInText_OneMinutePast_ReturnsNil() {
        let result = item(secondsFromAnchor: -60).startsInText(relativeTo: anchor)
        XCTAssertNil(result)
    }

    func testStartsInText_OneDayPast_ReturnsNil() {
        let result = item(secondsFromAnchor: -86400).startsInText(relativeTo: anchor)
        XCTAssertNil(result)
    }

    // MARK: - startsInText: invalid ISO strings

    func testStartsInText_InvalidISO_ReturnsNil() {
        let bad = item(startTime: "not-a-date")
        XCTAssertNil(bad.startsInText(relativeTo: .now))
    }

    func testStartsInText_EmptyString_ReturnsNil() {
        let bad = item(startTime: "")
        XCTAssertNil(bad.startsInText(relativeTo: .now))
    }

    // MARK: - startsInText: ISO 8601 format variants

    func testStartsInText_FractionalSeconds() {
        // The formatter should handle fractional seconds (p1 path)
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = fmtFrac.string(from: anchor.addingTimeInterval(3600))
        let result = item(startTime: iso).startsInText(relativeTo: anchor)
        XCTAssertEqual(result, "Starts in 1h")
    }

    func testStartsInText_TimezoneOffset() {
        // ISO string with explicit offset — 2099-12-31T12:00:00+05:30 is far in the future
        // relative to any sane anchor, so result must be non-nil and start with "Starts in"
        let result = item(startTime: "2099-12-31T12:00:00+05:30").startsInText(relativeTo: anchor)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.hasPrefix("Starts in"))
    }

    // MARK: - startsInText: custom `now` reference

    func testStartsInText_CustomNow_Future() {
        let anchor = ISO8601DateFormatter()
        anchor.formatOptions = [.withInternetDateTime]
        let fixedNow = anchor.date(from: "2026-07-04T12:00:00Z")!
        let twoHoursLater = anchor.date(from: "2026-07-04T14:00:00Z")!

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let it = item(startTime: fmt.string(from: twoHoursLater))
        XCTAssertEqual(it.startsInText(relativeTo: fixedNow), "Starts in 2h")
    }

    func testStartsInText_CustomNow_Past() {
        let anchor = ISO8601DateFormatter()
        anchor.formatOptions = [.withInternetDateTime]
        let fixedNow = anchor.date(from: "2026-07-04T12:00:00Z")!
        let oneHourEarlier = anchor.date(from: "2026-07-04T11:00:00Z")!

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let it = item(startTime: fmt.string(from: oneHourEarlier))
        XCTAssertNil(it.startsInText(relativeTo: fixedNow))
    }

    // MARK: - AppState.eventCode(from:)

    private let state = AppState()

    func testEventCode_ValidJoinURL() {
        let url = URL(string: "https://attnd.app/join/FWFM2026")!
        XCTAssertEqual(state.eventCode(from: url), "FWFM2026")
    }

    func testEventCode_ValidJoinURL_TrailingSlash() {
        let url = URL(string: "https://attnd.app/join/FWFM2026/")!
        XCTAssertEqual(state.eventCode(from: url), "FWFM2026")
    }

    func testEventCode_LowercaseCode() {
        let url = URL(string: "https://attnd.app/join/abc123")!
        XCTAssertEqual(state.eventCode(from: url), "abc123")
    }

    func testEventCode_WrongPath_ReturnsNil() {
        let url = URL(string: "https://attnd.app/events/FWFM2026")!
        XCTAssertNil(state.eventCode(from: url))
    }

    func testEventCode_RootPath_ReturnsNil() {
        let url = URL(string: "https://attnd.app/")!
        XCTAssertNil(state.eventCode(from: url))
    }

    func testEventCode_JoinWithNoCode_ReturnsNil() {
        let url = URL(string: "https://attnd.app/join/")!
        // pathComponents: ["/", "join", ""] — parts[2] is empty → nil
        XCTAssertNil(state.eventCode(from: url))
    }

    func testEventCode_JoinOnly_ReturnsNil() {
        let url = URL(string: "https://attnd.app/join")!
        // pathComponents: ["/", "join"] — count < 3 → nil
        XCTAssertNil(state.eventCode(from: url))
    }

    func testEventCode_DifferentHost_StillParses() {
        // The parser only looks at path, not host — deep links from any host work
        let url = URL(string: "https://example.com/join/MYCODE")!
        XCTAssertEqual(state.eventCode(from: url), "MYCODE")
    }

    // MARK: - URL encoding for & in query strings

    func testURLEncoding_AmpersandInName() {
        // Verify that & in event names gets percent-encoded so it doesn't break query params.
        // This is a regression test for the bug where "Austin Tech & Innovation Summit" was
        // silently truncated to "Austin Tech " by the API because & was left unencoded.
        let name = "Austin Tech & Innovation Summit"
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: set)!
        XCTAssertTrue(encoded.contains("%26"), "& should be percent-encoded to %26")
        XCTAssertFalse(encoded.contains("&"), "Raw & should not appear in the encoded string")
    }

    func testURLEncoding_PlusSign() {
        let name = "A+B Event"
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: set)!
        XCTAssertTrue(encoded.contains("%2B"), "+ should be encoded to %2B")
    }

    func testURLEncoding_NormalEventCode_Unchanged() {
        let code = "FWFM2026"
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        let encoded = code.addingPercentEncoding(withAllowedCharacters: set)!
        XCTAssertEqual(encoded, code, "Plain alphanumeric code should not be encoded")
    }
}
