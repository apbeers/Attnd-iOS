// APIClientIntegrationTests.swift
// AttndTests
//
// Integration tests against the live attnd.app API v2. They need a static API key
// (Config/Secrets.xcconfig or ATTND_API_KEY on the xcodebuild command line) when
// run on a simulator, where App Attest is unavailable.
//
// Fixture events (seed_test_data on the server):
//   "Fort Worth Food & Music Festival"  code=FWFM2026
//   "Austin Tech & Innovation Summit"   code=ATIS2026
//   "Dallas Arts & Culture Night"       code=DACN2026

import XCTest
@testable import Attnd

final class APIClientIntegrationTests: XCTestCase {

    private let api = APIClient.shared

    // MARK: - Lookup

    func testLookupByCode() async throws {
        let event = try await api.lookupEvent(query: "FWFM2026")
        XCTAssertEqual(event.eventCode, "FWFM2026")
        XCTAssertEqual(event.name, "Fort Worth Food & Music Festival")
        XCTAssertEqual(event.joinUrl?.absoluteString, "https://attnd.app/join/FWFM2026/")
        XCTAssertNotNil(event.timeZoneIdentifier)
    }

    func testLookupByCode_CaseInsensitive() async throws {
        let event = try await api.lookupEvent(query: "fwfm2026")
        XCTAssertEqual(event.eventCode, "FWFM2026")
    }

    func testLookupByExactName_WithAmpersand() async throws {
        let event = try await api.lookupEvent(query: "Austin Tech & Innovation Summit")
        XCTAssertEqual(event.eventCode, "ATIS2026")
    }

    func testLookupNotFound() async throws {
        do {
            _ = try await api.lookupEvent(query: "DOESNOTEXIST99999")
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Bundle

    func testBundle_LoadsEverything() async throws {
        let event = try await api.lookupEvent(query: "FWFM2026")
        guard case .updated(let bundle, let etag) = try await api.bundle(eventId: event.id, etag: nil, deviceId: nil) else {
            return XCTFail("A request without If-None-Match must return content")
        }
        XCTAssertEqual(bundle.event.id, event.id)
        XCTAssertGreaterThanOrEqual(bundle.schemaVersion, 2)
        XCTAssertFalse(bundle.locations.isEmpty)
        XCTAssertFalse(bundle.display.resolvedTabs(hasFlyer: bundle.event.flyerUrl != nil).isEmpty)
        XCTAssertNotNil(etag, "the bundle must carry an ETag")
        let starts = bundle.schedule.compactMap(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "schedule is sorted by start_time")
        let sent = bundle.notifications.compactMap(\.sendTime)
        XCTAssertEqual(sent, sent.sorted(by: >), "notifications are newest first")
    }

    func testBundle_ETagGives304() async throws {
        let event = try await api.lookupEvent(query: "FWFM2026")
        guard case .updated(_, let etag?) = try await api.bundle(eventId: event.id, etag: nil, deviceId: nil) else {
            return XCTFail("Expected content with an ETag")
        }
        let second = try await api.bundle(eventId: event.id, etag: etag, deviceId: "ios-test-\(UUID().uuidString)")
        guard case .notModified = second else {
            return XCTFail("Expected 304 Not Modified for an unchanged bundle")
        }
    }

    func testBundle_UnknownEvent() async throws {
        do {
            _ = try await api.bundle(eventId: 999_999, etag: nil, deviceId: nil)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Devices

    func testRegisterJoinLeave() async throws {
        let deviceId = "ios-test-\(UUID().uuidString)"
        let event = try await api.lookupEvent(query: "FWFM2026")

        let registered = try await api.registerDevice(deviceId: deviceId, pushToken: nil, subscribed: false)
        XCTAssertEqual(registered.status, "ok")
        XCTAssertEqual(registered.subscribed, false)

        let joined = try await api.joinEvent(eventId: event.id, deviceId: deviceId, pushToken: nil)
        XCTAssertEqual(joined.status, "ok")

        let afterJoin = try await api.registerDevice(deviceId: deviceId, pushToken: nil, subscribed: nil)
        XCTAssertEqual(afterJoin.eventId, event.id)

        let left = try await api.leaveEvent(eventId: event.id, deviceId: deviceId)
        XCTAssertEqual(left.status, "ok")
    }

    func testJoinUnknownEvent() async throws {
        do {
            try await api.joinEvent(eventId: 999_999, deviceId: "ios-test-404", pushToken: nil)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Nearby

    func testNearby_FortWorth() async throws {
        let results = try await api.nearbyEvents(latitude: 32.7555, longitude: -97.3308)
        XCTAssertTrue(results.map(\.event.eventCode).contains("FWFM2026"))
        XCTAssertTrue(results.allSatisfy { ($0.distanceMiles ?? 0) >= 0 })
    }

    func testNearby_RemoteLocation_IsEmpty() async throws {
        let results = try await api.nearbyEvents(latitude: 30.0, longitude: -40.0)
        XCTAssertTrue(results.isEmpty)
    }
}
