// BusinessLogicTests.swift
// AttndTests
//
// Network-free tests for small helpers:
//   - ScheduleItem.startsInText(relativeTo:)
//   - DeepLink parsing (Universal Links and scanned QR codes)
//   - query-value encoding for names containing & = +
//   - PushPayload parsing
//   - hex colours, ISO 8601 parsing, event-day detection

import XCTest
@testable import Attnd

final class BusinessLogicTests: XCTestCase {

    /// Fixed anchor so both the item's start and `now` derive from the same point.
    private let anchor = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00:00 UTC

    private func item(secondsFromAnchor seconds: TimeInterval) -> ScheduleItem {
        ScheduleItem(id: 1, name: "Test", startTime: anchor.addingTimeInterval(seconds))
    }

    // MARK: - startsInText

    func testStartsInText_HoursAndMinutes() {
        XCTAssertEqual(item(secondsFromAnchor: 2 * 3600 + 30 * 60).startsInText(relativeTo: anchor), "Starts in 2h 30m")
    }

    func testStartsInText_ExactHours() {
        XCTAssertEqual(item(secondsFromAnchor: 3600).startsInText(relativeTo: anchor), "Starts in 1h")
        XCTAssertEqual(item(secondsFromAnchor: 7200).startsInText(relativeTo: anchor), "Starts in 2h")
    }

    func testStartsInText_MinutesOnly() {
        XCTAssertEqual(item(secondsFromAnchor: 45 * 60).startsInText(relativeTo: anchor), "Starts in 45m")
        XCTAssertEqual(item(secondsFromAnchor: 90).startsInText(relativeTo: anchor), "Starts in 1m")
    }

    func testStartsInText_UnderAMinute_IsStartingNow() {
        XCTAssertEqual(item(secondsFromAnchor: 30).startsInText(relativeTo: anchor), "Starting now")
    }

    func testStartsInText_StartedOrPast_IsNil() {
        XCTAssertNil(item(secondsFromAnchor: 0).startsInText(relativeTo: anchor))
        XCTAssertNil(item(secondsFromAnchor: -60).startsInText(relativeTo: anchor))
        XCTAssertNil(item(secondsFromAnchor: -86400).startsInText(relativeTo: anchor))
    }

    func testStartsInText_NoStartTime_IsNil() {
        XCTAssertNil(ScheduleItem(id: 1, name: "TBA").startsInText(relativeTo: anchor))
    }

    // MARK: - ISO 8601

    func testISODate_Variants() {
        let base = ISODate.parse("2026-07-04T12:00:00Z")
        XCTAssertNotNil(base)
        XCTAssertEqual(ISODate.parse("2026-07-04T12:00:00+00:00"), base)
        XCTAssertEqual(ISODate.parse("2026-07-04T07:00:00-05:00"), base)
        XCTAssertEqual(ISODate.parse("2026-07-04T12:00:00.000Z"), base)
        XCTAssertEqual(ISODate.parse("2026-07-04T12:00:00.000000+00:00"), base)
        XCTAssertNil(ISODate.parse("not-a-date"))
        XCTAssertNil(ISODate.parse(""))
    }

    // MARK: - Deep links

    func testDeepLink_JoinURLs() {
        XCTAssertEqual(DeepLink.eventCode(from: URL(string: "https://attnd.app/join/FWFM2026")!), "FWFM2026")
        XCTAssertEqual(DeepLink.eventCode(from: URL(string: "https://attnd.app/join/FWFM2026/")!), "FWFM2026")
        XCTAssertEqual(DeepLink.eventCode(from: URL(string: "https://attnd.app/join/abc123")!), "abc123")
        XCTAssertEqual(DeepLink.eventCode(from: URL(string: "https://example.com/join/MYCODE")!), "MYCODE")
    }

    func testDeepLink_NonJoinURLs_AreNil() {
        XCTAssertNil(DeepLink.eventCode(from: URL(string: "https://attnd.app/events/FWFM2026")!))
        XCTAssertNil(DeepLink.eventCode(from: URL(string: "https://attnd.app/")!))
        XCTAssertNil(DeepLink.eventCode(from: URL(string: "https://attnd.app/join/")!))
        XCTAssertNil(DeepLink.eventCode(from: URL(string: "https://attnd.app/join")!))
    }

    func testDeepLink_ScannedValues() {
        XCTAssertEqual(DeepLink.eventCode(fromScanned: "https://attnd.app/join/FWFM2026/"), "FWFM2026")
        XCTAssertEqual(DeepLink.eventCode(fromScanned: "  FWFM2026 \n"), "FWFM2026")
        XCTAssertNil(DeepLink.eventCode(fromScanned: "https://example.com/menu"))
        XCTAssertNil(DeepLink.eventCode(fromScanned: "   "))
    }

    // MARK: - Query encoding

    func testQueryEncoding_SpecialCharacters() {
        // Regression: "Austin Tech & Innovation Summit" was truncated at the unencoded &.
        let encoded = APIClient.encodeQueryValue("Austin Tech & Innovation Summit")
        XCTAssertTrue(encoded.contains("%26"))
        XCTAssertFalse(encoded.contains("&"))
        XCTAssertTrue(APIClient.encodeQueryValue("A+B").contains("%2B"))
        XCTAssertTrue(APIClient.encodeQueryValue("a=b").contains("%3D"))
        XCTAssertEqual(APIClient.encodeQueryValue("FWFM2026"), "FWFM2026")
    }

    // MARK: - Push payloads

    func testPushPayload_Notification() {
        let p = PushPayload(userInfo: ["aps": ["alert": ["title": "Hi"]], "type": "notification",
                                       "event_id": 12, "notification_id": 99])
        XCTAssertEqual(p.kind, .notification)
        XCTAssertEqual(p.eventId, 12)
        XCTAssertEqual(p.notificationId, 99)
    }

    func testPushPayload_ContentUpdated_StringNumbers() {
        let p = PushPayload(userInfo: ["type": "content_updated", "event_id": "12", "content_version": "16"])
        XCTAssertEqual(p.kind, .contentUpdated)
        XCTAssertEqual(p.eventId, 12)
        XCTAssertEqual(p.contentVersion, 16)
    }

    func testPushPayload_Unknown() {
        let p = PushPayload(userInfo: ["type": "promo"])
        XCTAssertEqual(p.kind, .other("promo"))
        XCTAssertNil(p.eventId)
        XCTAssertNil(PushPayload(userInfo: [:]).kind)
    }

    // MARK: - Hex colours

    func testHexColor() {
        let c = HexColor.components("#FF8000")
        XCTAssertEqual(c?.red ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(c?.green ?? -1, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c?.blue ?? -1, 0, accuracy: 0.001)
        XCTAssertNotNil(HexColor.components("00ff00"))
        XCTAssertNil(HexColor.components(nil))
        XCTAssertNil(HexColor.components("#FFF"))
        XCTAssertNil(HexColor.components("#GGGGGG"))
    }

    // MARK: - Event days

    func testIsEventDay_UsesEventTimeZone() throws {
        let chicago = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let start = try XCTUnwrap(ISODate.parse("2026-11-14T18:00:00-06:00"))
        let end = try XCTUnwrap(ISODate.parse("2026-11-15T22:00:00-06:00"))
        // 23:30 on the 15th in Chicago is already the 16th in UTC — still an event day.
        let lateSunday = try XCTUnwrap(ISODate.parse("2026-11-15T23:30:00-06:00"))
        XCTAssertTrue(ScheduleTiming.isEventDay(now: lateSunday, start: start, end: end, timeZone: chicago))
        let monday = try XCTUnwrap(ISODate.parse("2026-11-16T09:00:00-06:00"))
        XCTAssertFalse(ScheduleTiming.isEventDay(now: monday, start: start, end: end, timeZone: chicago))
        let dayBefore = try XCTUnwrap(ISODate.parse("2026-11-13T12:00:00-06:00"))
        XCTAssertFalse(ScheduleTiming.isEventDay(now: dayBefore, start: start, end: nil, timeZone: chicago))
        XCTAssertTrue(ScheduleTiming.isEventDay(now: dayBefore, start: nil, end: nil, timeZone: chicago))
    }
}
