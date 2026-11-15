// ModelDecodingTests.swift
// AttndTests
//
// JSON → model decoding for the v2 API. No network: all input is inline JSON.
// Covers the forward-compatibility rules in API_V2.md: unknown keys ignored,
// missing keys defaulted (especially in `display`), nullable coordinates and
// schedule locations, end times, tags, categories.

import XCTest
@testable import Attnd

final class ModelDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private let fullEvent = """
    {"id":1,"name":"Fort Worth Food & Music Festival","event_code":"FWFM2026",
     "description":"Annual festival.","address":"Sundance Square",
     "latitude":32.75,"longitude":-97.33,
     "start_time":"2026-11-14T18:00:00+00:00","end_time":"2026-11-15T04:00:00+00:00",
     "timezone":"America/Chicago","status":"published","paid":false,"is_demo":true,
     "flyer_url":"https://attnd.app/media/flyer.pdf","accent_color":"#FF5A1F",
     "logo_url":null,"content_version":15,"join_url":"https://attnd.app/join/FWFM2026/",
     "some_future_key":{"nested":[1,2,3]}}
    """

    // MARK: - Event

    func testEvent_DecodesAllFields() throws {
        let event = try decode(Event.self, fullEvent)
        XCTAssertEqual(event.id, 1)
        XCTAssertEqual(event.eventCode, "FWFM2026")
        XCTAssertEqual(event.latitude ?? 0, 32.75, accuracy: 0.0001)
        XCTAssertEqual(event.timeZone.identifier, "America/Chicago")
        XCTAssertEqual(event.status, .published)
        XCTAssertTrue(event.isDemo)
        XCTAssertFalse(event.paid)
        XCTAssertEqual(event.flyerUrl?.absoluteString, "https://attnd.app/media/flyer.pdf")
        XCTAssertEqual(event.accentColor, "#FF5A1F")
        XCTAssertNil(event.logoUrl)
        XCTAssertEqual(event.contentVersion, 15)
        XCTAssertEqual(event.startTime, ISODate.parse("2026-11-14T18:00:00Z"))
        XCTAssertNotNil(event.endTime)
        XCTAssertNotNil(event.coordinate)
    }

    func testEvent_MinimalPayload_UsesDefaults() throws {
        let event = try decode(Event.self, #"{"id":7}"#)
        XCTAssertEqual(event.name, "")
        XCTAssertEqual(event.eventCode, "")
        XCTAssertNil(event.latitude)
        XCTAssertNil(event.coordinate)
        XCTAssertNil(event.startTime)
        XCTAssertEqual(event.status, .published)
        XCTAssertFalse(event.isDemo)
        XCTAssertEqual(event.timeZone, .current)
    }

    func testEvent_Archived_AndUnknownStatus() throws {
        XCTAssertTrue(try decode(Event.self, #"{"id":1,"status":"archived"}"#).isArchived)
        XCTAssertEqual(try decode(Event.self, #"{"id":1,"status":"something_new"}"#).status, .published)
    }

    func testEvent_IsDemoFallsBackToUnpaid() throws {
        XCTAssertTrue(try decode(Event.self, #"{"id":1,"paid":false}"#).isDemo)
        XCTAssertFalse(try decode(Event.self, #"{"id":1,"paid":true}"#).isDemo)
    }

    func testEvent_NullAndZeroCoordinates_HaveNoCoordinate() throws {
        XCTAssertNil(try decode(Event.self, #"{"id":1,"latitude":null,"longitude":null}"#).coordinate)
        XCTAssertNil(try decode(Event.self, #"{"id":1,"latitude":0,"longitude":0}"#).coordinate)
    }

    func testEvent_WrongTypes_FallBackInsteadOfFailing() throws {
        let event = try decode(Event.self, #"{"id":1,"name":42,"paid":"yes","content_version":"x"}"#)
        XCTAssertEqual(event.name, "")
        XCTAssertFalse(event.paid)
        XCTAssertEqual(event.contentVersion, 0)
    }

    func testEvent_MicrosecondTimestamps() throws {
        let event = try decode(Event.self, #"{"id":1,"start_time":"2026-11-14T13:29:44.123456+00:00"}"#)
        XCTAssertEqual(event.startTime?.timeIntervalSince1970 ?? 0,
                       ISODate.parse("2026-11-14T13:29:44Z")!.timeIntervalSince1970 + 0.123,
                       accuracy: 0.001)
    }

    // MARK: - Location

    func testLocation_NullableFields() throws {
        let loc = try decode(Location.self, """
        {"id":5,"name":"Food Court","snippet":"Eat","description":"","category":null,
         "website":null,"image_url":null,"address":"","latitude":null,"longitude":null,"sort_order":3}
        """)
        XCTAssertEqual(loc.id, 5)
        XCTAssertNil(loc.category)
        XCTAssertNil(loc.coordinate)
        XCTAssertEqual(loc.sortOrder, 3)
    }

    func testLocation_CategoryAndCoordinates() throws {
        let loc = try decode(Location.self, """
        {"id":5,"name":"Grill","category":"Food","website":"https://example.com",
         "image_url":"https://example.com/a.jpg","latitude":32.74,"longitude":-97.36}
        """)
        XCTAssertEqual(loc.category, "Food")
        XCTAssertEqual(loc.website?.host, "example.com")
        XCTAssertEqual(loc.coordinate, Coordinate(latitude: 32.74, longitude: -97.36))
    }

    func testLocation_EmptyCategory_IsNil() throws {
        XCTAssertNil(try decode(Location.self, #"{"id":1,"category":"  "}"#).category)
    }

    // MARK: - Schedule item

    func testScheduleItem_AllFields() throws {
        let item = try decode(ScheduleItem.self, """
        {"id":1,"name":"Headliner","description":"Main act.",
         "start_time":"2026-11-14T21:00:00+00:00","end_time":"2026-11-14T22:30:00+00:00",
         "location_id":5,"location_name":"Main Stage","tags":["Music","Free"]}
        """)
        XCTAssertEqual(item.locationId, 5)
        XCTAssertEqual(item.locationName, "Main Stage")
        XCTAssertEqual(item.tags, ["Music", "Free"])
        XCTAssertEqual(item.endTime?.timeIntervalSince(item.startTime!), 5400)
    }

    func testScheduleItem_NoLocation_NoEnd_NoTags() throws {
        let item = try decode(ScheduleItem.self, """
        {"id":2,"name":"Fireworks","start_time":"2026-11-14T23:00:00Z","end_time":null,
         "location_id":null,"location_name":null}
        """)
        XCTAssertNil(item.locationId)
        XCTAssertNil(item.locationName)
        XCTAssertNil(item.endTime)
        XCTAssertEqual(item.tags, [])
    }

    // MARK: - Notification

    func testNotification() throws {
        let n = try decode(AppNotification.self, #"{"id":1,"title":"Gate B open","body":"Head over.","send_time":"2026-11-14T17:45:00+00:00"}"#)
        XCTAssertEqual(n.title, "Gate B open")
        XCTAssertNotNil(n.sendTime)
    }

    // MARK: - Display

    func testDisplay_EmptyObject_UsesAllDefaults() throws {
        let d = try decode(DisplayConfig.self, "{}")
        XCTAssertEqual(d, DisplayConfig.default)
        XCTAssertNil(d.tabs)
        XCTAssertEqual(d.locationsStyle, .list)
        XCTAssertEqual(d.scheduleStyle, .byDay)
        XCTAssertFalse(d.mapClustering)
        XCTAssertTrue(d.mapFitAll)
        XCTAssertTrue(d.showLocationImages)
        XCTAssertTrue(d.enableSearch)
        XCTAssertFalse(d.groupByCategory)
        XCTAssertEqual(d.secondaryPane, .locations)
        XCTAssertEqual(d.resolvedTabs(hasFlyer: false), [.map, .locations, .schedule, .notifications])
        XCTAssertEqual(d.resolvedTabs(hasFlyer: true), [.map, .locations, .schedule, .flyer, .notifications])
        XCTAssertEqual(d.resolvedDefaultTab(hasFlyer: false), .map)
    }

    func testDisplay_FullObject() throws {
        let d = try decode(DisplayConfig.self, """
        {"tabs":["schedule","map","locations","flyer","notifications"],"default_tab":"schedule",
         "locations_style":"grouped","schedule_style":"now_next","map_clustering":true,
         "map_fit_all":false,"show_location_images":false,"enable_search":true,
         "group_by_category":true,"secondary_pane":"schedule","accent_color":"#112233",
         "logo_url":"https://example.com/logo.png","preset":"festival","resolved_preset":"festival",
         "reason":"Chosen","stats":{"location_count":40},"schema_version":2}
        """)
        XCTAssertEqual(d.tabs, [.schedule, .map, .locations, .flyer, .notifications])
        XCTAssertEqual(d.resolvedDefaultTab(hasFlyer: true), .schedule)
        XCTAssertEqual(d.locationsStyle, .grouped)
        XCTAssertEqual(d.scheduleStyle, .nowNext)
        XCTAssertTrue(d.mapClustering)
        XCTAssertFalse(d.mapFitAll)
        XCTAssertFalse(d.showLocationImages)
        XCTAssertTrue(d.groupByCategory)
        XCTAssertEqual(d.secondaryPane, .schedule)
        XCTAssertEqual(d.accentColor, "#112233")
        XCTAssertNotNil(d.logoUrl)
    }

    func testDisplay_UnknownValues_FallBack() throws {
        let d = try decode(DisplayConfig.self, """
        {"tabs":["map","tickets","map","notifications"],"default_tab":"tickets",
         "locations_style":"carousel","schedule_style":"gantt","secondary_pane":"weather",
         "map_clustering":"yes"}
        """)
        XCTAssertEqual(d.tabs, [.map, .notifications], "unknown tabs and duplicates are dropped")
        XCTAssertEqual(d.resolvedDefaultTab(hasFlyer: false), .map)
        XCTAssertEqual(d.locationsStyle, .list)
        XCTAssertEqual(d.scheduleStyle, .byDay)
        XCTAssertEqual(d.secondaryPane, .locations)
        XCTAssertFalse(d.mapClustering)
    }

    func testDisplay_DefaultTabNotVisible_FallsBackToMapThenFirst() throws {
        let withMap = try decode(DisplayConfig.self, #"{"tabs":["locations","map"],"default_tab":"schedule"}"#)
        XCTAssertEqual(withMap.resolvedDefaultTab(hasFlyer: false), .map)
        let noMap = try decode(DisplayConfig.self, #"{"tabs":["notifications","locations"]}"#)
        XCTAssertEqual(noMap.resolvedDefaultTab(hasFlyer: false), .notifications)
    }

    func testDisplay_AllTabsUnknown_UsesDefaults() throws {
        let d = try decode(DisplayConfig.self, #"{"tabs":["tickets"]}"#)
        XCTAssertEqual(d.resolvedTabs(hasFlyer: false), [.map, .locations, .schedule, .notifications])
    }

    func testDisplay_Tabs_AtMostFiveInListedOrder_NeverAMoreTab() throws {
        let d = try decode(
            DisplayConfig.self,
            #"{"tabs":["notifications","flyer","tickets","schedule","map","locations","map","schedule"]}"#
        )
        // Unknown values and duplicates dropped, the server's order kept, never more than five.
        XCTAssertEqual(d.resolvedTabs(hasFlyer: true), [.notifications, .flyer, .schedule, .map, .locations])
        XCTAssertLessThanOrEqual(d.resolvedTabs(hasFlyer: true).count, DisplayConfig.maxTabs)
        XCTAssertEqual(DisplayConfig.maxTabs, 5)
    }

    // MARK: - Bundle

    func testBundle_Full() throws {
        let bundle = try decode(EventBundle.self, """
        {"schema_version":2,"content_version":15,"updated_at":"2026-11-14T13:29:44+00:00",
         "event":\(fullEvent),
         "display":{"tabs":["map","schedule"],"schedule_style":"timeline"},
         "categories":["Food","Stage"],
         "locations":[{"id":5,"name":"Grill","category":"Food","latitude":32.74,"longitude":-97.36},
                      {"id":6,"name":"Info tent","latitude":null,"longitude":null}],
         "schedule":[{"id":1,"name":"Open","start_time":"2026-11-14T18:00:00Z","location_id":5,"location_name":"Grill","tags":[]},
                     {"id":2,"name":"Parade","start_time":"2026-11-14T19:00:00Z","location_id":null,"location_name":null}],
         "notifications":[{"id":3,"title":"Welcome","body":"Hi","send_time":"2026-11-14T17:00:00Z"}]}
        """)
        XCTAssertEqual(bundle.contentVersion, 15)
        XCTAssertNotNil(bundle.updatedAt)
        XCTAssertEqual(bundle.event.eventCode, "FWFM2026")
        XCTAssertEqual(bundle.display.tabs, [.map, .schedule])
        XCTAssertEqual(bundle.display.scheduleStyle, .timeline)
        XCTAssertEqual(bundle.display.locationsStyle, .list, "missing keys default")
        XCTAssertEqual(bundle.categories, ["Food", "Stage"])
        XCTAssertEqual(bundle.locations.map(\.id), [5, 6])
        XCTAssertNil(bundle.locations[1].coordinate)
        XCTAssertEqual(bundle.schedule.count, 2)
        XCTAssertNil(bundle.schedule[1].locationId)
        XCTAssertEqual(bundle.notifications.first?.title, "Welcome")
    }

    func testBundle_MissingDisplayAndLists_UseDefaults() throws {
        let bundle = try decode(EventBundle.self, #"{"event":{"id":1,"content_version":4}}"#)
        XCTAssertEqual(bundle.display, .default)
        XCTAssertEqual(bundle.contentVersion, 4)
        XCTAssertTrue(bundle.locations.isEmpty)
        XCTAssertTrue(bundle.schedule.isEmpty)
        XCTAssertTrue(bundle.notifications.isEmpty)
    }

    func testBundle_DisplayNull_UsesDefaults() throws {
        let bundle = try decode(EventBundle.self, #"{"event":{"id":1},"display":null}"#)
        XCTAssertEqual(bundle.display, .default)
    }

    func testBundle_BadElementIsSkipped_NotFatal() throws {
        let bundle = try decode(EventBundle.self, """
        {"event":{"id":1},"locations":[{"id":1,"name":"Good"},{"name":"No id"},{"id":3,"name":"Also good"}]}
        """)
        XCTAssertEqual(bundle.locations.map(\.id), [1, 3])
    }

    func testBundle_MissingEvent_Fails() {
        XCTAssertThrowsError(try decode(EventBundle.self, #"{"locations":[]}"#))
    }

    // MARK: - Nearby / Lookup / Status

    func testNearbyResponse() throws {
        let r = try decode(NearbyEventsResponse.self, """
        {"count":1,"results":[{"event":{"id":1,"event_code":"A"},"distance_miles":1.2,"starts_in_hours":5.0}]}
        """)
        XCTAssertEqual(r.results.count, 1)
        XCTAssertEqual(r.results[0].id, 1)
        XCTAssertEqual(r.results[0].distanceMiles ?? 0, 1.2, accuracy: 0.001)
    }

    func testLookupResponse() throws {
        XCTAssertEqual(try decode(LookupResponse.self, #"{"event":{"id":9,"event_code":"X"}}"#).event.id, 9)
    }

    func testStatusResponse() throws {
        let r = try decode(StatusResponse.self, #"{"status":"ok","subscribed":true,"event_id":null}"#)
        XCTAssertEqual(r.status, "ok")
        XCTAssertEqual(r.subscribed, true)
        XCTAssertNil(r.eventId)
    }

    // MARK: - Request bodies

    func testJoinRequest_OmitsNilFields() throws {
        let data = try JSONEncoder().encode(JoinRequest(deviceId: "abc", pushToken: nil, appVersion: nil))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, "abc")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertNil(json["push_token"])
    }

    func testDeviceRequest_Keys() throws {
        let data = try JSONEncoder().encode(DeviceRequest(deviceId: "abc", pushToken: "ff00", appVersion: "2.0", subscribed: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["push_token"] as? String, "ff00")
        XCTAssertEqual(json["app_version"] as? String, "2.0")
        XCTAssertEqual(json["subscribed"] as? Bool, true)
    }

    // MARK: - App status (API-003)

    func testAppStatus_DecodesRequired() throws {
        let json = #"{"update": "required", "min_version": "2.0.90", "latest_version": null, "update_url": "https://apps.apple.com/app/id1470627406", "message": null}"#
        let status = try JSONDecoder().decode(AppStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.update, .required)
        XCTAssertEqual(status.minVersion, "2.0.90")
        XCTAssertNil(status.latestVersion)
        XCTAssertEqual(status.updateURL?.absoluteString, "https://apps.apple.com/app/id1470627406")
    }

    func testAppStatus_UnknownOrMissingValuesMeanNoPrompt() throws {
        let unknown = try JSONDecoder().decode(AppStatus.self, from: Data(#"{"update": "someday", "extra": 1}"#.utf8))
        XCTAssertEqual(unknown.update, .upToDate)
        let empty = try JSONDecoder().decode(AppStatus.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.update, .upToDate)
    }


    // MARK: - Saved event (API-007 offline copy)

    private func savedEvent(eventId: Int = 1, code: String = "FWFM2026", json: String? = nil) -> SavedEvent {
        SavedEvent(
            eventId: eventId,
            eventCode: code,
            etag: "\"v15\"",
            lastRefreshed: Date(timeIntervalSince1970: 1_800_000_000),
            bundleJSON: Data((json ?? #"{"content_version":15,"event":\#(fullEvent)}"#).utf8)
        )
    }

    func testSavedEvent_RoundTripsAndDecodesTheRawBundle() throws {
        let saved = savedEvent()
        let restored = try SavedEvent.decode(SavedEvent.encode(saved))
        XCTAssertEqual(restored, saved)
        let bundle = try restored.decodedBundle()
        XCTAssertEqual(bundle.event.id, 1)
        XCTAssertEqual(bundle.contentVersion, 15)
        XCTAssertEqual(bundle.event.eventCode, "FWFM2026")
        XCTAssertEqual(restored.etag, "\"v15\"")
        XCTAssertEqual(restored.lastRefreshed, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSavedEvent_KeepsUnknownKeysForNewerBuilds() throws {
        // The raw server body is stored as is, so fields this build ignores survive on disk.
        let json = #"{"event":{"id":1,"name":"X","future_field":42},"future_list":[1,2]}"#
        let saved = savedEvent(json: json)
        let restored = try SavedEvent.decode(SavedEvent.encode(saved))
        XCTAssertEqual(String(decoding: restored.bundleJSON, as: UTF8.self), json)
        XCTAssertEqual(try restored.decodedBundle().event.name, "X")
    }

    func testSavedEvent_RejectsAnotherEventsBundle() {
        let saved = savedEvent(eventId: 2)
        XCTAssertThrowsError(try saved.decodedBundle())
    }

    func testSavedEvent_RejectsUnknownFormatAndCorruptBundle() {
        var future = savedEvent()
        future.format = SavedEvent.currentFormat + 1
        XCTAssertThrowsError(try future.decodedBundle())
        XCTAssertThrowsError(try savedEvent(json: "not json").decodedBundle())
        XCTAssertThrowsError(try SavedEvent.decode(Data("{}".utf8)))
    }

    func testSavedEvent_BelongsToSavedCodeCaseInsensitively() {
        let saved = savedEvent(code: "FWFM2026")
        XCTAssertTrue(saved.belongs(toEventCode: "fwfm2026"))
        XCTAssertFalse(saved.belongs(toEventCode: "OTHER"))
        XCTAssertFalse(saved.belongs(toEventCode: nil), "no saved code means the user left")
        XCTAssertFalse(saved.belongs(toEventCode: ""))
    }

    // MARK: - Push token in requests (API-007)

    func testEmptyPushToken_IsOmittedNotSentEmpty() throws {
        XCTAssertNil(APIClient.nonEmpty(""))
        XCTAssertNil(APIClient.nonEmpty("  "))
        XCTAssertNil(APIClient.nonEmpty(nil))
        XCTAssertEqual(APIClient.nonEmpty("ff00"), "ff00")
        let body = DeviceRequest(deviceId: "abc", pushToken: APIClient.nonEmpty(""), appVersion: nil, subscribed: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertFalse(json.keys.contains("push_token"))
        XCTAssertEqual(json["subscribed"] as? Bool, false)
    }

    func testDeviceRequest_TokenWithSubscribedFalse() throws {
        // Silent pushes need the token on the server even when alerts are off.
        let body = DeviceRequest(deviceId: "abc", pushToken: "ff00", appVersion: nil, subscribed: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["push_token"] as? String, "ff00")
        XCTAssertEqual(json["subscribed"] as? Bool, false)
    }
}
