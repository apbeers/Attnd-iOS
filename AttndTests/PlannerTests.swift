// PlannerTests.swift
// AttndTests
//
// Shared spec §6 (the same cases and numbers as Android's `unit/PlannerTest.kt`): TF-IDF
// similarity, scores, the chosen plan, pace, meals, reasons, swap, changes and storage
// (Planner.swift). Fixture: PlannerFixture (America/Chicago, now Sat Nov 14, 2026, 10:00 AM).

import XCTest
@testable import Attnd

final class PlannerTests: XCTestCase {

    private var bundle: EventBundle { PlannerFixture.bundle }
    private var now: Date { PlannerFixture.now }
    private let chicago = PlannerFixture.chicago
    private let us = Locale(identifier: "en_US")
    private let saturday = PlanDate(year: 2026, month: 11, day: 14)
    private let sunday = PlanDate(year: 2026, month: 11, day: 15)

    private let musicAndBbq = PlanPreferences(likedTags: ["live music", "bbq"], includeMeals: true)

    private func planner(_ preferences: PlanPreferences, hearted: Set<Int> = PlannerFixture.heartedItems) -> Planner {
        Planner(bundle: bundle, preferences: preferences, heartedItems: hearted)
    }

    /// "10:00 111", "12:00 lunch" … (event-zone clock times).
    private func clock(_ plan: Plan) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        return plan.days.flatMap { day in
            day.entries.map { entry in
                let c = calendar.dateComponents([.hour, .minute], from: entry.start)
                let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                switch entry {
                case .item(let item): return "\(time) \(item.itemId)"
                case .meal(let meal): return "\(time) \(meal.kind.rawValue)"
                }
            }
        }
    }

    private func item(_ id: Int) -> ScheduleItem {
        bundle.schedule.first { $0.id == id }!
    }

    private func planned(_ plan: Plan, _ id: Int) -> PlannedItem {
        plan.items.first { $0.itemId == id }!
    }

    private func minutes(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) / 60) }

    // MARK: - Similarity and scores

    func testTfIdfSimilarity() {
        let similarity = TfIdfSimilarity(bundle)
        func s(_ a: Int, _ b: Int) -> Double { similarity.similarity(item(a), item(b)) }
        XCTAssertEqual(s(101, 101), 1.0)
        XCTAssertEqual(s(101, 103), 0.4854, accuracy: 0.0001) // both country, "Texas", live music
        XCTAssertEqual(s(101, 114), 0.2108, accuracy: 0.0001)
        XCTAssertEqual(s(101, 106), 0.0551, accuracy: 0.0001)
        XCTAssertEqual(s(106, 107), 0.4586, accuracy: 0.0001) // chef demos at the same kitchen
        XCTAssertEqual(s(101, 111), 0.0) // nothing shared
        XCTAssertEqual(s(103, 101), s(101, 103))
    }

    func testScoresAreIntegerMilliPoints() {
        let planner = planner(musicAndBbq)
        XCTAssertEqual(planner.score(item(101)), 4922) // 0.5 + 3 + 2·0.2108 + 1
        XCTAssertEqual(planner.score(item(114)), 4922)
        XCTAssertEqual(planner.score(item(103)), 2471) // 0.5 + 2·0.4854 + 1
        XCTAssertEqual(planner.score(item(106)), 1610) // bbq: 0.5 + 2·0.0551 + 1
        XCTAssertEqual(planner.score(item(111)), 500) // base only
        let disliked = Planner(bundle: bundle, preferences: PlanPreferences(dislikedTags: ["dj"]))
        XCTAssertEqual(disliked.score(item(104)), -1500)
    }

    // MARK: - Plans

    func testBalancedPlanKeepsTheBetterHeartedItemAndOffersTheOther() throws {
        let plan = planner(musicAndBbq).plan(from: now, request: "Plan my Saturday around live music and BBQ")
        XCTAssertEqual(clock(plan), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertEqual(plan.days.count, 1)
        let day = try XCTUnwrap(plan.days.first)
        XCTAssertEqual(day.date, saturday)
        // Neon Armadillo clashes with The Prairie Lights (same score, later start): "or instead".
        let prairie = planned(plan, 101)
        XCTAssertEqual(prairie.orInstead, [114])
        XCTAssertEqual(prairie.alternatives, [114])
        XCTAssertEqual(prairie.reason, "You liked this")
        XCTAssertEqual(prairie.walkMinutes, 4)
        // The lunch break suggests the food location nearest to where the attendee was.
        XCTAssertEqual(day.meals.count, 1)
        let lunch = try XCTUnwrap(day.meals.first)
        XCTAssertEqual(lunch.kind, .lunch)
        XCTAssertEqual(lunch.locationId, 6)
        XCTAssertEqual(minutes(lunch.start, lunch.end), 45)
        // Reasons and walks.
        XCTAssertEqual(planned(plan, 103).reason, "Because you liked The Prairie Lights")
        XCTAssertEqual(planned(plan, 104).reason, "Because you like live music")
        XCTAssertNil(plan.items[0].walkMinutes) // first item of the day
        XCTAssertNil(plan.items[1].walkMinutes) // Gates open has no location
        XCTAssertEqual(planned(plan, 103).walkMinutes, 0) // same stage as Ana Morales Trio
        XCTAssertEqual(planned(plan, 109).alternatives, [106])
    }

    func testSummaryLine() {
        let plan = planner(musicAndBbq).plan(from: now, request: "")
        XCTAssertEqual(Planner.summary(plan, timeZone: chicago, locale: us), "8 items, 10:00 AM – 11:00 PM, with a lunch break")
        let empty = Planner(bundle: bundle, preferences: PlanPreferences(days: [sunday], earliest: PlanClock(hour: 22, minute: 0)))
            .plan(from: now, request: "")
        XCTAssertEqual(Planner.summary(empty, timeZone: chicago, locale: us), "Nothing fits")
    }

    func testPaceCapsTheBookedShare() {
        var relaxedPreferences = musicAndBbq
        relaxedPreferences.pace = .relaxed
        let relaxed = planner(relaxedPreferences).plan(from: now, request: "")
        XCTAssertEqual(clock(relaxed), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"])
        // Span 10:00–23:00 = 780 min; relaxed books at most 390.
        XCTAssertEqual(relaxed.items.reduce(0) { $0 + minutes($1.start, $1.end) }, 390)
        XCTAssertEqual(planned(relaxed, 101).alternatives, [114, 104])

        let packed = Planner(bundle: bundle, preferences: PlanPreferences(pace: .packed)).plan(from: now, request: "")
        XCTAssertEqual(clock(packed), ["10:00 111", "12:00 106", "13:00 102", "14:15 107", "16:15 110", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertTrue(packed.items.allSatisfy { $0.reason == "Fits your day" })
    }

    func testKidFriendlyWithThreeHours() throws {
        let plan = Planner(bundle: bundle, preferences: PlanPreferences(durationMinutes: 180, kidFriendly: true)).plan(from: now, request: "")
        XCTAssertEqual(plan.days.count, 1)
        let day = try XCTUnwrap(plan.days.first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: day.windowEnd), DateComponents(hour: 13, minute: 0))
        XCTAssertEqual(clock(plan), ["11:00 108"])
        XCTAssertEqual(plan.items.first?.reason, "Kid-friendly")
        XCTAssertEqual(plan.items.first?.alternatives, [111, 109, 106])
        // The 21+ tasting never appears with kids.
        let evening = Planner(bundle: bundle, preferences: PlanPreferences(earliest: PlanClock(hour: 17, minute: 0), kidFriendly: true))
            .plan(from: now, request: "")
        XCTAssertFalse(evening.itemIds.contains(112))
    }

    func testNamedDayAndLikedTag() {
        let plan = planner(PlanPreferences(likedTags: ["rock"], days: [sunday])).plan(from: now, request: "")
        XCTAssertEqual(clock(plan), ["09:00 203", "12:00 201", "14:00 202"])
        XCTAssertEqual(plan.days.map(\.date), [sunday])
        // Days that aren't event days are ignored; with none left the first day with candidates is planned.
        let fallback = Planner(bundle: bundle, preferences: PlanPreferences(days: [PlanDate(year: 2026, month: 12, day: 1)]))
            .plan(from: now, request: "")
        XCTAssertEqual(fallback.days.map(\.date), [saturday])
    }

    func testEveningWithDislikeAndExample() {
        let plan = Planner(
            bundle: bundle,
            preferences: PlanPreferences(dislikedTags: ["dj"], similarTo: [103], earliest: PlanClock(hour: 17, minute: 0))
        ).plan(from: now, request: "")
        XCTAssertEqual(clock(plan), ["17:00 105", "18:15 113", "20:00 114"])
        XCTAssertEqual(planned(plan, 114).reason, "Like Big Sky Radio")
        XCTAssertFalse(plan.itemIds.contains(104))
    }

    func testLatestBeforeSixIsTheNextMorning() throws {
        let plan = Planner(
            bundle: bundle,
            preferences: PlanPreferences(earliest: PlanClock(hour: 20, minute: 0), latest: PlanClock(hour: 1, minute: 0))
        ).plan(from: now, request: "")
        XCTAssertEqual(plan.days.count, 1)
        XCTAssertEqual(ISODate.string(from: try XCTUnwrap(plan.days.first).windowEnd), "2026-11-15T07:00:00Z")
        // Span 20:00–23:00 = 180 min, cap 126: one of Neon Armadillo (60) and DJ Lone Star (120);
        // equal scores, so the one that books fewer minutes.
        XCTAssertEqual(clock(plan), ["20:00 114"])
        XCTAssertEqual(plan.items.first?.alternatives, [104])
    }

    func testReplanFromLaterDropsStartedItems() throws {
        let later = now.addingTimeInterval(9 * 3600) // 7:00 PM
        let plan = planner(musicAndBbq).plan(from: later, request: "")
        // Span 19:00–23:00 = 240 min, cap 168: The Prairie Lights (90) leaves no room for DJ Lone Star (120).
        XCTAssertEqual(clock(plan), ["19:00 101"])
        XCTAssertEqual(plan.items.first?.alternatives, [114, 104])
        XCTAssertEqual(ISODate.string(from: try XCTUnwrap(plan.days.first).windowStart), "2026-11-15T01:00:00Z")
    }

    func testSwapReplacesAnItemWithAnAlternative() throws {
        let planner = planner(musicAndBbq)
        let plan = planner.plan(from: now, request: "")
        let swapped = try XCTUnwrap(planner.swap(plan, oldId: 101, newId: 114))
        XCTAssertTrue(swapped.itemIds.contains(114))
        XCTAssertFalse(swapped.itemIds.contains(101))
        let neon = planned(swapped, 114)
        XCTAssertEqual(neon.orInstead, [101]) // the hearted one can be swapped back
        XCTAssertEqual(neon.alternatives.first, 101)
        XCTAssertNil(planner.swap(plan, oldId: 101, newId: 9999))
        XCTAssertNil(planner.swap(plan, oldId: 9999, newId: 114))
    }

    func testChangesAreNoticed() {
        let plan = planner(musicAndBbq).plan(from: now, request: "")
        XCTAssertFalse(Planner.changed(plan, schedule: bundle.schedule))
        let moved = bundle.schedule.map { item -> ScheduleItem in
            guard item.id == 105 else { return item }
            var copy = item
            copy.startTime = PlannerFixture.sat("20:30")
            copy.endTime = PlannerFixture.sat("21:30")
            return copy
        }
        XCTAssertTrue(Planner.changed(plan, schedule: moved))
        XCTAssertTrue(Planner.changed(plan, schedule: bundle.schedule.filter { $0.id != 113 }))
        let unrelated = bundle.schedule.map { item -> ScheduleItem in
            guard item.id == 112 else { return item }
            var copy = item
            copy.name = "Beer flight"
            return copy
        }
        XCTAssertFalse(Planner.changed(plan, schedule: unrelated))
    }

    func testCodecRoundTripsAndIsLenient() throws {
        var preferences = musicAndBbq
        preferences.earliest = PlanClock(hour: 10, minute: 0)
        preferences.days = [saturday]
        let plan = planner(preferences).plan(from: now, request: "Plan my Saturday")
        XCTAssertEqual(PlanCodec.decode(PlanCodec.encode(plan)), plan)
        XCTAssertNil(PlanCodec.decode("not json"))
        XCTAssertNil(PlanCodec.decode(""))
        let extra = try XCTUnwrap(PlanCodec.decode(#"{"eventId":42,"createdAt":"2026-11-14T16:00:00Z","future":1,"days":[]}"#))
        XCTAssertEqual(extra.eventId, 42)
        XCTAssertTrue(extra.isEmpty)
    }

    func testWalkMinutesMatchAndroid() {
        // Main Stage → Trinity Stage, the straight-line estimate rounded like Android's Walking.
        let main = PlannerFixture.locations[0].coordinate!
        let trinity = PlannerFixture.locations[1].coordinate!
        XCTAssertEqual(Planner.walkMinutes(meters: Planner.distance(main, trinity)), 4)
        XCTAssertEqual(Planner.walkMinutes(meters: 0), 1)
        XCTAssertEqual(Planner.walkMinutes(meters: 65), 1) // 60 s
        XCTAssertEqual(Planner.walkMinutes(meters: 66), 2) // 61 s
    }
}
