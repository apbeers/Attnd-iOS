// LiveFollowTests.swift
// AttndTests
//
// "Follow on Lock Screen" (Live Activity), heart reminders, the urgent block
// (API-011), `live_activity_token` and the activity's links (LiveFollowLogic.swift,
// LiveActivityModel.swift; onboarding's examples are in PlanRequestTests). Fixed `now`:
// Saturday Nov 14, 2026, 2:00 PM in America/Chicago; locale en_US.

import XCTest
@testable import Attnd

private func date(_ iso: String) -> Date {
    guard let d = ISODate.parse(iso) else { fatalError("bad fixture date \(iso)") }
    return d
}

/// "7:30\u{202F}PM" → "7:30 PM".
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

final class LiveFollowTests: XCTestCase {

    private let now = date("2026-11-14T14:00:00-06:00")
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let us = Locale(identifier: "en_US")

    private let mainStage = Location(id: 10, name: "Main Stage", latitude: 41.88, longitude: -87.63)
    private let foodCourt = Location(id: 20, name: "Food Court", latitude: 41.881, longitude: -87.631)
    private var locations: [Location] { [mainStage, foodCourt] }
    private var atFoodCourt: Coordinate { foodCourt.coordinate! }

    private let schedule: [ScheduleItem] = [
        ScheduleItem(id: 1, name: "Morning Yoga", startTime: date("2026-11-14T08:00:00-06:00"),
                     endTime: date("2026-11-14T09:00:00-06:00"), locationId: 20),
        ScheduleItem(id: 2, name: "Prairie Lights", startTime: date("2026-11-14T13:30:00-06:00"),
                     endTime: date("2026-11-14T15:00:00-06:00"), locationId: 10),
        ScheduleItem(id: 3, name: "Taco Tasting", startTime: date("2026-11-14T13:45:00-06:00"),
                     endTime: date("2026-11-14T14:30:00-06:00"), locationId: 20),
        ScheduleItem(id: 4, name: "Midnight Choir", startTime: date("2026-11-14T16:30:00-06:00"),
                     endTime: date("2026-11-14T17:30:00-06:00"), locationId: 10),
        ScheduleItem(id: 5, name: "Late Set", startTime: date("2026-11-14T20:30:00-06:00"), locationId: 10),
        ScheduleItem(id: 6, name: "Sunday Brunch", startTime: date("2026-11-15T10:00:00-06:00"),
                     endTime: date("2026-11-15T11:00:00-06:00"), locationId: 20),
        ScheduleItem(id: 7, name: "To be announced"),
    ]

    private let eventStart = date("2026-11-14T09:00:00-06:00")

    private func day(hearted: Set<Int> = [], planned: Set<Int> = [], places: [FollowPlace] = [],
                     at time: Date? = nil, schedule: [ScheduleItem]? = nil) -> FollowDay? {
        LiveActivityPlanner.followDay(
            schedule: schedule ?? self.schedule,
            hearted: hearted,
            planned: planned,
            places: places,
            eventStart: eventStart,
            now: time ?? now,
            timeZone: chicago
        )
    }

    private func content(
        _ day: FollowDay,
        hearted: Set<Int> = [],
        skipped: Set<Int> = [],
        user: Coordinate? = nil,
        userAt: Date? = nil,
        at time: Date? = nil
    ) -> EventActivityAttributes.ContentState {
        LiveActivityPlanner.content(
            day: day, locations: locations, hearted: hearted, skipped: skipped,
            user: user, userAt: userAt, urgent: nil, now: time ?? now, imperial: true, locale: us
        )
    }

    // MARK: - The followed day

    func testFollowDay_TodayWithoutHeartsFollowsTheSchedule() throws {
        let today = try XCTUnwrap(day())
        XCTAssertFalse(today.followsHearts)
        XCTAssertEqual(today.items.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(today.dayStart, date("2026-11-14T00:00:00-06:00"))
        XCTAssertEqual(today.gatesOpen, eventStart)
        // 2 h before the first item (8:00).
        XCTAssertEqual(today.startAt, date("2026-11-14T06:00:00-06:00"))
        // The last item has no end: start + 1 h.
        XCTAssertEqual(today.endAt, date("2026-11-14T21:30:00-06:00"))
    }

    func testFollowDay_HeartsWhileOneIsLeftToday() throws {
        let hearted = try XCTUnwrap(day(hearted: [2, 6]))
        XCTAssertTrue(hearted.followsHearts)
        XCTAssertEqual(hearted.items.map(\.id), [2])
        // The gates (9:00) open before the hearted item (13:30).
        XCTAssertEqual(hearted.startAt, date("2026-11-14T07:00:00-06:00"))

        // Once the hearted item is over, the rest of today's schedule.
        let later = try XCTUnwrap(day(hearted: [2, 6], at: date("2026-11-14T15:30:00-06:00")))
        XCTAssertFalse(later.followsHearts)
        // Hearts only on another day: today follows the schedule.
        XCTAssertFalse(try XCTUnwrap(day(hearted: [6])).followsHearts)
    }

    func testFollowDay_NextDayOnceTodayIsOver() throws {
        let tomorrow = try XCTUnwrap(day(at: date("2026-11-14T22:00:00-06:00")))
        XCTAssertEqual(tomorrow.dayStart, date("2026-11-15T00:00:00-06:00"))
        XCTAssertEqual(tomorrow.items.map(\.id), [6])
        XCTAssertNil(tomorrow.gatesOpen)
        XCTAssertEqual(tomorrow.startAt, date("2026-11-15T08:00:00-06:00"))
        XCTAssertNil(day(at: date("2026-11-15T12:00:00-06:00")))
    }

    func testFollowDay_ItemRunningPastMidnightCountsForToday() throws {
        let late = ScheduleItem(id: 8, name: "After Hours", startTime: date("2026-11-13T23:00:00-06:00"),
                                endTime: date("2026-11-14T01:00:00-06:00"), locationId: 10)
        let halfPast = date("2026-11-14T00:30:00-06:00")
        let today = try XCTUnwrap(day(at: halfPast, schedule: schedule + [late]))
        XCTAssertEqual(today.dayStart, date("2026-11-14T00:00:00-06:00"))
        XCTAssertEqual(today.items.first?.id, 8)
        XCTAssertEqual(content(today, at: halfPast).current?.id, 8)
    }

    // MARK: - When to start

    func testDecision() throws {
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(), now: now, timeZone: chicago), .startNow)

        let dayBefore = date("2026-11-13T12:00:00-06:00")
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(at: dayBefore), now: dayBefore, timeZone: chicago),
                       .schedule(date("2026-11-14T06:00:00-06:00")))
        // More than 36 h ahead: nothing yet (a later app open schedules it).
        let twoDaysBefore = date("2026-11-12T12:00:00-06:00")
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(at: twoDaysBefore), now: twoDaysBefore, timeZone: chicago), .nothing)

        // Forced ("Start now", the follow notification) skips the 2 h lead today only.
        let early = date("2026-11-14T04:00:00-06:00")
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(at: early), now: early, timeZone: chicago),
                       .schedule(date("2026-11-14T06:00:00-06:00")))
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(at: early), now: early, timeZone: chicago, forced: true), .startNow)
        let night = date("2026-11-14T22:00:00-06:00")
        XCTAssertEqual(LiveActivityPlanner.decision(for: day(at: night), now: night, timeZone: chicago, forced: true),
                       .schedule(date("2026-11-15T08:00:00-06:00")))
        XCTAssertEqual(LiveActivityPlanner.decision(for: nil, now: now, timeZone: chicago), .nothing)
    }

    // MARK: - Content

    func testContent_CurrentNextAfterAndWalk() throws {
        let state = content(try XCTUnwrap(day()), hearted: [4], user: atFoodCourt)
        // Two items are on; the one that started last is current.
        XCTAssertEqual(state.current?.id, 3)
        XCTAssertEqual(state.current?.location, "Food Court")
        XCTAssertEqual(state.next?.id, 4)
        XCTAssertEqual(state.next?.name, "Midnight Choir")
        XCTAssertEqual(state.next?.location, "Main Stage")
        XCTAssertEqual(state.next?.locationId, 10)
        XCTAssertEqual(state.next?.hearted, true)
        XCTAssertEqual(state.after?.id, 5)
        // No end: start + 1 h.
        XCTAssertEqual(state.after?.end, date("2026-11-14T21:30:00-06:00"))
        // ~139 m to Main Stage: 139 × 1.2 / 1.3 m/s, rounded up.
        XCTAssertEqual(state.walkMinutesToNext, 3)
        XCTAssertEqual(state.followsHearts, false)
        XCTAssertNil(state.opensAt)
        XCTAssertNil(state.dayComplete)
        XCTAssertNil(state.urgent)
    }

    func testContent_SkipAndNoLocation() throws {
        let state = content(try XCTUnwrap(day()), skipped: [4])
        XCTAssertEqual(state.next?.id, 5)
        XCTAssertNil(state.after)
        XCTAssertNil(state.walkMinutesToNext)
    }

    func testContent_GatesOpenAndDayComplete() throws {
        let early = date("2026-11-14T07:30:00-06:00")
        let noYoga = Array(schedule.dropFirst())
        let morning = content(try XCTUnwrap(day(at: early, schedule: noYoga)), at: early)
        XCTAssertEqual(morning.opensAt, eventStart)
        XCTAssertNil(morning.current)
        XCTAssertEqual(morning.next?.id, 2)

        let done = content(try XCTUnwrap(day()), at: date("2026-11-14T22:00:00-06:00"))
        XCTAssertEqual(done.dayComplete, true)
        XCTAssertEqual(done.completedCount, 5)
        XCTAssertNil(done.current)
        XCTAssertNil(done.next)
    }

    func testStaleDate() throws {
        let state = content(try XCTUnwrap(day()))
        // Without a position Now is the earliest started (Prairie Lights, ends 15:00, before
        // Next starts at 16:30), plus a minute.
        XCTAssertEqual(state.current?.id, 2)
        XCTAssertEqual(LiveActivityPlanner.staleDate(state, now: now), date("2026-11-14T15:01:00-06:00"))
        XCTAssertEqual(LiveActivityPlanner.staleDate(EventActivityAttributes.ContentState(), now: now),
                       now.addingTimeInterval(3600))
    }

    // MARK: - Urgent block (API-011)

    func testUrgent_NewestFromTheBundleElseThePushedOne() {
        let notifications = [
            AppNotification(id: 7, title: "Water refill", sendTime: date("2026-11-14T13:50:00-06:00")),
            AppNotification(id: 8, title: "Old warning", sendTime: date("2026-11-14T01:00:00-06:00"), priority: .urgent),
            AppNotification(id: 9, title: "Main Stage closed", body: "Storm on the way",
                            sendTime: date("2026-11-14T13:40:00-06:00"), priority: .urgent),
        ]
        let urgent = LiveActivityPlanner.urgent(notifications: notifications, dismissed: [], existing: nil, now: now)
        XCTAssertEqual(urgent?.id, 9)
        XCTAssertEqual(urgent?.title, "Main Stage closed")
        XCTAssertEqual(urgent?.body, "Storm on the way")
        XCTAssertEqual(urgent?.sentAt.flatMap(ISODate.parse), date("2026-11-14T13:40:00-06:00"))
        // Older than 12 h or dismissed: gone.
        XCTAssertNil(LiveActivityPlanner.urgent(notifications: notifications, dismissed: [9], existing: nil, now: now))
        XCTAssertEqual(UpdatesInbox.urgent(notifications, dismissed: [], now: now)?.id, 9)

        // Only in the activity (the push arrived before the bundle): kept while ≤ 12 h old.
        let pushed = EventActivityAttributes.Urgent(id: 11, title: "Gate B closed", body: "Use gate A",
                                                     sentAt: "2026-11-14T19:00:00+00:00")
        XCTAssertEqual(LiveActivityPlanner.urgent(notifications: [], dismissed: [], existing: pushed, now: now), pushed)
        XCTAssertNil(LiveActivityPlanner.urgent(notifications: [], dismissed: [11], existing: pushed, now: now))
        XCTAssertNil(LiveActivityPlanner.urgent(notifications: [], dismissed: [], existing: pushed,
                                                now: date("2026-11-15T08:00:00-06:00")))
    }

    func testContentState_DecodesTheServersUrgentPush() throws {
        // API_V2.md's Live Activity push: content-state carries only `urgent`.
        let json = #"{"urgent": {"id": 9, "title": "Main Stage closed", "body": "Storm on the way…", "sent_at": "2026-11-15T16:40:00+00:00"}}"#
        let state = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state.urgent?.id, 9)
        XCTAssertEqual(state.urgent?.title, "Main Stage closed")
        XCTAssertEqual(state.urgent?.sentAt, "2026-11-15T16:40:00+00:00")
        XCTAssertNil(state.current)
        XCTAssertNil(state.next)
        XCTAssertNil(state.walkMinutesToNext)

        // Empty, unknown keys and wrong types never fail.
        XCTAssertEqual(try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data("{}".utf8)),
                       EventActivityAttributes.ContentState())
        let odd = #"{"walk_minutes_to_next": "soon", "urgent": {"id": "12"}, "extra": true}"#
        let lenient = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data(odd.utf8))
        XCTAssertNil(lenient.walkMinutesToNext)
        XCTAssertEqual(lenient.urgent?.id, 12)
    }

    func testContentState_RoundTrips() throws {
        var state = content(try XCTUnwrap(day()), user: atFoodCourt)
        state.urgent = EventActivityAttributes.Urgent(id: 9, title: "T", body: "B", sentAt: "2026-11-14T19:40:00Z")
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: data), state)
        // The wire name the server uses.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sent_at\""))
    }

    // MARK: - live_activity_token (API-011)

    private func deviceJSON(_ change: LiveActivityTokenChange) throws -> [String: Any] {
        let request = DeviceRequest(deviceId: "d1", pushToken: nil, appVersion: "2.0.1", subscribed: false, liveActivityToken: change)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }

    func testDeviceRequest_LiveActivityToken() throws {
        let unchanged = try deviceJSON(.unchanged)
        XCTAssertNil(unchanged["live_activity_token"])
        XCTAssertNil(unchanged["push_token"])
        XCTAssertEqual(unchanged["device_id"] as? String, "d1")
        XCTAssertEqual(unchanged["platform"] as? String, "ios")
        XCTAssertEqual(unchanged["subscribed"] as? Bool, false)

        XCTAssertEqual(try deviceJSON(.set("80f3a1"))["live_activity_token"] as? String, "80f3a1")

        let cleared = try deviceJSON(.clear)
        XCTAssertTrue(cleared.keys.contains("live_activity_token"))
        XCTAssertTrue(cleared["live_activity_token"] is NSNull)
    }

    // MARK: - Links

    func testLinks_RoundTrip() {
        let links: [LiveActivityLink] = [.item(12), .map(locationId: 5), .updates(notificationId: 9), .updates(notificationId: nil), .follow, .plan, .place(3)]
        for link in links {
            let url = link.url(eventId: 42)
            XCTAssertEqual(LiveActivityLink.parse(url)?.eventId, 42, url.absoluteString)
            XCTAssertEqual(LiveActivityLink.parse(url)?.link, link, url.absoluteString)
        }
        XCTAssertEqual(LiveActivityLink.item(12).url(eventId: 42).absoluteString, "attnd-live://event/42/item/12")
        XCTAssertEqual(LiveActivityLink.updates(notificationId: 9).url(eventId: 42).absoluteString, "attnd-live://event/42/updates/9")
        for bad in ["attnd-live://event/x/item/1", "attnd-live://event/4/item", "attnd-live://event/4/item/1/2",
                    "attnd-live://other/4/item/1", "attnd-live://event/4/tickets/1", "https://attnd.app/join/DEMO/"] {
            XCTAssertNil(LiveActivityLink.parse(URL(string: bad)!), bad)
        }
    }

    // MARK: - Reminders

    func testReminders_BeforeHeartedItemsWithWalk() {
        let reminders = ReminderPlanner.reminders(
            eventId: 1, schedule: schedule, hearted: [2, 4, 5, 6, 7], locations: locations,
            user: atFoodCourt, now: now, timeZone: chicago, locale: us
        )
        // 2 has started (its reminder time passed), 7 has no time.
        XCTAssertEqual(reminders.map(\.itemId), [4, 5, 6])
        XCTAssertEqual(reminders[0].id, "attnd.reminder.1.4")
        XCTAssertEqual(reminders[0].fireDate, date("2026-11-14T16:15:00-06:00"))
        XCTAssertEqual(reminders[0].title, "Midnight Choir in 15 min · 3 min walk")
        XCTAssertEqual(plain(reminders[0].body), "Main Stage · 4:30 PM")
        XCTAssertEqual(plain(reminders[1].body), "Main Stage · 8:30 PM")
        // Already at the Food Court: no walk.
        XCTAssertEqual(reminders[2].title, "Sunday Brunch in 15 min")
        XCTAssertEqual(plain(reminders[2].body), "Food Court · 10:00 AM")

        let noLocation = ReminderPlanner.reminders(
            eventId: 1, schedule: schedule, hearted: [4], locations: locations,
            user: nil, now: now, timeZone: chicago, locale: us
        )
        XCTAssertEqual(noLocation.first?.title, "Midnight Choir in 15 min")
        XCTAssertTrue(ReminderPlanner.reminders(
            eventId: 1, schedule: schedule, hearted: [], locations: locations,
            user: nil, now: now, timeZone: chicago
        ).isEmpty)
    }

    // MARK: - "Tap to follow" text

    func testFollowPromptText() throws {
        let night = date("2026-11-14T22:00:00-06:00")
        let sunday = try XCTUnwrap(day(at: night))
        XCTAssertEqual(
            FollowPromptText.body(day: sunday, at: sunday.startAt, timeZone: chicago, locale: us),
            "Sunday Brunch in 2 h · tap to follow on your Lock Screen"
        )
        let early = date("2026-11-14T07:30:00-06:00")
        let morning = try XCTUnwrap(day(at: early, schedule: Array(schedule.dropFirst())))
        XCTAssertEqual(FollowPromptText.headline(day: morning, at: early, timeZone: chicago, locale: us), "Gates open in 1 h 30 min")
        // Arriving while something is on.
        XCTAssertEqual(FollowPromptText.headline(day: try XCTUnwrap(day()), at: now, timeZone: chicago, locale: us),
                       "Prairie Lights started 30 min ago")
    }

    // MARK: - The plan (spec §6): plan > hearts > the event's own day

    func testFollowDay_PlanWinsOverHearts() throws {
        let planned = try XCTUnwrap(day(hearted: [4], planned: [2, 5]))
        XCTAssertTrue(planned.followsPlan)
        XCTAssertFalse(planned.followsHearts)
        XCTAssertEqual(planned.items.map(\.id), [2, 5])
        let state = content(planned)
        XCTAssertEqual(state.followsPlan, true)
        XCTAssertEqual(state.followSymbol, "list.bullet.clipboard")
        XCTAssertEqual(state.current?.id, 2)
        XCTAssertEqual(state.next?.id, 5)
    }

    func testFollowDay_PlanOverTodayFallsBackToHearts() throws {
        // Only Morning Yoga (ended) was planned today: hearts take over, then the schedule.
        let hearts = try XCTUnwrap(day(hearted: [4], planned: [1]))
        XCTAssertFalse(hearts.followsPlan)
        XCTAssertTrue(hearts.followsHearts)
        XCTAssertEqual(hearts.items.map(\.id), [4])
        XCTAssertNil(content(hearts).followsPlan)
        let everything = try XCTUnwrap(day(planned: [1]))
        XCTAssertFalse(everything.followsPlan)
        XCTAssertFalse(everything.followsHearts)
        XCTAssertEqual(everything.items.map(\.id), [1, 2, 3, 4, 5])
    }

    // MARK: - Now / Next always filled (owner, Nov 21, 2026)

    func testContent_GapInMyScheduleShowsWhatsOnAtTheEvent() throws {
        let mine = try XCTUnwrap(day(hearted: [4]))
        XCTAssertEqual(mine.eventItems.map(\.id), [1, 2, 3, 4, 5])
        // Nothing of mine on: the event's item nearest to the user (Taco Tasting at the Food Court).
        let state = content(mine, hearted: [4], user: atFoodCourt)
        XCTAssertEqual(state.current?.id, 3)
        XCTAssertEqual(state.nowSource, "event")
        XCTAssertTrue(state.nowIsFromEvent)
        XCTAssertEqual(state.next?.id, 4)
        XCTAssertEqual(state.nextSource, "schedule")
        XCTAssertEqual(state.freeUntil, date("2026-11-14T16:30:00-06:00"))
        // Without a position: the earliest started (Prairie Lights, 1:30 PM).
        XCTAssertEqual(content(mine, hearted: [4]).current?.id, 2)

        // Mine in progress: no gap, Now from My schedule.
        let planned = content(try XCTUnwrap(day(planned: [2, 5])))
        XCTAssertEqual(planned.nowSource, "schedule")
        XCTAssertNil(planned.freeUntil)

        // Nothing of mine left after Next: Next comes from the event.
        let lastMine = content(try XCTUnwrap(day(hearted: [2])), hearted: [2])
        XCTAssertEqual(lastMine.current?.id, 2)
        XCTAssertEqual(lastMine.next?.id, 4)
        XCTAssertEqual(lastMine.nextSource, "event")
        XCTAssertNil(lastMine.freeUntil)
    }

    func testContent_TimedPlacesOfMySchedule() throws {
        let dinner = FollowPlace(locationId: 20, name: "Food Court",
                                 start: date("2026-11-14T15:00:00-06:00"), end: date("2026-11-14T15:45:00-06:00"))
        // Only a place today: it is followed (My schedule), the event fills Now.
        let onlyPlace = try XCTUnwrap(day(places: [dinner]))
        XCTAssertTrue(onlyPlace.followsHearts)
        XCTAssertEqual(onlyPlace.places, [dinner])
        let state = content(onlyPlace)
        XCTAssertEqual(state.nowSource, "event")
        XCTAssertEqual(state.next?.kind, "place")
        XCTAssertTrue(try XCTUnwrap(state.next).isPlace)
        XCTAssertNil(state.next?.id)
        XCTAssertEqual(state.next?.locationId, 20)
        XCTAssertEqual(state.next?.link, .place(20))
        XCTAssertEqual(state.freeUntil, dinner.start)

        // With an item: by start.
        let both = content(try XCTUnwrap(day(hearted: [4], places: [dinner])), hearted: [4])
        XCTAssertEqual(both.next?.kind, "place")
        XCTAssertEqual(both.after?.id, 4)
        XCTAssertEqual(both.after?.link, .item(4))
        // During dinner Now is the place.
        let during = content(try XCTUnwrap(day(hearted: [4], places: [dinner])), hearted: [4], at: date("2026-11-14T15:10:00-06:00"))
        XCTAssertEqual(during.current?.locationId, 20)
        XCTAssertEqual(during.nowSource, "schedule")
        XCTAssertEqual(during.next?.id, 4)
        // A place a day ahead makes that day's start.
        XCTAssertNil(day(places: [dinner], at: date("2026-11-14T23:30:00-06:00"))?.places.first)
    }

    func testContent_DirectionAndDistanceToNext() throws {
        let state = content(try XCTUnwrap(day()), user: atFoodCourt, userAt: now.addingTimeInterval(-600))
        XCTAssertEqual(state.next?.id, 4)
        // Main Stage is south-east of the Food Court, ~139 m (450 ft).
        XCTAssertEqual(state.nextPoint, CompassPoint.southeast.rawValue)
        XCTAssertEqual(state.nextDistance, "450 ft")
        XCTAssertEqual(state.nextDirectionLabel, "Southeast, 450 feet")
        XCTAssertEqual(state.nextArrow, "↘")
        XCTAssertEqual(state.nextDirectionLine, "↘ 450 ft · 3 min walk")

        // A position older than 30 min: nothing.
        let stale = content(try XCTUnwrap(day()), user: atFoodCourt, userAt: now.addingTimeInterval(-31 * 60))
        XCTAssertNil(stale.walkMinutesToNext)
        XCTAssertNil(stale.nextPoint)
        XCTAssertNil(stale.nextDirectionLine)
        // At the place itself (< 20 m): no arrow or distance.
        let here = content(try XCTUnwrap(day()), user: mainStage.coordinate!)
        XCTAssertNil(here.nextPoint)
        XCTAssertNil(here.nextDistance)
        XCTAssertEqual(here.nextDirectionLine, "\(here.walkMinutesToNext ?? 0) min walk")
    }

    func testContentState_NewFieldsRoundTripAndStayLenient() throws {
        var state = content(try XCTUnwrap(day(hearted: [4])), hearted: [4], user: atFoodCourt)
        state.nextPoint = 1
        let data = try JSONEncoder().encode(state)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"now_source\""))
        XCTAssertTrue(text.contains("\"free_until\""))
        XCTAssertEqual(try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: data), state)
        let odd = #"{"next_point": 9, "now_source": 3, "free_until": "soon"}"#
        let lenient = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: Data(odd.utf8))
        XCTAssertNil(lenient.nextPoint)
        XCTAssertNil(lenient.nowSource)
        XCTAssertNil(lenient.freeUntil)
    }

    // MARK: - Theme (API-023)

    func testActivityTheme_FromTheEventsThemeAndLenientAttributes() throws {
        XCTAssertNil(LiveThemeMapping.activityTheme(nil))
        XCTAssertNil(LiveThemeMapping.activityTheme(EventTheme()))
        let theme = EventTheme(light: ThemeColors(primary: "#0B6E4F", secondary: "#CDEBDD", tertiary: "#C4471B"),
                               dark: ThemeColors(primary: "#5FD3A6"))
        let mapped = try XCTUnwrap(LiveThemeMapping.activityTheme(theme))
        XCTAssertEqual(mapped.hex(\.primary, dark: false), "#0B6E4F")
        XCTAssertEqual(mapped.hex(\.primary, dark: true), "#5FD3A6")
        // A role missing in dark uses light's.
        XCTAssertEqual(mapped.hex(\.tertiary, dark: true), "#C4471B")

        let attributes = EventActivityAttributes(eventId: 1, eventName: "Fest", accentHex: "#431F86",
                                                 timeZoneIdentifier: "America/Chicago", dayStart: now, theme: mapped)
        let data = try JSONEncoder().encode(attributes)
        XCTAssertEqual(try JSONDecoder().decode(EventActivityAttributes.self, from: data).theme, mapped)
        // Attributes from an older build (no theme) and a malformed theme still decode.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["theme"] = nil
        let old = try JSONDecoder().decode(EventActivityAttributes.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.theme)
        XCTAssertEqual(old.accentHex, "#431F86")
        object["theme"] = "purple"
        XCTAssertNil(try JSONDecoder().decode(EventActivityAttributes.self, from: JSONSerialization.data(withJSONObject: object)).theme)
    }

    // MARK: - Personal state

    func testPersonalState_FollowDefaultsAndOldFiles() throws {
        let old = try JSONDecoder().decode(EventPersonalState.self, from: Data(#"{"heartedScheduleItems": [2]}"#.utf8))
        XCTAssertTrue(old.followsOnLockScreen)
        XCTAssertTrue(old.skippedItems.isEmpty)
        XCTAssertTrue(old.dismissedUrgentIds.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(EventPersonalState.self, from: Data("{}".utf8)).followsOnLockScreen,
                      "on by default: the activity starts on join (batch 7)")

        var state = old
        state.followOnLockScreen = false
        state.skippedItems = [4]
        state.dismissedUrgentIds = [9]
        let decoded = try JSONDecoder().decode(EventPersonalState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertFalse(decoded.followsOnLockScreen)
    }

    func testInputs_LiveActivitySettings() {
        let event = Event(id: 1, name: "E", eventCode: "E")
        let bundle = EventBundle(event: event, locations: locations, schedule: schedule)
        let place = FollowPlace(locationId: 20, name: "Food Court", start: now, end: now.addingTimeInterval(2700))
        let mine = LiveActivityPlanner.inputs(nil, bundle: bundle, hearted: [2], planned: [3], places: [place])
        XCTAssertEqual(mine.hearted, [2])
        XCTAssertEqual(mine.planned, [3])
        XCTAssertEqual(mine.places.count, 1)
        let all = LiveActivityPlanner.inputs(LiveActivitySettings(follows: .everything), bundle: bundle, hearted: [2], planned: [3], places: [place])
        XCTAssertTrue(all.hearted.isEmpty && all.planned.isEmpty && all.places.isEmpty)
        XCTAssertEqual(all.schedule.count, schedule.count)
        let stage = LiveActivityPlanner.inputs(LiveActivitySettings(follows: .location, locationId: 10), bundle: bundle, hearted: [3], planned: [], places: [])
        XCTAssertEqual(stage.schedule.map(\.id), [2, 4, 5])
        XCTAssertTrue(stage.hearted.isEmpty)
        // An unknown place falls back to My schedule.
        XCTAssertEqual(LiveActivityPlanner.inputs(LiveActivitySettings(follows: .location, locationId: 99), bundle: bundle, hearted: [3], planned: [], places: []).hearted, [3])
    }

    func testContentState_ButtonsAndStaleText() throws {
        var state = EventActivityAttributes.ContentState()
        XCTAssertTrue(state.showsButton("skip"))
        state.buttons = ["map"]
        state.staleText = "Open the app"
        XCTAssertFalse(state.showsButton("skip"))
        XCTAssertTrue(state.showsButton("map"))
        let again = try JSONDecoder().decode(EventActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(again.buttons, ["map"])
        XCTAssertEqual(again.staleText, "Open the app")
    }
}
