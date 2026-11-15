// BusinessLogicTests.swift
// AttndTests
//
// Network-free tests for small helpers:
//   - DeepLink parsing (Universal Links and scanned QR codes)
//   - query-value encoding for names containing & = +
//   - PushPayload parsing
//   - hex colours, ISO 8601 parsing, event-day detection
//   - usage counts (API-005): hour bucketing, aggregation, request body shape
//   - support code and support info text (API-004)
//   - live updates (API-007): poll intervals, content_updated handling, "last updated" text

import XCTest
@testable import Attnd

final class BusinessLogicTests: XCTestCase {

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

    // MARK: - Usage counts (API-005)

    func testUsageBucketStart_TruncatesToUTCFiveMinutes() throws {
        let date = try XCTUnwrap(ISODate.parse("2026-11-14T16:59:59-06:00")) // 22:59:59Z
        XCTAssertEqual(ISODate.string(from: UsageAggregator.bucketStart(date)), "2026-11-14T22:55:00Z")
        let mid = try XCTUnwrap(ISODate.parse("2026-11-14T16:07:30Z"))
        XCTAssertEqual(ISODate.string(from: UsageAggregator.bucketStart(mid)), "2026-11-14T16:05:00Z")
        let exact = try XCTUnwrap(ISODate.parse("2026-11-14T16:05:00Z"))
        XCTAssertEqual(UsageAggregator.bucketStart(exact), exact)
        // Non-whole-hour offsets still bucket on UTC boundaries.
        let kolkata = try XCTUnwrap(ISODate.parse("2026-11-14T21:42:10+05:30")) // 16:12:10Z
        XCTAssertEqual(ISODate.string(from: UsageAggregator.bucketStart(kolkata)), "2026-11-14T16:10:00Z")
    }

    func testUsageAggregator_CountsRepeatsByNameDetailAndBucket() throws {
        let t1 = try XCTUnwrap(ISODate.parse("2026-11-14T16:05:00Z"))
        let t2 = try XCTUnwrap(ISODate.parse("2026-11-14T16:09:59Z"))
        let nextBucket = try XCTUnwrap(ISODate.parse("2026-11-14T16:10:00Z"))
        var aggregator = UsageAggregator()
        aggregator.record(.tabView, detail: "map", eventId: 1, at: t1)
        aggregator.record(.tabView, detail: "map", eventId: 1, at: t2)
        aggregator.record(.tabView, detail: "schedule", eventId: 1, at: t2)
        aggregator.record(.tabView, detail: "map", eventId: 1, at: nextBucket)
        aggregator.record(.appOpen, eventId: 1, at: t1)
        aggregator.record(.appOpen, detail: "  ", eventId: 1, at: t2) // blank detail = none
        aggregator.record(.locationView, detail: "42", eventId: 2, at: t1)

        let drained = aggregator.drain()
        XCTAssertTrue(aggregator.isEmpty)
        XCTAssertEqual(drained[1], [
            UsageEntry(name: "app_open", detail: nil, count: 2, at: "2026-11-14T16:05:00Z"),
            UsageEntry(name: "tab_view", detail: "map", count: 2, at: "2026-11-14T16:05:00Z"),
            UsageEntry(name: "tab_view", detail: "schedule", count: 1, at: "2026-11-14T16:05:00Z"),
            UsageEntry(name: "tab_view", detail: "map", count: 1, at: "2026-11-14T16:10:00Z"),
        ])
        XCTAssertEqual(drained[2], [
            UsageEntry(name: "location_view", detail: "42", count: 1, at: "2026-11-14T16:05:00Z"),
        ])
        XCTAssertTrue(aggregator.drain().isEmpty)
    }

    func testUsageChunks_LimitEntriesPerRequest() {
        let entries = (0..<450).map { UsageEntry(name: "location_view", detail: String($0), count: 1, at: "2026-11-14T16:00:00Z") }
        let chunks = UsageAggregator.chunks(entries)
        XCTAssertEqual(chunks.map(\.count), [200, 200, 50])
        XCTAssertEqual(chunks.flatMap { $0 }, entries)
        XCTAssertTrue(UsageAggregator.chunks([]).isEmpty)
    }

    func testUsageRequest_BodyShape() throws {
        let body = UsageRequest(events: [
            UsageEntry(name: "tab_view", detail: "map", count: 3, at: "2026-11-14T16:00:00Z"),
            UsageEntry(name: "app_open", detail: nil, count: 1, at: "2026-11-14T16:00:00Z"),
        ])
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["platform", "events"])
        XCTAssertEqual(json["platform"] as? String, "ios")
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events[0].keys), ["name", "detail", "count", "at"])
        XCTAssertEqual(events[0]["name"] as? String, "tab_view")
        XCTAssertEqual(events[0]["detail"] as? String, "map")
        XCTAssertEqual(events[0]["count"] as? Int, 3)
        XCTAssertEqual(events[0]["at"] as? String, "2026-11-14T16:00:00Z")
        // detail is omitted, not null, when there is none.
        XCTAssertEqual(Set(events[1].keys), ["name", "count", "at"])
        // Nothing identifying is ever sent.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("device"))
    }

    func testUsageMetric_WireNames() {
        XCTAssertEqual(UsageMetric.allCases.map(\.rawValue), [
            "app_open", "tab_view", "location_view", "schedule_item_view", "notification_open", "search", "refresh",
            "location_heart", "location_unheart", "schedule_item_heart", "schedule_item_unheart",
            "perf_launch_cold", "perf_launch_warm", "perf_bundle_fetch", "perf_bundle_304", "perf_api_error",
            "perf_push_refresh_delay", "perf_live_start_fail", "perf_planner_ms", "perf_map_first_render",
        ])
        // tab_view details: the event tabs' raw values, and "options" for the Options sheet.
        XCTAssertEqual(EventTab.allCases.map(\.rawValue), ["map", "locations", "schedule", "flyer", "notifications"])
        XCTAssertEqual(EventSheet.options.usageDetail, "options")
        // The search sheet has no tab_view detail (the server only accepts the event tabs and options).
        XCTAssertNil(EventSheet.search.usageDetail)
    }

    // MARK: - Support info (API-004)

    func testSupportCode_FirstEightWithoutDashesUppercased() {
        XCTAssertEqual(SupportInfo.supportCode(deviceId: "3f2a9c1e-7b4d-4e2a-9c1e-000000000000"), "3F2A9C1E")
        XCTAssertEqual(SupportInfo.supportCode(deviceId: "ab-cd-ef12-3456"), "ABCDEF12")
        XCTAssertEqual(SupportInfo.supportCode(deviceId: "abc"), "ABC")
    }

    func testSupportInfo_PlainTextIncludesEverything() throws {
        var info = SupportInfo(
            appVersion: "2.0.57", buildNumber: "57", serverHost: "attnd-dev.example.com", apiVersion: 2,
            osVersion: "26.1", deviceModel: "iPhone17,2", isAppClip: false,
            deviceId: "3f2a9c1e-7b4d-4e2a-9c1e-000000000000"
        )
        XCTAssertFalse(info.isProductionServer)
        var text = info.plainText
        XCTAssertTrue(text.contains("Support code: 3F2A9C1E"))
        XCTAssertTrue(text.contains("3f2a9c1e-7b4d-4e2a-9c1e-000000000000"))
        XCTAssertTrue(text.contains("2.0.57 (57)"))
        XCTAssertTrue(text.contains("attnd-dev.example.com"))
        XCTAssertTrue(text.contains("API version: 2"))
        XCTAssertTrue(text.contains("iOS 26.1"))
        XCTAssertTrue(text.contains("iPhone17,2"))
        XCTAssertTrue(text.contains("Event: none"))
        XCTAssertTrue(text.contains("Last refresh: never"))

        info.serverHost = "attnd.app"
        info.eventName = "Fall Fest"
        info.eventCode = "FALL26"
        info.eventId = 7
        info.contentVersion = 12
        info.lastRefreshed = try XCTUnwrap(ISODate.parse("2026-11-14T16:05:00Z"))
        XCTAssertTrue(info.isProductionServer)
        text = info.plainText
        XCTAssertTrue(text.contains("Event: Fall Fest (code FALL26, id 7)"))
        XCTAssertTrue(text.contains("Content version: 12"))
        XCTAssertTrue(text.contains("Last refresh: 2026-11-14T16:05:00Z"))
    }


    // MARK: - Live updates (API-007)

    func testLiveRefreshInterval_DependsOnPush() {
        XCTAssertEqual(LiveRefreshPolicy.interval(canReceivePush: true), .seconds(300))
        XCTAssertEqual(LiveRefreshPolicy.interval(canReceivePush: false), .seconds(60))
        XCTAssertEqual(LiveRefreshPolicy.interval(canReceivePush: true, lastRefreshFailed: true), .seconds(15))
        XCTAssertEqual(LiveRefreshPolicy.interval(canReceivePush: false, lastRefreshFailed: true), .seconds(15))
    }

    func testCanReceivePush_NeedsTokenRegistrationAndFullApp() {
        XCTAssertTrue(LiveRefreshPolicy.canReceivePush(pushToken: "ff00", registrationFailed: false, isAppClip: false))
        XCTAssertFalse(LiveRefreshPolicy.canReceivePush(pushToken: nil, registrationFailed: false, isAppClip: false))
        XCTAssertFalse(LiveRefreshPolicy.canReceivePush(pushToken: "", registrationFailed: false, isAppClip: false))
        XCTAssertFalse(LiveRefreshPolicy.canReceivePush(pushToken: "ff00", registrationFailed: true, isAppClip: false))
        XCTAssertFalse(LiveRefreshPolicy.canReceivePush(pushToken: "ff00", registrationFailed: false, isAppClip: true),
                       "the App Clip can't get pushes")
    }

    func testContentUpdated_RefreshesOnlyForNewerVersions() {
        XCTAssertTrue(ContentUpdatePolicy.shouldRefresh(pushedVersion: 16, currentVersion: 15))
        XCTAssertFalse(ContentUpdatePolicy.shouldRefresh(pushedVersion: 15, currentVersion: 15))
        XCTAssertFalse(ContentUpdatePolicy.shouldRefresh(pushedVersion: 14, currentVersion: 15))
        XCTAssertTrue(ContentUpdatePolicy.shouldRefresh(pushedVersion: nil, currentVersion: 15), "no version: refetch")
        XCTAssertTrue(ContentUpdatePolicy.shouldRefresh(pushedVersion: 3, currentVersion: nil), "nothing loaded yet")
    }

    func testContentUpdated_JitterIsWithinTenSeconds() {
        for _ in 0..<200 {
            let delay = ContentUpdatePolicy.jitter()
            XCTAssertGreaterThanOrEqual(delay, .zero)
            XCTAssertLessThanOrEqual(delay, .seconds(10))
        }
    }

    func testRefreshProblem_FromErrors() {
        XCTAssertEqual(RefreshProblem(APIError.networkError("offline")), .offline)
        XCTAssertEqual(RefreshProblem(APIError.serverError(503)), .serverError)
        XCTAssertEqual(RefreshProblem(APIError.unauthorized), .serverError)
    }

    func testLastUpdatedText_UsesDeviceZoneAndShowsDateWhenNotToday() throws {
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISODate.parse("2026-11-14T18:00:00Z"))
        let today = try XCTUnwrap(ISODate.parse("2026-11-14T15:41:00Z"))
        let yesterday = try XCTUnwrap(ISODate.parse("2026-11-13T15:41:00Z"))

        let todayText = LastUpdatedText.time(today, now: now, timeZone: utc, locale: posix)
        XCTAssertTrue(todayText.contains("3:41"), todayText)
        XCTAssertFalse(todayText.contains("Nov"), todayText)

        let olderText = LastUpdatedText.time(yesterday, now: now, timeZone: utc, locale: posix)
        XCTAssertTrue(olderText.contains("Nov 13"), olderText)

        // The same instant in another device zone reads differently ("last updated" is device time).
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertTrue(LastUpdatedText.time(today, now: now, timeZone: tokyo, locale: posix).contains("12:41"))

        let badge = LastUpdatedText.badgeTitle(.offline, lastRefreshed: today, now: now, timeZone: utc, locale: posix)
        XCTAssertTrue(badge.hasPrefix("Offline · Updated "), badge)
        XCTAssertTrue(badge.contains("3:41"), badge)
        XCTAssertEqual(LastUpdatedText.badgeTitle(.offline, lastRefreshed: nil), "Offline")
        XCTAssertTrue(LastUpdatedText.badgeTitle(.serverError, lastRefreshed: today, now: now, timeZone: utc, locale: posix)
            .hasPrefix("Can't update · Updated "))
    }
}
