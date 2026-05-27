// APIClientIntegrationTests.swift
// AttndTests
//
// Integration tests that hit the live attnd.app API.
// All test data matches the sample_data.json fixture loaded on the production server.
//
// Event fixture summary:
//   id=1  "Fort Worth Food & Music Festival"  code=FWFM2026  10 locations  2 sent notifications  2 scheduled items (loc 1)
//   id=2  "Austin Tech & Innovation Summit"   code=ATIS2026  10 locations  2 sent notifications  1 scheduled item  (loc 11)
//   id=3  "Dallas Arts & Culture Night"       code=DACN2026  10 locations  2 sent notifications  0 scheduled items
//
// Scheduled item fixture:
//   pk=1  "Opening Ceremony"       event=1  location=1  start=2026-04-26T17:00:00Z
//   pk=2  "Headliner Performance"  event=1  location=1  start=2026-04-26T21:00:00Z
//   pk=3  "Food Tasting"           event=2  location=11 start=2026-04-26T12:00:00Z

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
        XCTAssertFalse(event.createdAt.isEmpty)
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
    // Uses lookupEvent (exact match, encodes & correctly via urlQueryValueAllowed).

    func testLookupByName_FortWorth() async throws {
        let event = try await api.lookupEvent(query: "Fort Worth Food & Music Festival")
        XCTAssertEqual(event.eventCode, "FWFM2026")
        XCTAssertEqual(event.name, "Fort Worth Food & Music Festival")
    }

    func testLookupByName_Austin() async throws {
        let event = try await api.lookupEvent(query: "Austin Tech & Innovation Summit")
        XCTAssertEqual(event.eventCode, "ATIS2026")
        XCTAssertEqual(event.name, "Austin Tech & Innovation Summit")
    }

    func testLookupByName_Dallas() async throws {
        let event = try await api.lookupEvent(query: "Dallas Arts & Culture Night")
        XCTAssertEqual(event.eventCode, "DACN2026")
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
    // Fixture events are seeded with start_time = now + a few hours (public=true),
    // so they always fall within the API's 3-day look-back / 7-day look-ahead window.

    func testNearbyEvents_FortWorth_ContainsFWFM2026() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7555, longitude: -97.3308)
        XCTAssertGreaterThan(list.count, 0, "Nearby events should be seeded near Fort Worth coordinates")
        let codes = list.results.map { $0.event.eventCode }
        XCTAssertTrue(codes.contains("FWFM2026"), "FWFM2026 should appear near Fort Worth coordinates")
    }

    func testNearbyEvents_Austin_ContainsATIS2026() async throws {
        let list = try await api.nearbyEvents(latitude: 30.2672, longitude: -97.7431)
        XCTAssertGreaterThan(list.count, 0, "Nearby events should be seeded near Austin coordinates")
        let codes = list.results.map { $0.event.eventCode }
        XCTAssertTrue(codes.contains("ATIS2026"), "ATIS2026 should appear near Austin coordinates")
    }

    func testNearbyEvents_Dallas_ContainsDACN2026() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7767, longitude: -96.7970)
        XCTAssertGreaterThan(list.count, 0, "Nearby events should be seeded near Dallas coordinates")
        let codes = list.results.map { $0.event.eventCode }
        XCTAssertTrue(codes.contains("DACN2026"), "DACN2026 should appear near Dallas coordinates")
    }

    func testNearbyEvents_ResultShape() async throws {
        let list = try await api.nearbyEvents(latitude: 32.7555, longitude: -97.3308)
        XCTAssertGreaterThan(list.count, 0, "Seeded Fort Worth event should always be nearby")
        guard let first = list.results.first else { return }
        XCTAssertGreaterThanOrEqual(first.distanceMiles, 0)
        XCTAssertFalse(first.event.name.isEmpty)
        XCTAssertFalse(first.event.eventCode.isEmpty)
        XCTAssertFalse(first.event.address.isEmpty)
        XCTAssertEqual(list.count, list.results.count)
    }

    func testNearbyEvents_RemoteLocation_ReturnsEmpty() async throws {
        // Middle of the Atlantic — no seeded events there
        let list = try await api.nearbyEvents(latitude: 30.0, longitude: -40.0)
        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(list.results.isEmpty)
    }

    // MARK: - APIList Envelope

    func testAPIListEnvelope_CountMatchesResults() async throws {
        let locations = try await api.locations(eventId: 1)
        XCTAssertEqual(locations.count, locations.results.count)

        let notifications = try await api.notifications(eventId: 1)
        XCTAssertEqual(notifications.count, notifications.results.count)
    }

    // MARK: - Schedule List

    func testSchedule_FortWorth_Count() async throws {
        let list = try await api.schedule(eventId: 1)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.results.count, 2)
    }

    func testSchedule_Austin_Count() async throws {
        let list = try await api.schedule(eventId: 2)
        XCTAssertEqual(list.count, 1)
    }

    func testSchedule_Dallas_Empty() async throws {
        let list = try await api.schedule(eventId: 3)
        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(list.results.isEmpty)
    }

    func testSchedule_FortWorth_Fields() async throws {
        let list = try await api.schedule(eventId: 1)
        guard let first = list.results.first else {
            XCTFail("Expected at least one scheduled item for event 1")
            return
        }
        XCTAssertGreaterThan(first.id, 0)
        XCTAssertFalse(first.name.isEmpty)
        XCTAssertFalse(first.startTime.isEmpty)
        XCTAssertGreaterThan(first.locationId, 0)
        XCTAssertFalse(first.locationName.isEmpty)
    }

    func testSchedule_FortWorth_SortedByStartTime() async throws {
        let list = try await api.schedule(eventId: 1)
        let times = list.results.map { $0.startTime }
        XCTAssertEqual(times, times.sorted(), "Schedule items must be sorted ascending by start_time")
    }

    func testSchedule_FortWorth_ItemNames() async throws {
        let list = try await api.schedule(eventId: 1)
        let names = list.results.map { $0.name }
        XCTAssertTrue(names.contains("Opening Ceremony"))
        XCTAssertTrue(names.contains("Headliner Performance"))
    }

    func testSchedule_CountMatchesEnvelope() async throws {
        for eventId in [1, 2, 3] {
            let list = try await api.schedule(eventId: eventId)
            XCTAssertEqual(
                list.count, list.results.count,
                "count field must equal results.count for event \(eventId)"
            )
        }
    }

    // MARK: - Single Scheduled Item

    func testFetchScheduledItem_FortWorth_Item1() async throws {
        let item = try await api.scheduledItem(eventId: 1, itemId: 1)
        XCTAssertEqual(item.id, 1)
        XCTAssertEqual(item.name, "Opening Ceremony")
        XCTAssertEqual(item.locationId, 1)
        XCTAssertFalse(item.locationName.isEmpty)
    }

    func testFetchScheduledItem_FortWorth_Item2() async throws {
        let item = try await api.scheduledItem(eventId: 1, itemId: 2)
        XCTAssertEqual(item.id, 2)
        XCTAssertEqual(item.name, "Headliner Performance")
    }

    func testFetchScheduledItem_NotFound() async throws {
        do {
            _ = try await api.scheduledItem(eventId: 1, itemId: 99999)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    func testFetchScheduledItem_WrongEvent_Returns404() async throws {
        // item 1 belongs to event 1; looking it up under event 2 should 404
        do {
            _ = try await api.scheduledItem(eventId: 2, itemId: 1)
            XCTFail("Expected APIError.notFound")
        } catch APIError.notFound {
            // pass
        }
    }

    // MARK: - Location scheduledItems field

    func testAllLocations_HaveScheduledItemsField() async throws {
        let list = try await api.locations(eventId: 1)
        for loc in list.results {
            // scheduledItems must decode as an array, never crash
            XCTAssertNotNil(loc.scheduledItems, "location \(loc.id) scheduledItems should not be nil")
        }
    }

    func testLocation_WithItems_CorrectCount() async throws {
        // Location pk=1 (event 1) has 2 scheduled items in the fixture
        let loc = try await api.location(eventId: 1, locationId: 1)
        XCTAssertEqual(loc.scheduledItems.count, 2)
        let names = loc.scheduledItems.map { $0.name }
        XCTAssertTrue(names.contains("Opening Ceremony"))
        XCTAssertTrue(names.contains("Headliner Performance"))
    }

    func testLocation_WithoutItems_EmptyArray() async throws {
        // Location pk=2 (event 1) has no scheduled items in the fixture
        let loc = try await api.location(eventId: 1, locationId: 2)
        XCTAssertTrue(loc.scheduledItems.isEmpty)
    }

    func testLocation_ScheduledItems_SortedByStartTime() async throws {
        let loc = try await api.location(eventId: 1, locationId: 1)
        let times = loc.scheduledItems.map { $0.startTime }
        XCTAssertEqual(times, times.sorted())
    }
}
