// GlanceTests.swift
// AttndTests
//
// The glance rules (Glance.swift), with the cases shared with the Android app: a fixed `now`
// (Saturday Nov 14, 2026, 2:00 PM in America/Chicago), locale en_US (time strings are compared
// with narrow / no-break spaces turned into plain spaces).

import XCTest
@testable import Attnd

private func date(_ iso: String) -> Date {
    guard let d = ISODate.parse(iso) else { fatalError("bad fixture date \(iso)") }
    return d
}

/// "7:30\u{202F}PM" → "7:30 PM".
private func plain(_ text: String?) -> String? {
    text.map { $0.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
}

final class GlanceTests: XCTestCase {

    private let now = date("2026-11-14T14:00:00-06:00")
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    private func relative(_ start: String, end: String? = nil, includeEnd: Bool = false) -> String? {
        plain(RelativeTimeText.start(date(start), end: end.map(date), now: now, timeZone: chicago,
                                     includeEnd: includeEnd, locale: us))
    }

    // MARK: - Relative start time (§1)

    func testRelative_EndedAndStarted() {
        XCTAssertEqual(relative("2026-11-14T08:00:00-06:00", end: "2026-11-14T09:00:00-06:00"), "Ended")
        // Ends exactly now: ended.
        XCTAssertEqual(relative("2026-11-14T13:00:00-06:00", end: "2026-11-14T14:00:00-06:00"), "Ended")
        XCTAssertEqual(relative("2026-11-14T13:40:00-06:00", end: "2026-11-14T15:00:00-06:00"), "Started 20 min ago")
        XCTAssertEqual(relative("2026-11-14T13:59:30-06:00", end: "2026-11-14T15:00:00-06:00"), "Started just now")
        XCTAssertEqual(relative("2026-11-14T12:30:00-06:00", end: "2026-11-14T20:30:00-06:00"), "Now")
        XCTAssertEqual(relative("2026-11-14T12:30:00-06:00", end: "2026-11-14T20:30:00-06:00", includeEnd: true),
                       "Now · ends 8:30 PM")
        XCTAssertEqual(relative("2026-11-14T13:40:00-06:00", end: "2026-11-14T15:00:00-06:00", includeEnd: true),
                       "Started 20 min ago · ends 3:00 PM")
        // No end: one hour long.
        XCTAssertEqual(relative("2026-11-14T13:30:00-06:00"), "Started 30 min ago")
        XCTAssertEqual(relative("2026-11-14T12:30:00-06:00"), "Ended")
    }

    func testRelative_FutureMinutesAndHours() {
        XCTAssertEqual(relative("2026-11-14T14:00:30-06:00"), "Starting now")
        XCTAssertEqual(relative("2026-11-14T14:12:00-06:00"), "in 12 min")
        XCTAssertEqual(relative("2026-11-14T14:12:59-06:00"), "in 12 min")
        XCTAssertEqual(relative("2026-11-14T14:59:00-06:00"), "in 59 min")
        XCTAssertEqual(relative("2026-11-14T15:00:00-06:00"), "in 1 h")
        XCTAssertEqual(relative("2026-11-14T17:20:00-06:00"), "in 3 h 20 min")
        XCTAssertEqual(relative("2026-11-14T19:59:00-06:00"), "in 5 h 59 min")
    }

    func testRelative_SixHoursOrMoreUsesDays() {
        // 6 h or more: never hours.
        XCTAssertEqual(relative("2026-11-14T20:00:00-06:00"), "today 8:00 PM")
        XCTAssertEqual(relative("2026-11-14T23:30:00-06:00"), "today 11:30 PM")
        XCTAssertEqual(relative("2026-11-15T19:30:00-06:00"), "tomorrow 7:30 PM")
        // 1 AM tomorrow (11 h away): the next calendar day.
        XCTAssertEqual(relative("2026-11-15T01:00:00-06:00"), "tomorrow 1:00 AM")
        XCTAssertEqual(relative("2026-11-17T10:00:00-06:00"), "in 3 days")
        XCTAssertEqual(relative("2026-11-20T10:00:00-06:00"), "in 6 days")
        XCTAssertEqual(relative("2026-11-21T10:00:00-06:00"), "in 1 week")
        XCTAssertEqual(relative("2026-11-28T10:00:00-06:00"), "in 2 weeks")
        XCTAssertEqual(relative("2026-12-18T10:00:00-06:00"), "in 4 weeks")
        XCTAssertEqual(relative("2027-03-20T10:00:00-05:00"), "in 4 months")
        XCTAssertEqual(relative("2027-11-20T10:00:00-06:00"), "in 1 year")
        XCTAssertEqual(relative("2029-01-10T10:00:00-06:00"), "in 2 years")
    }

    func testRelative_CalendarDaysInEventTimeZone() {
        // 11:30 PM Saturday in Chicago is still "today" there, although it's Sunday in UTC.
        XCTAssertEqual(relative("2026-11-15T05:30:00Z"), "today 11:30 PM")
    }

    func testRelative_NearbyEventFromStartsInHours() {
        // The bug: 2,000 hours away was printed as hours. Now it becomes a date.
        let event = Event(id: 1, name: "Future Fest", eventCode: "FF", timeZoneIdentifier: "America/Chicago")
        XCTAssertEqual(plain(RelativeTimeText.event(event, startsInHours: 2000, now: now, locale: us)), "in 2 months")
        XCTAssertEqual(plain(RelativeTimeText.event(event, startsInHours: 3.5, now: now, locale: us)), "in 3 h 30 min")
        XCTAssertNil(RelativeTimeText.event(event, startsInHours: nil, now: now, locale: us))
        // An event without an end lasts until the end of its first day.
        let started = Event(id: 2, name: "Today", eventCode: "T", startTime: date("2026-11-14T09:00:00-06:00"),
                            timeZoneIdentifier: "America/Chicago")
        XCTAssertEqual(RelativeTimeText.event(started, startsInHours: nil, now: now, locale: us), "Now")
    }

    // MARK: - Distance (§1)

    func testDistance_Imperial() {
        XCTAssertEqual(DistanceText.text(meters: 152.4, imperial: true, locale: us), "500 ft")
        XCTAssertEqual(DistanceText.text(meters: 3, imperial: true, locale: us), "10 ft")
        XCTAssertEqual(DistanceText.text(meters: 965.6, imperial: true, locale: us), "0.6 mi")
        XCTAssertEqual(DistanceText.text(meters: 16_093, imperial: true, locale: us), "10 mi")
        XCTAssertEqual(DistanceText.text(meters: 15_000, imperial: true, locale: us), "9.3 mi")
        XCTAssertEqual(DistanceText.text(meters: 19_312, imperial: true, locale: us), "12 mi")
        XCTAssertEqual(DistanceText.spoken(meters: 965.6, imperial: true, locale: us), "0.6 miles")
        XCTAssertEqual(DistanceText.spoken(meters: 152.4, imperial: true, locale: us), "500 feet")
    }

    func testDistance_Metric() {
        XCTAssertEqual(DistanceText.text(meters: 348, imperial: false, locale: us), "350 m")
        XCTAssertEqual(DistanceText.text(meters: 996, imperial: false, locale: us), "1.0 km")
        XCTAssertEqual(DistanceText.text(meters: 1_234, imperial: false, locale: us), "1.2 km")
        XCTAssertEqual(DistanceText.text(meters: 12_400, imperial: false, locale: us), "12 km")
        XCTAssertEqual(DistanceText.text(meters: 1_234, imperial: false, locale: de), "1,2 km")
        XCTAssertEqual(DistanceText.spoken(meters: 1_234, imperial: false, locale: us), "1.2 kilometers")
    }

    func testDistance_RegionUnits() {
        XCTAssertTrue(DistanceText.usesImperial(Locale(identifier: "en_US")))
        XCTAssertTrue(DistanceText.usesImperial(Locale(identifier: "en_GB")))
        XCTAssertTrue(DistanceText.usesImperial(Locale(identifier: "en_LR")))
        XCTAssertTrue(DistanceText.usesImperial(Locale(identifier: "my_MM")))
        XCTAssertFalse(DistanceText.usesImperial(Locale(identifier: "en_CA")))
        XCTAssertFalse(DistanceText.usesImperial(Locale(identifier: "de_DE")))
    }

    // MARK: - Compass (§2)

    private let plaza = Coordinate(latitude: 41.8800, longitude: -87.6300)

    func testCompass_BearingAndDistance() {
        let north = Coordinate(latitude: 41.8900, longitude: -87.6300)
        let east = Coordinate(latitude: 41.8800, longitude: -87.6200)
        XCTAssertEqual(Compass.bearing(from: plaza, to: north), 0, accuracy: 0.01)
        XCTAssertEqual(Compass.bearing(from: plaza, to: east), 90, accuracy: 0.1)
        XCTAssertEqual(Compass.bearing(from: north, to: plaza), 180, accuracy: 0.01)
        XCTAssertEqual(Compass.distance(plaza, north), 1_112, accuracy: 2)
        XCTAssertEqual(Compass.distance(plaza, east), 828, accuracy: 2)
        let northeast = Coordinate(latitude: 41.8864, longitude: -87.6214)
        XCTAssertEqual(Compass.point(Compass.bearing(from: plaza, to: northeast)), .northeast)
    }

    func testCompass_PointsAndRotation() {
        XCTAssertEqual(Compass.point(0), .north)
        XCTAssertEqual(Compass.point(22.4), .north)
        XCTAssertEqual(Compass.point(22.5), .northeast)
        XCTAssertEqual(Compass.point(337.4), .northwest)
        XCTAssertEqual(Compass.point(337.5), .north)
        XCTAssertEqual(Compass.point(-90), .west)
        XCTAssertEqual(Compass.point(180), .south)
        XCTAssertEqual(Compass.arrowRotation(bearing: 45, heading: 90), 315)
        XCTAssertEqual(Compass.arrowRotation(bearing: 10, heading: 350), 20)
        XCTAssertEqual(Compass.normalized(720), 0)
        XCTAssertEqual(Compass.interfaceHeading(deviceHeading: 300, interfaceRotation: 90), 30)
    }

    func testTargetDirection_TextsAndHere() {
        let target = Coordinate(latitude: 41.8861, longitude: -87.6218) // ~950 m northeast
        let direction = TargetDirection(from: plaza, to: target)
        XCTAssertEqual(direction.text(imperial: true, locale: us), "0.6 mi")
        XCTAssertEqual(direction.accessibilityText(imperial: true, locale: us), "Northeast, 0.6 miles")
        XCTAssertNotNil(direction.arrowRotation(heading: 0))
        XCTAssertNil(direction.arrowRotation(heading: nil))

        let close = TargetDirection(from: plaza, to: Coordinate(latitude: 41.88010, longitude: -87.6300)) // ~11 m
        XCTAssertTrue(close.isHere)
        XCTAssertEqual(close.text(imperial: true, locale: us), "Here")
        XCTAssertEqual(close.accessibilityText(imperial: false, locale: us), "Here")
        XCTAssertNil(close.arrowRotation(heading: 0))
    }

    // MARK: - Walking (§3)

    func testWalk_EstimateAndTexts() {
        // 1,000 m × 1.2 / 1.3 m/s = 923 s → 16 min (rounded up).
        XCTAssertEqual(WalkTime.estimatedSeconds(straightMeters: 1_000), 923.08, accuracy: 0.1)
        XCTAssertEqual(WalkTime.rowText(straightMeters: 1_000), "16 min walk")
        XCTAssertEqual(WalkTime.rowText(straightMeters: 10), "1 min walk")
        XCTAssertEqual(WalkTime.durationText(3600), "1 h")
        XCTAssertEqual(WalkTime.durationText(3901), "1 h 6 min")
        XCTAssertTrue(WalkTime.isWithinWalkingRange(8_000))
        XCTAssertFalse(WalkTime.isWithinWalkingRange(8_001))
    }

    func testWalk_RouteOrFallback() {
        let destination = Coordinate(latitude: 41.8861, longitude: -87.6218)
        let straight = Compass.distance(plaza, destination)
        let good = WalkRoute.make(locationId: 1, origin: plaza, destination: destination,
                                  routePoints: [plaza, destination], routeSeconds: 720, routeMeters: 965.6)
        XCTAssertFalse(good.isEstimate)
        XCTAssertEqual(good.text(imperial: true, locale: us), "12 min walk · 0.6 mi")

        // A route more than 2.5× the straight line (festival grounds): dashed line + estimate.
        let detour = WalkRoute.make(locationId: 1, origin: plaza, destination: destination,
                                    routePoints: [plaza, destination], routeSeconds: 2400, routeMeters: straight * 2.6)
        XCTAssertTrue(detour.isEstimate)
        XCTAssertEqual(detour.linePoints, [plaza, destination])
        XCTAssertEqual(detour.text(imperial: true, locale: us), "about 15 min walk")

        let none = WalkRoute.make(locationId: 1, origin: plaza, destination: destination,
                                  routePoints: nil, routeSeconds: nil, routeMeters: nil)
        XCTAssertTrue(none.isEstimate)
    }

    func testRouteCache_ReusedWithin50Meters() {
        var cache = RouteCache()
        let destination = Coordinate(latitude: 41.8861, longitude: -87.6218)
        XCTAssertTrue(cache.needsRoute(for: 1, from: plaza))
        cache.store(WalkRoute.make(locationId: 1, origin: plaza, destination: destination,
                                   routePoints: nil, routeSeconds: nil, routeMeters: nil))
        // ~30 m away: reused.
        XCTAssertFalse(cache.needsRoute(for: 1, from: Coordinate(latitude: 41.88027, longitude: -87.6300)))
        // ~80 m away: re-route.
        XCTAssertTrue(cache.needsRoute(for: 1, from: Coordinate(latitude: 41.88072, longitude: -87.6300)))
        // Another location: not cached.
        XCTAssertTrue(cache.needsRoute(for: 2, from: plaza))
    }

    // MARK: - Now / next per location (§4)

    private let schedule: [ScheduleItem] = [
        ScheduleItem(id: 1, name: "Prairie Lights", startTime: date("2026-11-14T13:30:00-06:00"),
                     endTime: date("2026-11-14T15:00:00-06:00"), locationId: 10),
        ScheduleItem(id: 2, name: "Midnight Choir", startTime: date("2026-11-14T16:30:00-06:00"),
                     endTime: date("2026-11-14T17:30:00-06:00"), locationId: 10),
        ScheduleItem(id: 3, name: "Late Set", startTime: date("2026-11-14T20:30:00-06:00"), locationId: 10),
        ScheduleItem(id: 4, name: "Sunday Brunch", startTime: date("2026-11-15T10:00:00-06:00"), locationId: 20),
        ScheduleItem(id: 5, name: "Morning Yoga", startTime: date("2026-11-14T08:00:00-06:00"),
                     endTime: date("2026-11-14T09:00:00-06:00"), locationId: 30),
        ScheduleItem(id: 6, name: "Taco Tasting", startTime: date("2026-11-14T13:45:00-06:00"),
                     endTime: date("2026-11-14T14:30:00-06:00"), locationId: 20),
        ScheduleItem(id: 7, name: "Roaming Band", startTime: date("2026-11-14T13:00:00-06:00"),
                     endTime: date("2026-11-14T16:00:00-06:00")),
    ]

    func testLocationGlance_NowAndNext() {
        let stage = LocationGlance.make(locationId: 10, schedule: schedule, now: now)
        XCTAssertEqual(stage.current?.id, 1)
        XCTAssertEqual(stage.next?.id, 2)
        XCTAssertTrue(stage.isLive)
        XCTAssertEqual(plain(stage.pinSubtitle(now: now, timeZone: chicago, locale: us)), "Next 4:30")
        XCTAssertEqual(plain(stage.rowLine(now: now, timeZone: chicago, locale: us)),
                       "Now: Prairie Lights · Next 4:30 Midnight Choir")

        // Next item more than 3 h away: no pin subtitle; another day in the row line.
        let food = LocationGlance.make(locationId: 20, schedule: schedule, now: now)
        XCTAssertEqual(food.current?.id, 6)
        XCTAssertNil(food.pinSubtitle(now: now, timeZone: chicago, locale: us))
        XCTAssertEqual(plain(food.rowLine(now: now, timeZone: chicago, locale: us)),
                       "Now: Taco Tasting · Next Sun 10:00 Sunday Brunch")

        // Only ended items: nothing to say.
        let yoga = LocationGlance.make(locationId: 30, schedule: schedule, now: now)
        XCTAssertNil(yoga.current)
        XCTAssertNil(yoga.rowLine(now: now, timeZone: chicago, locale: us))
        XCTAssertNil(LocationGlance.make(locationId: 99, schedule: schedule, now: now).rowLine(now: now, timeZone: chicago))
    }

    func testNowPlaying_ItemsWithPins() {
        let locations = [
            Location(id: 20, name: "Food Court", latitude: 41.881, longitude: -87.631),
            Location(id: 10, name: "Main Stage", latitude: 41.88, longitude: -87.63),
        ]
        let items = NowPlayingItem.items(schedule: schedule, locations: locations, now: now)
        // In progress, with a pinned location, by start time; the location-less band is left out.
        XCTAssertEqual(items.map(\.title), ["Main Stage · Prairie Lights", "Food Court · Taco Tasting"])
        XCTAssertEqual(items.first?.locationId, 10)
        XCTAssertTrue(NowPlayingItem.items(schedule: schedule, locations: [], now: now).isEmpty)
    }

    func testProgress() {
        XCTAssertEqual(ScheduleTiming.progress(schedule[0], at: now) ?? -1, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertNil(ScheduleTiming.progress(schedule[1], at: now))
        XCTAssertNil(ScheduleTiming.progress(schedule[4], at: now))
    }

    // MARK: - Unread updates (§4)

    private let updates = [
        AppNotification(id: 1, title: "Gates open", sendTime: date("2026-11-13T08:00:00-06:00")),
        AppNotification(id: 2, title: "Rain plan", sendTime: date("2026-11-14T12:00:00-06:00")),
        AppNotification(id: 3, title: "Scheduled", sendTime: nil),
    ]

    func testUnread_CountsAfterSeen() {
        XCTAssertEqual(UpdatesInbox.unreadCount(updates, seenAt: nil), 2)
        XCTAssertEqual(UpdatesInbox.unreadCount(updates, seenAt: date("2026-11-14T09:00:00-06:00")), 1)
        XCTAssertEqual(UpdatesInbox.unreadCount(updates, seenAt: date("2026-11-14T12:00:00-06:00")), 0)
    }

    func testUnread_BannerNewestWithin24Hours() {
        XCTAssertEqual(UpdatesInbox.banner(updates, seenAt: nil, dismissedId: nil, now: now)?.id, 2)
        XCTAssertNil(UpdatesInbox.banner(updates, seenAt: nil, dismissedId: 2, now: now))
        XCTAssertNil(UpdatesInbox.banner(updates, seenAt: date("2026-11-14T12:30:00-06:00"), dismissedId: nil, now: now))
        // Older than 24 h: no banner, still unread.
        let later = date("2026-11-15T12:00:01-06:00")
        XCTAssertNil(UpdatesInbox.banner(updates, seenAt: nil, dismissedId: nil, now: later))
    }

    func testUnread_SeenMarkCoversServerClockAhead() {
        let ahead = [AppNotification(id: 9, title: "Soon", sendTime: date("2026-11-14T14:00:30-06:00"))]
        XCTAssertEqual(UpdatesInbox.seenMark(ahead, now: now), date("2026-11-14T14:00:30-06:00"))
        XCTAssertEqual(UpdatesInbox.seenMark(updates, now: now), now)
    }

    // MARK: - Tags (API-010)

    func testTagText_CapitalisesForDisplayOnly() {
        XCTAssertEqual(TagText.display("live music"), "Live music")
        XCTAssertEqual(TagText.display("kid-friendly"), "Kid-friendly")
        XCTAssertEqual(TagText.display("21+"), "21+")
        XCTAssertEqual(TagText.display(""), "")
        XCTAssertEqual(TagText.line(["live music", "free"]), "Live music · Free")
    }

    // MARK: - Hearts (§5)

    func testHearts_ToggleAndMetrics() {
        var state = EventPersonalState()
        XCTAssertEqual(state.setHeart(true, for: .location(5)), .locationHeart)
        XCTAssertNil(state.setHeart(true, for: .location(5)))
        XCTAssertEqual(state.setHeart(true, for: .scheduleItem(3)), .scheduleItemHeart)
        XCTAssertTrue(state.isHearted(.location(5)))
        XCTAssertTrue(state.isHearted(.scheduleItem(3)))
        XCTAssertFalse(state.isHearted(.scheduleItem(5)))
        XCTAssertNil(state.setHeart(true, for: .notification(1)))
        XCTAssertEqual(state.setHeart(false, for: .scheduleItem(3)), .scheduleItemUnheart)
        XCTAssertEqual(state.setHeart(false, for: .location(5)), .locationUnheart)
        XCTAssertNil(state.setHeart(false, for: .location(5)))
        XCTAssertFalse(state.hasHearts)
        XCTAssertEqual(UsageMetric.locationHeart.rawValue, "location_heart")
        XCTAssertEqual(UsageMetric.scheduleItemUnheart.rawValue, "schedule_item_unheart")
    }

    func testHearts_RoundTripAndLenientDecoding() throws {
        var state = EventPersonalState()
        state.setHeart(true, for: .location(5))
        state.setHeart(true, for: .scheduleItem(3))
        state.updatesSeenAt = now
        state.dismissedUpdateBannerId = 2
        let decoded = try JSONDecoder().decode(EventPersonalState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        // Unknown keys and wrong types fall back to defaults.
        let odd = Data(#"{"heartedLocations":[1,2],"heartedScheduleItems":"x","future":true}"#.utf8)
        let lenient = try JSONDecoder().decode(EventPersonalState.self, from: odd)
        XCTAssertEqual(lenient.heartedLocations, [1, 2])
        XCTAssertTrue(lenient.heartedScheduleItems.isEmpty)
        XCTAssertNil(lenient.updatesSeenAt)
    }

    func testHearts_TargetsStillInBundle() {
        var state = EventPersonalState()
        state.setHeart(true, for: .scheduleItem(2))
        state.setHeart(true, for: .scheduleItem(1))
        state.setHeart(true, for: .scheduleItem(99)) // removed by the organizer
        state.setHeart(true, for: .location(10))
        let bundle = EventBundle(
            event: Event(id: 1, name: "Fest", eventCode: "F"),
            locations: [Location(id: 10, name: "Main Stage")],
            schedule: Array(schedule.prefix(3))
        )
        XCTAssertEqual(state.heartedTargets(in: bundle), [.scheduleItem(1), .scheduleItem(2), .location(10)])
    }
}
