// APIClientIntegrationTests.swift
// AttndTests
//
// Integration tests that hit the live attnd.app API.
// All test data matches the sample_data.json fixture loaded on the production server.
//
// Event fixture summary:
//   id=1  "Fort Worth Food & Music Festival"  code=FWFM2026  10 locations  2 sent notifications
//   id=2  "Austin Tech & Innovation Summit"   code=ATIS2026  10 locations  2 sent notifications
//   id=3  "Dallas Arts & Culture Night"       code=DACN2026  10 locations  2 sent notifications

import XCTest
@testable import Attnd

final class APIClientIntegrationTests: XCTestCase {

    let api = APIClient.shared

    // MARK: - Event Lookup by Code

    func testLookupByCode_FortWorth() async throws {
        let event = try await api.lookupEvent(query: "FWFM2026")
        XCTAssertEqual(event.id, 1)
        XCTAssertEqual(event.name, "Fort Worth Food & Music Festival")
        XCTAssertEqual(event.eventCode, "FWFM2026")
        XCTAssertEqual(event.address, "Sundance Square, 420 Main St, Fort Worth, TX 76102")
        XCTAssertEqual(event.latitude,  32.7555, accuracy: 0.001)
        XCTAssertEqual(event.longitude, -97.3308, accuracy: 0.001)
        XCTAssertFalse(event.paid)
    }

    func testLookupByCode_Austin() async throws {
        let event = try await api.lookupEvent(query: "ATIS2026")
        XCTAssertEqual(event.id, 2)
        XCTAssertEqual(event.name, "Austin Tech & Innovation Summit")
        XCTAssertEqual(event.eventCode, "ATIS2026")
    }

    func testLookupByCode_Dallas() async throws {
        let event = try await api.lookupEvent(query: "DACN2026")
        XCTAssertEqual(event.id, 3)
        XCTAssertEqual(event.name, "Dallas Arts & Culture Night")
        XCTAssertEqual(event.eventCode, "DACN2026")
    }

    // MARK: - Event Lookup by Name

    func testLookupByName_FortWorth() async throws {
        let event = try await api.lookupEvent(query: "Fort Worth Food & Music Festival")
        XCTAssertEqual(event.id, 1)
        XCTAssertEqual(event.eventCode, "FWFM2026")
    }

    func testLookupByName_Austin() async throws {
        let event = try await api.lookupEvent(query: "Austin Tech & Innovation Summit")
        XCTAssertEqual(event.id, 2)
    }

    // MARK: - Lookup Not Found

    func testLookupNotFound() async throws {
        do {
            _ = try await api.lookupEvent(query: "DOESNOTEXIST99999")
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Fetch Event by ID

    func testFetchEventById_FortWorth() async throws {
        let event = try await api.event(id: 1)
        XCTAssertEqual(event.id, 1)
        XCTAssertEqual(event.name, "Fort Worth Food & Music Festival")
    }

    func testFetchEventById_Austin() async throws {
        let event = try await api.event(id: 2)
        XCTAssertEqual(event.id, 2)
        XCTAssertEqual(event.name, "Austin Tech & Innovation Summit")
    }

    func testFetchEventById_NotFound() async throws {
        do {
            _ = try await api.event(id: 99999)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Locations List

    func testLocations_FortWorth_Count() async throws {
        let list = try await api.locations(eventId: 1)
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.results.count, 10)
    }

    func testLocations_FortWorth_Names() async throws {
        let list = try await api.locations(eventId: 1)
        let names = list.results.map { $0.name }
        XCTAssertTrue(names.contains("Cattlemen's Steakhouse"))
        XCTAssertTrue(names.contains("Sundance Square Plaza"))
        XCTAssertTrue(names.contains("Billy Bob's Texas"))
        XCTAssertTrue(names.contains("Kimbell Art Museum"))
    }

    func testLocations_Austin_Count() async throws {
        let list = try await api.locations(eventId: 2)
        XCTAssertEqual(list.count, 10)
        let names = list.results.map { $0.name }
        XCTAssertTrue(names.contains("Palmer Events Center"))
        XCTAssertTrue(names.contains("Capital Factory"))
        XCTAssertTrue(names.contains("Stubb's Amphitheater"))
    }

    func testLocations_Dallas_Count() async throws {
        let list = try await api.locations(eventId: 3)
        XCTAssertEqual(list.count, 10)
        let names = list.results.map { $0.name }
        XCTAssertTrue(names.contains("Dallas Museum of Art"))
        XCTAssertTrue(names.contains("Deep Ellum"))
        XCTAssertTrue(names.contains("The Bomb Factory"))
    }

    // MARK: - Single Location

    func testFetchLocation_CattleSteak() async throws {
        let loc = try await api.location(eventId: 1, locationId: 1)
        XCTAssertEqual(loc.id, 1)
        XCTAssertEqual(loc.name, "Cattlemen's Steakhouse")
        XCTAssertEqual(loc.snippet, "Award-winning steakhouse since 1947.")
        XCTAssertEqual(loc.address, "2458 N Main St, Fort Worth, TX 76106")
        XCTAssertEqual(loc.latitude,  32.755, accuracy: 0.001)
        XCTAssertEqual(loc.longitude, -97.332, accuracy: 0.001)
        XCTAssertNil(loc.imageUrl)
        XCTAssertNil(loc.website)
        XCTAssertFalse(loc.description.isEmpty)
    }

    func testFetchLocation_PalmerEvents() async throws {
        let loc = try await api.location(eventId: 2, locationId: 11)
        XCTAssertEqual(loc.id, 11)
        XCTAssertEqual(loc.name, "Palmer Events Center")
    }

    func testFetchLocation_NotFound() async throws {
        do {
            _ = try await api.location(eventId: 1, locationId: 99999)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Notifications (API only returns sent=true)

    func testNotifications_FortWorth() async throws {
        let list = try await api.notifications(eventId: 1)
        // Fixture: notifications 1 and 2 are sent=true for event 1
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.results.count, 2)
        XCTAssertTrue(list.results.allSatisfy { $0.sent })
        let titles = list.results.map { $0.title }
        XCTAssertTrue(titles.contains("Festival kicks off tomorrow!"))
        XCTAssertTrue(titles.contains("Lineup announced for Saturday night"))
    }

    func testNotifications_Austin() async throws {
        let list = try await api.notifications(eventId: 2)
        // Fixture: notifications 5 and 6 are sent=true for event 2
        XCTAssertEqual(list.count, 2)
        let titles = list.results.map { $0.title }
        XCTAssertTrue(titles.contains("Early bird registration closes tonight"))
        XCTAssertTrue(titles.contains("Speaker spotlight: keynote revealed"))
    }

    func testNotifications_Dallas() async throws {
        let list = try await api.notifications(eventId: 3)
        // Fixture: notifications 9 and 10 are sent=true for event 3
        XCTAssertEqual(list.count, 2)
        let titles = list.results.map { $0.title }
        XCTAssertTrue(titles.contains("Venue map now available"))
        XCTAssertTrue(titles.contains("Free parking at Klyde Warren Park"))
    }

    func testNotifications_AllSent() async throws {
        // Verify the API never returns unsent notifications
        for eventId in [1, 2, 3] {
            let list = try await api.notifications(eventId: eventId)
            XCTAssertTrue(
                list.results.allSatisfy { $0.sent },
                "Event \(eventId) returned an unsent notification"
            )
        }
    }

    // MARK: - Device Join / Leave

    func testJoinAndLeaveEvent() async throws {
        // Use a unique ID so parallel test runs don't collide
        let deviceId = "ios-test-\(UUID().uuidString)"
        try await api.joinEvent(eventId: 1, deviceId: deviceId)
        // no throw = success
        try await api.leaveEvent(eventId: 1, deviceId: deviceId)
    }

    func testJoinEvent_UnknownEvent() async throws {
        do {
            try await api.joinEvent(eventId: 99999, deviceId: "ios-test-404")
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Nearby Events

    func testNearbyEvents_FortWorth_ContainsEvent1() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7555, longitude: -97.3308)
        XCTAssertGreaterThan(list.count, 0)
        let ids = list.results.map { $0.event.id }
        XCTAssertTrue(ids.contains(1), "Fort Worth event should appear near its own coordinates")
    }

    func testNearbyEvents_Austin_ContainsEvent2() async throws {
        let list = try await api.nearbyEvents(latitude: 30.2672, longitude: -97.7431)
        XCTAssertGreaterThan(list.count, 0)
        let ids = list.results.map { $0.event.id }
        XCTAssertTrue(ids.contains(2))
    }

    func testNearbyEvents_Dallas_ContainsEvent3() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7767, longitude: -96.7970)
        XCTAssertGreaterThan(list.count, 0)
        let ids = list.results.map { $0.event.id }
        XCTAssertTrue(ids.contains(3))
    }

    func testNearbyEvents_ResultShape() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7555, longitude: -97.3308)
        guard let first = list.results.first else {
            XCTFail("Expected at least one nearby event")
            return
        }
        XCTAssertGreaterThanOrEqual(first.distanceMiles, 0)
        XCTAssertFalse(first.event.name.isEmpty)
        XCTAssertFalse(first.event.eventCode.isEmpty)
        XCTAssertFalse(first.event.address.isEmpty)
        // count should match results array length
        XCTAssertEqual(list.count, list.results.count)
    }

    // MARK: - APIList Envelope

    func testAPIListEnvelope_CountMatchesResults() async throws {
        let locations = try await api.locations(eventId: 1)
        XCTAssertEqual(locations.count, locations.results.count)

        let notifications = try await api.notifications(eventId: 1)
        XCTAssertEqual(notifications.count, notifications.results.count)
    }
}
