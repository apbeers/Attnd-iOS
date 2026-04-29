// ModelDecodingTests.swift
// AttndTests
//
// Unit tests for JSON → Swift model decoding.
// No network required — all input is inline JSON strings.
// Tests every model type in Helpers.swift, including the new ScheduledItem
// and the scheduled_items array embedded in Location.

import XCTest
@testable import Attnd

final class ModelDecodingTests: XCTestCase {

    // MARK: - Helper

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Event

    func testEvent_Decodes_AllFields() throws {
        let json = """
        {
          "id": 1,
          "name": "Fort Worth Food & Music Festival",
          "event_code": "FWFM2026",
          "description": "Annual food and music festival.",
          "latitude": 32.7555,
          "longitude": -97.3308,
          "start_time": "2026-04-26T18:00:00Z",
          "created_at": "2026-01-15T09:00:00Z",
          "paid": false,
          "flyer_url": null,
          "address": "Sundance Square, Fort Worth, TX"
        }
        """
        let event = try decode(Event.self, from: json)
        XCTAssertEqual(event.id, 1)
        XCTAssertEqual(event.name, "Fort Worth Food & Music Festival")
        XCTAssertEqual(event.eventCode, "FWFM2026")
        XCTAssertEqual(event.description, "Annual food and music festival.")
        XCTAssertEqual(event.latitude,  32.7555,  accuracy: 0.0001)
        XCTAssertEqual(event.longitude, -97.3308, accuracy: 0.0001)
        XCTAssertEqual(event.startTime, "2026-04-26T18:00:00Z")
        XCTAssertEqual(event.createdAt, "2026-01-15T09:00:00Z")
        XCTAssertFalse(event.paid)
        XCTAssertNil(event.flyerUrl)
        XCTAssertEqual(event.address, "Sundance Square, Fort Worth, TX")
    }

    func testEvent_Paid_True() throws {
        let json = """
        {"id":2,"name":"Paid Event","event_code":"PAY001","description":"desc",
         "latitude":0,"longitude":0,"start_time":"2026-01-01T00:00:00Z",
         "created_at":"2025-12-01T00:00:00Z","paid":true,"flyer_url":null,"address":""}
        """
        XCTAssertTrue(try decode(Event.self, from: json).paid)
    }

    func testEvent_FlyerUrl_NonNull() throws {
        let json = """
        {"id":3,"name":"Flyer Event","event_code":"FLY001","description":"",
         "latitude":0,"longitude":0,"start_time":"2026-01-01T00:00:00Z",
         "created_at":"2025-12-01T00:00:00Z",
         "paid":false,"flyer_url":"https://example.com/flyer.pdf","address":""}
        """
        let event = try decode(Event.self, from: json)
        XCTAssertEqual(event.flyerUrl, "https://example.com/flyer.pdf")
    }

    func testEvent_SnakeCaseMapping() throws {
        // Verifies that event_code, start_time, created_at, flyer_url map to Swift camelCase names
        let json = """
        {"id":1,"name":"X","event_code":"ABC123","description":"","latitude":0,
         "longitude":0,"start_time":"2026-06-01T10:00:00Z",
         "created_at":"2026-01-01T00:00:00Z","paid":false,"flyer_url":null,"address":""}
        """
        let event = try decode(Event.self, from: json)
        XCTAssertEqual(event.eventCode, "ABC123")
        XCTAssertEqual(event.startTime, "2026-06-01T10:00:00Z")
        XCTAssertEqual(event.createdAt, "2026-01-01T00:00:00Z")
    }

    // MARK: - ScheduledItem

    func testScheduledItem_Decodes_AllFields() throws {
        let json = """
        {
          "id": 1,
          "name": "Opening Ceremony",
          "description": "Welcome to the festival.",
          "start_time": "2026-04-26T17:00:00+00:00",
          "location_id": 1,
          "location_name": "Main Stage"
        }
        """
        let item = try decode(ScheduledItem.self, from: json)
        XCTAssertEqual(item.id, 1)
        XCTAssertEqual(item.name, "Opening Ceremony")
        XCTAssertEqual(item.description, "Welcome to the festival.")
        XCTAssertEqual(item.startTime, "2026-04-26T17:00:00+00:00")
        XCTAssertEqual(item.locationId, 1)
        XCTAssertEqual(item.locationName, "Main Stage")
    }

    func testScheduledItem_SnakeCaseMapping() throws {
        let json = """
        {"id":2,"name":"Headliner","description":"Main act.",
         "start_time":"2026-04-26T21:00:00Z","location_id":5,"location_name":"Big Stage"}
        """
        let item = try decode(ScheduledItem.self, from: json)
        XCTAssertEqual(item.locationId, 5)
        XCTAssertEqual(item.locationName, "Big Stage")
    }

    func testScheduledItem_EmptyDescription() throws {
        let json = """
        {"id":3,"name":"Intermission","description":"",
         "start_time":"2026-04-26T19:30:00Z","location_id":1,"location_name":"Stage"}
        """
        let item = try decode(ScheduledItem.self, from: json)
        XCTAssertTrue(item.description.isEmpty)
    }

    // MARK: - Location

    func testLocation_Decodes_WithScheduledItems() throws {
        let json = """
        {
          "id": 1,
          "name": "Main Stage",
          "snippet": "Live music all day.",
          "description": "The main stage area.",
          "website": "https://example.com",
          "image_url": "https://example.com/stage.jpg",
          "latitude": 32.755,
          "longitude": -97.331,
          "address": "123 Main St, Fort Worth, TX",
          "scheduled_items": [
            {"id":1,"name":"Opening Ceremony","description":"Welcome.",
             "start_time":"2026-04-26T17:00:00Z","location_id":1,"location_name":"Main Stage"},
            {"id":2,"name":"Headliner Performance","description":"Main act.",
             "start_time":"2026-04-26T21:00:00Z","location_id":1,"location_name":"Main Stage"}
          ]
        }
        """
        let loc = try decode(Location.self, from: json)
        XCTAssertEqual(loc.id, 1)
        XCTAssertEqual(loc.name, "Main Stage")
        XCTAssertEqual(loc.snippet, "Live music all day.")
        XCTAssertEqual(loc.website, "https://example.com")
        XCTAssertEqual(loc.imageUrl, "https://example.com/stage.jpg")
        XCTAssertEqual(loc.latitude,  32.755, accuracy: 0.001)
        XCTAssertEqual(loc.longitude, -97.331, accuracy: 0.001)
        XCTAssertEqual(loc.address, "123 Main St, Fort Worth, TX")
        XCTAssertEqual(loc.scheduledItems.count, 2)
        XCTAssertEqual(loc.scheduledItems[0].name, "Opening Ceremony")
        XCTAssertEqual(loc.scheduledItems[1].name, "Headliner Performance")
    }

    func testLocation_Decodes_EmptyScheduledItems() throws {
        let json = """
        {"id":2,"name":"Food Court","snippet":"Food","description":"Lots of food.",
         "website":null,"image_url":null,"latitude":0,"longitude":0,
         "address":"456 Other St","scheduled_items":[]}
        """
        let loc = try decode(Location.self, from: json)
        XCTAssertTrue(loc.scheduledItems.isEmpty)
        XCTAssertNil(loc.website)
        XCTAssertNil(loc.imageUrl)
    }

    func testLocation_Decodes_NullOptionals() throws {
        let json = """
        {"id":3,"name":"Gallery","snippet":"Art","description":"Contemporary art.",
         "website":null,"image_url":null,"latitude":0,"longitude":0,
         "address":"789 Art Ave","scheduled_items":[]}
        """
        let loc = try decode(Location.self, from: json)
        XCTAssertNil(loc.website)
        XCTAssertNil(loc.imageUrl)
    }

    func testLocation_ScheduledItems_PreserveOrder() throws {
        // Items should decode in the order the API returns them
        let json = """
        {"id":1,"name":"Stage","snippet":"","description":"","website":null,"image_url":null,
         "latitude":0,"longitude":0,"address":"","scheduled_items":[
           {"id":2,"name":"Headliner","description":"","start_time":"2026-04-26T21:00:00Z","location_id":1,"location_name":"Stage"},
           {"id":1,"name":"Opener","description":"","start_time":"2026-04-26T17:00:00Z","location_id":1,"location_name":"Stage"}
         ]}
        """
        let loc = try decode(Location.self, from: json)
        // First item in array = first decoded, regardless of id order
        XCTAssertEqual(loc.scheduledItems[0].id, 2)
        XCTAssertEqual(loc.scheduledItems[1].id, 1)
    }

    // MARK: - AppNotification

    func testAppNotification_Decodes_AllFields() throws {
        let json = """
        {
          "id": 1,
          "title": "Festival kicks off tomorrow!",
          "body": "Get ready for an amazing time.",
          "send_time": "2026-04-25T12:00:00Z",
          "sent": true
        }
        """
        let notif = try decode(AppNotification.self, from: json)
        XCTAssertEqual(notif.id, 1)
        XCTAssertEqual(notif.title, "Festival kicks off tomorrow!")
        XCTAssertEqual(notif.body, "Get ready for an amazing time.")
        XCTAssertEqual(notif.sendTime, "2026-04-25T12:00:00Z")
        XCTAssertTrue(notif.sent)
    }

    func testAppNotification_Unsent() throws {
        let json = """
        {"id":2,"title":"Coming soon","body":"Stay tuned.",
         "send_time":"2026-05-01T00:00:00Z","sent":false}
        """
        XCTAssertFalse(try decode(AppNotification.self, from: json).sent)
    }

    func testAppNotification_SnakeCaseMapping() throws {
        let json = """
        {"id":1,"title":"T","body":"B","send_time":"2026-01-01T00:00:00Z","sent":true}
        """
        let notif = try decode(AppNotification.self, from: json)
        XCTAssertEqual(notif.sendTime, "2026-01-01T00:00:00Z")
    }

    // MARK: - NearbyEventResult

    func testNearbyEventResult_Decodes() throws {
        let json = """
        {
          "event": {
            "id":1,"name":"Fort Worth Festival","event_code":"FWFM2026","description":"",
            "latitude":32.7555,"longitude":-97.3308,"start_time":"2026-04-26T18:00:00Z",
            "created_at":"2026-01-15T09:00:00Z","paid":false,"flyer_url":null,"address":"Fort Worth, TX"
          },
          "distance_miles": 0.3,
          "starts_in_hours": 6.0
        }
        """
        let result = try decode(NearbyEventResult.self, from: json)
        XCTAssertEqual(result.event.id, 1)
        XCTAssertEqual(result.event.eventCode, "FWFM2026")
        XCTAssertEqual(result.distanceMiles, 0.3, accuracy: 0.001)
        XCTAssertEqual(result.startsInHours, 6.0, accuracy: 0.001)
        // id is proxied from event.id
        XCTAssertEqual(result.id, 1)
    }

    func testNearbyEventResult_SnakeCaseMapping() throws {
        let json = """
        {
          "event":{"id":2,"name":"E","event_code":"E2","description":"","latitude":0,"longitude":0,
                   "start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z",
                   "paid":false,"flyer_url":null,"address":""},
          "distance_miles":12.5,
          "starts_in_hours":-2.0
        }
        """
        let result = try decode(NearbyEventResult.self, from: json)
        XCTAssertEqual(result.distanceMiles, 12.5, accuracy: 0.001)
        XCTAssertEqual(result.startsInHours, -2.0, accuracy: 0.001)
    }

    // MARK: - APIList envelope

    func testAPIList_Decodes_Events() throws {
        let json = """
        {
          "count": 2,
          "results": [
            {"id":1,"name":"Event A","event_code":"EVA001","description":"","latitude":0,
             "longitude":0,"start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z",
             "paid":false,"flyer_url":null,"address":""},
            {"id":2,"name":"Event B","event_code":"EVB002","description":"","latitude":0,
             "longitude":0,"start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z",
             "paid":true,"flyer_url":null,"address":""}
          ]
        }
        """
        let list = try decode(APIList<Event>.self, from: json)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.results.count, 2)
        XCTAssertEqual(list.results[0].eventCode, "EVA001")
        XCTAssertEqual(list.results[1].eventCode, "EVB002")
        XCTAssertTrue(list.results[1].paid)
    }

    func testAPIList_Decodes_ScheduledItems() throws {
        let json = """
        {
          "count": 1,
          "results": [
            {"id":1,"name":"Opening Ceremony","description":"Welcome.",
             "start_time":"2026-04-26T17:00:00Z","location_id":1,"location_name":"Stage"}
          ]
        }
        """
        let list = try decode(APIList<ScheduledItem>.self, from: json)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.results[0].name, "Opening Ceremony")
    }

    func testAPIList_Decodes_EmptyResults() throws {
        let json = """{"count":0,"results":[]}"""
        let list = try decode(APIList<ScheduledItem>.self, from: json)
        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(list.results.isEmpty)
    }

    func testAPIList_CountAndResults_AlwaysMatch() throws {
        let json = """
        {"count":3,"results":[
          {"id":1,"name":"A","event_code":"A1","description":"","latitude":0,"longitude":0,"start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z","paid":false,"flyer_url":null,"address":""},
          {"id":2,"name":"B","event_code":"B2","description":"","latitude":0,"longitude":0,"start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z","paid":false,"flyer_url":null,"address":""},
          {"id":3,"name":"C","event_code":"C3","description":"","latitude":0,"longitude":0,"start_time":"2026-01-01T00:00:00Z","created_at":"2025-12-01T00:00:00Z","paid":false,"flyer_url":null,"address":""}
        ]}
        """
        let list = try decode(APIList<Event>.self, from: json)
        XCTAssertEqual(list.count, list.results.count)
    }

    // MARK: - Hashable conformance (ScheduledItem & Location)

    func testScheduledItem_Hashable_NoDuplicatesInSet() throws {
        let json = """
        {"id":1,"name":"Act","description":"","start_time":"2026-01-01T00:00:00Z",
         "location_id":1,"location_name":"Stage"}
        """
        let item = try decode(ScheduledItem.self, from: json)
        var set = Set<ScheduledItem>()
        set.insert(item)
        set.insert(item)
        XCTAssertEqual(set.count, 1)
    }

    func testLocation_Hashable_NoDuplicatesInSet() throws {
        let json = """
        {"id":1,"name":"Loc","snippet":"s","description":"d","website":null,"image_url":null,
         "latitude":0,"longitude":0,"address":"","scheduled_items":[]}
        """
        let loc = try decode(Location.self, from: json)
        var set = Set<Location>()
        set.insert(loc)
        set.insert(loc)
        XCTAssertEqual(set.count, 1)
    }
}
