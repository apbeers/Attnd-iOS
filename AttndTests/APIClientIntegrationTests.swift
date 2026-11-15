// APIClientIntegrationTests.swift
// AttndTests
//
// Live integration tests: the app's real `APIClient` against a running Attnd server (API v2),
// using the DEMO event (attnd-web `load_demo_event`; regenerated in place so it is always
// happening now). The facts asserted here come from the shared spec; if the server's demo data
// changes, attnd-web's own test of `load_demo_event` is the source of truth — update all three
// repos together.
//
// Configuration (environment of the test process; nothing is compiled in):
//   ATTND_IT_SERVER  host, e.g. dev.attnd.app or attnd.app
//   ATTND_IT_KEY     static bearer key the server accepts (dev: its API_KEY; prod: the CI key,
//                    which only works for the DEMO event)
//   ATTND_IT_RUN_ID  optional, used in device ids (CI passes the workflow run id)
// When the server or key is missing, every test is skipped (XCTSkip), so local unit test runs
// are unaffected.
//
// xcodebuild only forwards variables prefixed with TEST_RUNNER_ to the test process (prefix
// stripped), so pass them like this (scripts/ci/test.sh integration does):
//   TEST_RUNNER_ATTND_IT_SERVER=dev.attnd.app TEST_RUNNER_ATTND_IT_KEY=… \
//     xcodebuild test … -only-testing:AttndTests/APIClientIntegrationTests
// In Xcode, add ATTND_IT_SERVER / ATTND_IT_KEY to the scheme's Test action environment instead
// (locally only; never commit a key).

import XCTest
@testable import Attnd

final class APIClientIntegrationTests: XCTestCase {

    // MARK: - Configuration

    private struct Live: Sendable {
        let host: String
        let key: String
        let runId: String

        static func fromEnvironment() -> Live? {
            let env = ProcessInfo.processInfo.environment
            func value(_ name: String) -> String? {
                guard let v = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty,
                      !v.hasPrefix("$(") else { return nil }
                return v
            }
            guard var host = value("ATTND_IT_SERVER"), let key = value("ATTND_IT_KEY") else { return nil }
            // Accept "https://host/" as well as a bare host.
            for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
                host.removeFirst(prefix.count)
            }
            while host.hasSuffix("/") { host.removeLast() }
            return Live(host: host, key: key, runId: value("ATTND_IT_RUN_ID") ?? "local")
        }
    }

    /// The configured server, or an XCTSkip.
    private func liveServer() throws -> Live {
        guard let live = Live.fromEnvironment() else {
            throw XCTSkip("ATTND_IT_SERVER / ATTND_IT_KEY not set (pass TEST_RUNNER_ATTND_IT_SERVER and TEST_RUNNER_ATTND_IT_KEY to xcodebuild)")
        }
        return live
    }

    /// The app's client, pointed at the configured server with the configured key (no App Attest).
    private func client(_ live: Live) -> APIClient {
        APIClient(serverHost: live.host, apiKey: live.key)
    }

    /// "ci-ios-<run id>-<random>": unique per test, recognisable on the server.
    private func deviceId(_ live: Live) -> String {
        "ci-ios-\(live.runId)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func demo(_ api: APIClient) async throws -> Event {
        try await api.lookupEvent(query: "DEMO")
    }

    private func json(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "expected a JSON object")
    }

    private func usageBody(_ events: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["platform": "ios", "events": events])
    }

    // MARK: - 1. App status (unversioned, unauthenticated)

    func testAppStatus_AnswersForThisBuild() async throws {
        let live = try liveServer()
        // No key at all: app-status must work without Authorization.
        let status = try await APIClient(serverHost: live.host, apiKey: "").appStatus()
        XCTAssertNotNil(status.updateURL, "update_url is always set")
        if let min = status.minVersion { XCTAssertFalse(min.isEmpty) }
    }

    func testAppStatus_RetiredApiVersionIsRequired() async throws {
        let live = try liveServer()
        let status = try await APIClient(serverHost: live.host, apiKey: "", apiVersion: 9).appStatus()
        XCTAssertEqual(status.update, .required, "a build speaking an unserved API version must update")
    }

    // MARK: - 2. Lookup

    func testLookup_DemoAnyCaseAndWhitespace() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        for query in ["demo", " Demo ", "DeMo"] {
            let other = try await api.lookupEvent(query: query)
            XCTAssertEqual(other.id, event.id, "lookup '\(query)'")
            XCTAssertEqual(other.eventCode, "DEMO")
        }
    }

    func testLookup_DemoEventFacts() async throws {
        let event = try await demo(client(liveServer()))
        XCTAssertEqual(event.eventCode, "DEMO")
        XCTAssertEqual(event.name, "Demo: Fort Worth Food & Music Festival")
        XCTAssertEqual(event.timeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(event.status, .published)
        XCTAssertTrue(event.paid)
        XCTAssertFalse(event.isDemo, "paid event → is_demo false")
        XCTAssertEqual(event.address, "Panther Island, Fort Worth, TX 76102")
        let centre = try XCTUnwrap(event.coordinate, "the event has coordinates")
        XCTAssertEqual(centre.latitude, 32.7495, accuracy: 0.001)
        XCTAssertEqual(centre.longitude, -97.3316, accuracy: 0.001)
        let now = Date()
        let start = try XCTUnwrap(event.startTime)
        let end = try XCTUnwrap(event.endTime)
        XCTAssertLessThanOrEqual(start, now, "DEMO is always happening now")
        XCTAssertGreaterThanOrEqual(end, now, "DEMO is always happening now")
        XCTAssertGreaterThanOrEqual(event.contentVersion, 1)
        XCTAssertTrue(event.joinUrl?.absoluteString.hasSuffix("/join/DEMO/") ?? false, "join_url ends in /join/DEMO/")
    }

    func testLookup_UnknownCodeIsNotFound() async throws {
        let api = try client(liveServer())
        do {
            _ = try await api.lookupEvent(query: "CI-NO-SUCH-EVENT-\(UUID().uuidString.prefix(8))")
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    func testLookup_MissingAuthIsUnauthorized() async throws {
        let live = try liveServer()
        // Empty key, no attestation → no Authorization header at all.
        let api = APIClient(serverHost: live.host, apiKey: "")
        do {
            _ = try await api.lookupEvent(query: "DEMO")
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // pass
        }
    }

    func testLookup_WrongKeyIsUnauthorized() async throws {
        let live = try liveServer()
        let api = APIClient(serverHost: live.host, apiKey: "ci-wrong-\(UUID().uuidString)")
        do {
            _ = try await api.lookupEvent(query: "DEMO")
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // pass
        }
    }

    // MARK: - 3. Bundle and ETags

    func testBundle_ETagRoundTrip() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        // The demo can be regenerated between two requests (new content_version → new ETag), so
        // allow one retry before calling a missing 304 a failure.
        var lastStatus = 0
        for _ in 0..<2 {
            guard case .updated(_, let etag?, _) = try await api.bundle(eventId: event.id, etag: nil, deviceId: nil) else {
                return XCTFail("A request without If-None-Match must return content with an ETag")
            }
            let (data, http) = try await api.send("events/\(event.id)/bundle/", headers: ["If-None-Match": etag])
            lastStatus = http.statusCode
            if http.statusCode == 304 {
                XCTAssertTrue(data.isEmpty, "a 304 has no body")
                // And the same through the app's own bundle call.
                if case .updated = try await api.bundle(eventId: event.id, etag: etag, deviceId: nil) {
                    continue // changed in between; try once more
                }
                return
            }
        }
        XCTFail("Expected 304 for an unchanged bundle, got \(lastStatus)")
    }

    func testBundle_StaleETagGivesContent() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        for stale in ["\"garbage\"", "\"e\(event.id)-v0\"", "W/\"nope\""] {
            guard case .updated(let bundle, let etag, _) = try await api.bundle(eventId: event.id, etag: stale, deviceId: nil) else {
                XCTFail("If-None-Match \(stale) must give 200 with content")
                continue
            }
            XCTAssertEqual(bundle.event.id, event.id)
            XCTAssertNotNil(etag)
        }
    }

    func testBundle_UnknownEventIsNotFound() async throws {
        let api = try client(liveServer())
        do {
            _ = try await api.bundle(eventId: 999_999_999, etag: nil, deviceId: nil)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - 4. Join / leave

    func testJoinLeave_Idempotent() async throws {
        let live = try liveServer()
        let api = client(live)
        let event = try await demo(api)
        let device = deviceId(live)
        addTeardownBlock { _ = try? await api.leaveEvent(eventId: event.id, deviceId: device) }

        let joined = try await api.joinEvent(eventId: event.id, deviceId: device, pushToken: nil)
        XCTAssertEqual(joined.status, "ok")
        XCTAssertGreaterThanOrEqual(joined.contentVersion ?? 0, 1)
        let again = try await api.joinEvent(eventId: event.id, deviceId: device, pushToken: nil)
        XCTAssertEqual(again.status, "ok", "joining twice is fine")

        let afterJoin = try await api.registerDevice(deviceId: device, pushToken: nil, subscribed: nil)
        XCTAssertEqual(afterJoin.eventId, event.id)

        // X-Device-Id on the bundle is accepted for a joined device.
        guard case .updated = try await api.bundle(eventId: event.id, etag: nil, deviceId: device) else {
            return XCTFail("Expected content")
        }

        let left = try await api.leaveEvent(eventId: event.id, deviceId: device)
        XCTAssertEqual(left.status, "ok")
        let leftAgain = try await api.leaveEvent(eventId: event.id, deviceId: device)
        XCTAssertEqual(leftAgain.status, "ok", "leaving twice is fine")

        let afterLeave = try await api.registerDevice(deviceId: device, pushToken: nil, subscribed: nil)
        XCTAssertNil(afterLeave.eventId, "event_id is null after leaving")
    }

    func testJoin_UnknownEventIsNotFound() async throws {
        let live = try liveServer()
        let api = client(live)
        do {
            try await api.joinEvent(eventId: 999_999_999, deviceId: deviceId(live), pushToken: nil)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - 5. Devices

    func testDevices_TokenAndSubscribed() async throws {
        let live = try liveServer()
        let api = client(live)
        let device = deviceId(live)

        let registered = try await api.registerDevice(deviceId: device, pushToken: "ci-\(UUID().uuidString)", subscribed: false)
        XCTAssertEqual(registered.status, "ok")
        XCTAssertEqual(registered.subscribed, false)
        XCTAssertNil(registered.eventId, "a new device has joined nothing")

        // No token: omitted from the body (never ""), and the rest is unchanged.
        let withoutToken = try await api.registerDevice(deviceId: device, pushToken: nil, subscribed: nil)
        XCTAssertEqual(withoutToken.status, "ok")
        XCTAssertEqual(withoutToken.subscribed, false, "an omitted subscribed keeps the stored value")

        // An empty token is dropped by the client, never sent as "" (which would clear it).
        let emptyToken = try await api.registerDevice(deviceId: device, pushToken: "", subscribed: false)
        XCTAssertEqual(emptyToken.status, "ok")
        let body = try JSONEncoder().encode(
            DeviceRequest(deviceId: device, pushToken: APIClient.nonEmpty(""), appVersion: api.appVersion, subscribed: false))
        XCTAssertNil(try json(body)["push_token"], "push_token must be omitted, not \"\"")
    }

    // MARK: - 6. Usage (API-005)

    func testUsage_ValidBatchIsAccepted() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        let at = ISODate.string(from: UsageAggregator.bucketStart(Date()))
        let entries = [
            UsageEntry(name: UsageMetric.appOpen.rawValue, detail: nil, count: 1, at: at),
            UsageEntry(name: UsageMetric.tabView.rawValue, detail: "map", count: 2, at: at),
        ]
        // The app's own call (throws on any non-2xx).
        try await api.sendUsage(eventId: event.id, entries: entries)

        // Same body through the same path, reading the accepted count.
        let data = try JSONEncoder().encode(UsageRequest(events: entries))
        let (response, http) = try await api.send("events/\(event.id)/usage/", method: "POST", body: data)
        XCTAssertEqual(http.statusCode, 200)
        let answer = try json(response)
        XCTAssertEqual(answer["status"] as? String, "ok")
        XCTAssertEqual(answer["accepted"] as? Int, 2)
    }

    /// API_V2.md: unknown names and invalid details are dropped silently and a malformed body still
    /// returns 200 — analytics must never make an app request fail. (Not a 400.)
    func testUsage_InvalidEntriesAreDroppedNotRejected() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        let path = "events/\(event.id)/usage/"

        let bad = try usageBody([["name": "not_a_metric"], ["name": "tab_view", "detail": "bogus"],
                                 ["name": "location_view", "detail": "999999999"]])
        let (badAnswer, badHTTP) = try await api.send(path, method: "POST", body: bad)
        XCTAssertEqual(badHTTP.statusCode, 200)
        XCTAssertEqual(try json(badAnswer)["accepted"] as? Int, 0, "invalid entries are dropped")

        // A bad `at` never fails the request (the server places the count in the current window).
        let badAt = try usageBody([["name": "app_open", "at": "not-a-date"]])
        let (_, badAtHTTP) = try await api.send(path, method: "POST", body: badAt)
        XCTAssertEqual(badAtHTTP.statusCode, 200)

        let (garbageAnswer, garbageHTTP) = try await api.send(path, method: "POST", body: Data("not json".utf8))
        XCTAssertEqual(garbageHTTP.statusCode, 200, "a malformed body still returns 200")
        XCTAssertEqual(try json(garbageAnswer)["accepted"] as? Int, 0)
    }

    func testUsage_EmptyBatchIsNoOp() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        try await api.sendUsage(eventId: event.id, entries: []) // the client sends nothing
        let (answer, http) = try await api.send("events/\(event.id)/usage/", method: "POST", body: try usageBody([[String: Any]]()))
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(try json(answer)["accepted"] as? Int, 0)
    }

    func testUsage_UnknownEventIsNotFound() async throws {
        let api = try client(liveServer())
        let entry = UsageEntry(name: "app_open", detail: nil, count: 1, at: ISODate.string(from: UsageAggregator.bucketStart(Date())))
        do {
            try await api.sendUsage(eventId: 999_999_999, entries: [entry])
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - 7. Retired API version

    func testRetiredApiVersion_UpdateRequired() async throws {
        let live = try liveServer()
        // The app's client speaking a version the server doesn't serve maps 410 to updateRequired.
        let retired = APIClient(serverHost: live.host, apiKey: live.key, apiVersion: 9)
        do {
            _ = try await retired.lookupEvent(query: "DEMO")
            XCTFail("Expected APIError.updateRequired")
        } catch APIError.updateRequired {
            // pass
        }

        // The body: 410 {"error": "update_required", "update_url": …}.
        let url = try XCTUnwrap(URL(string: "https://\(live.host)/api/v9/events/lookup/?q=DEMO"))
        var request = URLRequest(url: url)
        request.setValue("Bearer \(live.key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 410)
        let body = try json(data)
        XCTAssertEqual(body["error"] as? String, "update_required")
        XCTAssertFalse((body["update_url"] as? String ?? "").isEmpty, "update_url is set")
    }

    // MARK: - 8. Decoding the full live bundle

    func testBundle_DecodesEverythingAndMatchesDemo() async throws {
        let api = try client(liveServer())
        let event = try await demo(api)
        guard case .updated(let bundle, let etag, let data) = try await api.bundle(eventId: event.id, etag: nil, deviceId: nil) else {
            return XCTFail("A request without If-None-Match must return content")
        }
        XCTAssertNotNil(etag)

        // Nothing dropped by the lenient decoders: decoded counts equal the raw JSON arrays.
        let raw = try json(data)
        func rawCount(_ key: String) -> Int? { (raw[key] as? [Any])?.count }
        XCTAssertEqual(bundle.locations.count, rawCount("locations"))
        XCTAssertEqual(bundle.schedule.count, rawCount("schedule"))
        XCTAssertEqual(bundle.notifications.count, rawCount("notifications"))
        XCTAssertEqual(bundle.categories.count, rawCount("categories"))
        XCTAssertEqual(bundle.schemaVersion, 2)
        XCTAssertGreaterThanOrEqual(bundle.contentVersion, 1)
        XCTAssertEqual(bundle.event.id, event.id)

        // Display: festival preset (resolved by the server), now/next beside the map.
        let rawDisplay = try XCTUnwrap(raw["display"] as? [String: Any])
        XCTAssertEqual(rawDisplay["resolved_preset"] as? String ?? rawDisplay["preset"] as? String, "festival")
        XCTAssertEqual(bundle.display.secondaryPane, .nowNext)
        let tabs = bundle.display.resolvedTabs(hasFlyer: bundle.event.flyerUrl != nil)
        for tab in [EventTab.map, .locations, .schedule, .notifications] {
            XCTAssertTrue(tabs.contains(tab), "tabs include \(tab.rawValue)")
        }

        // Locations: 18; only Roaming Mariachi has no coordinates; the rest are near the centre.
        XCTAssertEqual(bundle.locations.count, 18)
        let centre = try XCTUnwrap(bundle.event.coordinate)
        for location in bundle.locations {
            if location.name == "Roaming Mariachi" {
                XCTAssertNil(location.latitude)
                XCTAssertNil(location.longitude)
                XCTAssertNil(location.coordinate)
                XCTAssertEqual(location.category, "Stage")
            } else {
                let c = try XCTUnwrap(location.coordinate, "\(location.name) has coordinates")
                XCTAssertEqual(c.latitude, centre.latitude, accuracy: 0.01, location.name)
                XCTAssertEqual(c.longitude, centre.longitude, accuracy: 0.01, location.name)
            }
        }
        let names = Set(bundle.locations.map(\.name))
        for name in ["Main Stage", "Trinity Stage", "Panther Island Pavilion", "Chef Demo Kitchen", "Taco Row",
                     "BBQ Pit Lane", "Sweet Spot", "Craft Beer Garden", "Lemonade Stand", "Makers Market",
                     "Kids Zone", "First Aid", "Info Booth", "Restrooms North", "Restrooms South",
                     "Rideshare Pickup", "Overflow Parking", "Roaming Mariachi"] {
            XCTAssertTrue(names.contains(name), "location \(name)")
        }
        let categories: Set<String> = ["Stage", "Food", "Drinks", "Vendor", "Family", "Services", "Parking"]
        XCTAssertEqual(Set(bundle.locations.compactMap(\.category)), categories)
        XCTAssertEqual(Set(bundle.categories), categories)
        let mainStage = try XCTUnwrap(bundle.locations.first { $0.name == "Main Stage" })
        XCTAssertEqual(mainStage.category, "Stage")
        XCTAssertEqual(mainStage.snippet, "Headliners every night")
        XCTAssertTrue(mainStage.description.hasPrefix("The big one: headliners each night"))

        // Schedule: 51 items, sorted, start < end, 3 without a location, now/next non-empty.
        XCTAssertEqual(bundle.schedule.count, 51)
        let starts = bundle.schedule.compactMap(\.startTime)
        XCTAssertEqual(starts.count, 51, "every item has a start time")
        XCTAssertEqual(starts, starts.sorted(), "schedule is sorted by start_time")
        for item in bundle.schedule {
            if let start = item.startTime, let end = item.endTime {
                XCTAssertLessThan(start, end, item.name)
            } else {
                XCTFail("\(item.name) has start and end times")
            }
        }
        let general = bundle.schedule.filter { $0.locationId == nil }
        XCTAssertEqual(general.count, 3)
        XCTAssertTrue(general.allSatisfy { $0.tags == ["General"] && $0.locationName == nil })
        XCTAssertEqual(Set(general.map(\.name)), ["Opening ceremony", "Gates open"])
        let stages: Set<String> = ["Main Stage", "Trinity Stage", "Panther Island Pavilion"]
        let music = bundle.schedule.filter { $0.tags.contains("Music") }
        XCTAssertEqual(music.count, 36)
        XCTAssertTrue(music.allSatisfy { stages.contains($0.locationName ?? "") }, "music is on the three stages")
        XCTAssertEqual(bundle.schedule.filter { $0.locationName == "Chef Demo Kitchen" }.count, 9)
        let kids = bundle.schedule.filter { $0.locationName == "Kids Zone" }
        XCTAssertEqual(kids.count, 3)
        XCTAssertTrue(kids.allSatisfy { $0.name == "Face painting & games" && $0.tags.contains("Family") })
        let now = Date()
        XCTAssertTrue(bundle.schedule.contains { ($0.endTime ?? .distantPast) > now }, "something is on now or next")
        let locationIds = Set(bundle.locations.map(\.id))
        for item in bundle.schedule {
            if let id = item.locationId { XCTAssertTrue(locationIds.contains(id), "\(item.name) points at a bundle location") }
        }

        // Notifications: the 4 sent at load, plus the 2 load_demo_event schedules ("Headliner soon" +90 min,
        // "Day 2" +24 h) once the scheduler has sent them; newest first.
        let titles = Set(bundle.notifications.map(\.title))
        let sentAtLoad: Set<String> = ["Welcome!", "Taco Row is open", "Shade & water", "Set time change"]
        XCTAssertTrue(titles.isSuperset(of: sentAtLoad), "the four sent at load: \(titles)")
        XCTAssertTrue(titles.isSubset(of: sentAtLoad.union(["Headliner soon", "Day 2"])), "unexpected notifications: \(titles)")
        XCTAssertEqual(titles.count, bundle.notifications.count, "no duplicate notifications")
        let sent = bundle.notifications.compactMap(\.sendTime)
        XCTAssertEqual(sent.count, bundle.notifications.count, "every notification has a send time")
        XCTAssertEqual(sent, sent.sorted(by: >), "notifications are newest first")
        XCTAssertTrue(sent.allSatisfy { $0 <= now.addingTimeInterval(60) }, "no future notifications")
    }
}
