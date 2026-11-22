// MyScheduleTests.swift
// AttndTests
//
// My schedule (iOS, Nov 21, 2026; iOS diverges from Android): entries, migration from likes and
// plans, add / remove / time / reminder, API-009 metrics only on real changes, the Schedule
// section's order, Home's up next, clashes, the planner filling My schedule, organizer changes.

import XCTest
@testable import Attnd

final class MyScheduleTests: XCTestCase {
    private let bundle = PlannerFixture.bundle
    private let now = PlannerFixture.now  // Sat 10:00 AM
    private let zone = PlannerFixture.chicago

    func testMigrationFromLikesAndPlan() {
        let plan = AssistantFixture.plan
        let migrated = MySchedule.migrate(heartedItems: [101, 114], heartedLocations: [6], plan: plan)
        // Hearted items, then the plan's other items; hearted places saved; the plan's lunch at
        // its food place becomes a place entry at the break's time.
        XCTAssertEqual(migrated.itemIds, Set([101, 114]).union(plan.itemIds))
        XCTAssertTrue(migrated.placeIds.contains(6))
        let meal = plan.days.flatMap(\.meals).first { $0.locationId != nil }
        if let meal, let id = meal.locationId {
            XCTAssertEqual(migrated.entry(.place, id)?.at, meal.start)
        }
        // Once per event: EventPersonalState migrates only while it has no schedule.
        var personal = EventPersonalState()
        personal.heartedScheduleItems = [101]
        XCTAssertTrue(personal.migrateSchedule(plan: nil))
        XCTAssertFalse(personal.migrateSchedule(plan: plan))
        XCTAssertEqual(personal.heartedScheduleItems, [101])
    }

    func testAddRemoveMetricsOnlyOnRealChanges() {
        var personal = EventPersonalState()
        _ = personal.migrateSchedule(plan: nil)
        XCTAssertEqual(personal.setHeart(true, for: .scheduleItem(101)), .scheduleItemHeart)
        XCTAssertNil(personal.setHeart(true, for: .scheduleItem(101)))
        XCTAssertEqual(personal.setHeart(true, for: .location(6)), .locationHeart)
        XCTAssertEqual(personal.heartedLocations, [6])
        // A time for a place already there: no metric.
        let change = personal.updateSchedule { $0.add(.location(6), at: PlannerFixture.sat("19:00")) }
        XCTAssertNotNil(change)
        XCTAssertNil(change?.metric)
        XCTAssertNil(personal.updateSchedule { $0.setReminder(.scheduleItem(101), minutes: 30) }?.metric)
        XCTAssertEqual(personal.setHeart(false, for: .scheduleItem(101)), .scheduleItemUnheart)
        XCTAssertNil(personal.setHeart(false, for: .scheduleItem(101)))
        XCTAssertEqual(personal.heartedScheduleItems, [])
        XCTAssertNil(personal.setHeart(true, for: .notification(31)))
    }

    func testTimesRemindersAndRows() {
        var s = MySchedule()
        s.add(.scheduleItem(101))
        s.add(.scheduleItem(109))
        s.add(.location(6), at: PlannerFixture.sat("18:00"))
        s.add(.location(5))
        XCTAssertEqual(s.savedPlaceIds, [5])
        XCTAssertEqual(s.rows(bundle, now: now).map(\.name), ["Juniper Lane", "Taco Row", "The Prairie Lights"])
        // A place entry lasts 45 min by default.
        XCTAssertEqual(s.rows(bundle, now: now)[1].end, PlannerFixture.sat("18:45"))
        // Move, reminder (nearest choice), off.
        s.move(.location(6), to: PlannerFixture.sat("20:00"))
        XCTAssertEqual(s.entry(.place, 6)?.at, PlannerFixture.sat("20:00"))
        XCTAssertNil(s.move(.scheduleItem(101), to: PlannerFixture.sat("20:00")))
        s.setReminder(.scheduleItem(101), minutes: 25)
        XCTAssertEqual(s.entry(.item, 101)?.reminderMinutes, 30)
        s.setReminder(.scheduleItem(101), minutes: 0)
        XCTAssertEqual(s.entry(.item, 101)?.reminderMinutes, 0)
        XCTAssertEqual(s.entry(.item, 109)?.reminderMinutes, 15)
        // The Schedule tab's section: upcoming first, ended at the end.
        let later = PlannerFixture.sat("12:30")
        XCTAssertEqual(s.sectionRows(bundle, now: later).map(\.name), ["The Prairie Lights", "Taco Row", "Juniper Lane"])
        XCTAssertEqual(s.sectionRows(bundle, now: later).last?.ended, true)
        // Home: up next.
        XCTAssertEqual(s.upNext(bundle, now: later, limit: 5).map(\.name), ["The Prairie Lights", "Taco Row"])
        // Codec round trip, lenient.
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(MySchedule.self, from: data), s)
        let lenient = try! JSONDecoder().decode(MySchedule.self, from: Data(#"{"entries":[{"kind":"item","id":5,"reminder":7},{"kind":"x"},{"kind":"place","id":6,"extra":1}],"more":2}"#.utf8))
        XCTAssertEqual(lenient.entries.map(\.id), [5, 6])
        XCTAssertNil(lenient.entries[0].reminder)
    }

    func testClashesAndSuggestedTimes() {
        var s = MySchedule()
        s.add(.scheduleItem(113))  // Sundown Choir 18:15–18:45
        let beer = s.span(of: .scheduleItem(112), bundle)!  // 18:00–19:00
        XCTAssertEqual(s.clashes(start: beer.start, end: beer.end, bundle, now: now).map(\.entry.id), [113])
        XCTAssertTrue(s.clashes(start: PlannerFixture.sat("19:00"), end: PlannerFixture.sat("20:00"), bundle, now: now).isEmpty)
        // "When?" from now + walk + 5 min, on the quarter hour, every 30 min; the first free one suggested.
        let options = s.suggestedTimes(for: 6, bundle, now: PlannerFixture.sat("17:52"), walkMinutes: 3)
        XCTAssertEqual(options.times.first, PlannerFixture.sat("18:00"))
        XCTAssertEqual(options.suggested, PlannerFixture.sat("19:00"))
        // Clock times: today, or tomorrow when more than 30 min past; near an entry's day when moving.
        XCTAssertEqual(MySchedule.date(PlanClock(hour: 20, minute: 0), near: nil, now: now, timeZone: zone), PlannerFixture.sat("20:00"))
        XCTAssertEqual(MySchedule.date(PlanClock(hour: 8, minute: 0), near: nil, now: now, timeZone: zone), PlannerFixture.sun("08:00"))
        XCTAssertEqual(MySchedule.date(PlanClock(hour: 13, minute: 0), near: PlannerFixture.sun("12:00"), now: now, timeZone: zone), PlannerFixture.sun("13:00"))
    }

    // MARK: One list (Attnd-Web docs/specs/one_list_spec.md)

    func testProposeAddsWithReasonsAndMyScheduleItemsAreMustIncludes() {
        var s = MySchedule()
        s.add(.scheduleItem(101))
        s.add(.scheduleItem(201))  // Sunday: not on the plan's day, stays
        let (plan, proposal) = Planner.propose(s, preferences: SchedulePreferences(), request: AssistantFixture.musicAndBbq,
                                               text: "Plan my Saturday around live music and BBQ", bundle: bundle, now: now)
        // Same plan as the planner alone with My schedule's items hearted (rule 7): fixture numbers unchanged.
        let alone = Planner(bundle: bundle, preferences: AssistantFixture.musicAndBbq, heartedItems: s.itemIds)
            .plan(from: now, request: "Plan my Saturday around live music and BBQ", createdAt: plan.createdAt)
        XCTAssertEqual(plan.itemIds, alone.itemIds)
        XCTAssertTrue(plan.itemIds.contains(101))
        // Adds: the plan's items not in My schedule, each with the planner's reason; meal places at the break.
        let added = proposal.adds.compactMap { if case .scheduleItem(let id) = $0.target { return id } else { return nil } }
        XCTAssertEqual(added, plan.itemIds.filter { $0 != 101 })
        for add in proposal.adds where add.meal == nil {
            if case .scheduleItem(let id) = add.target {
                XCTAssertEqual(add.reason, plan.items.first { $0.itemId == id }?.reason)
            }
        }
        let meals = plan.days.flatMap(\.meals).filter { $0.locationId != nil }
        XCTAssertEqual(proposal.adds.filter { $0.meal != nil }.count, meals.count)
        XCTAssertTrue(proposal.removes.isEmpty)
        XCTAssertTrue(proposal.pillText.hasPrefix("+\(added.count) items"))
        XCTAssertEqual(proposal.title, "Add \(proposal.adds.count) things to your schedule")
        // Applying: source planner + reasons; counted once per new item.
        var applied = s
        let changes = applied.apply(proposal)
        XCTAssertEqual(applied.itemIds, Set(plan.itemIds).union([201]))
        XCTAssertEqual(changes.filter { $0.metric == .scheduleItemHeart }.count, added.count)
        XCTAssertEqual(applied.entry(.item, 101)?.source, .you)
        XCTAssertEqual(applied.entry(.item, added[0])?.source, .planner)
        XCTAssertNotNil(applied.entry(.item, added[0])?.reason)
        // A new plan the same day removes only the planner's own entries it dropped.
        var edited = plan
        let dropped = added[0]
        edited.days[0].entries.removeAll { if case .item(let i) = $0 { return i.itemId == dropped || i.itemId == 101 } else { return false } }
        let next = applied.proposal(for: edited, bundle)
        XCTAssertEqual(next.removes.map(\.target), [.scheduleItem(dropped)])
        // …unless the request asked to remove it ("drop the …").
        XCTAssertTrue(applied.proposal(for: edited, explicit: [101], bundle).removes.map(\.target).contains(.scheduleItem(101)))
        XCTAssertTrue(applied.proposal(for: nil, bundle).isEmpty)
    }

    func testDerivedDayPlanFromMySchedule() {
        var s = MySchedule()
        XCTAssertNil(s.dayPlan(bundle, now: now))
        s.add(.scheduleItem(105))
        s.add(.scheduleItem(101))
        s.add(.scheduleItem(201))
        let plan = s.dayPlan(bundle, checkedOff: [101, 999], now: now)!
        XCTAssertEqual(plan.days.count, 2)
        XCTAssertEqual(Set(plan.itemIds), [101, 105, 201])
        XCTAssertEqual(plan.days[0].items.map(\.start), plan.days[0].items.map(\.start).sorted())
        XCTAssertEqual(plan.checkedOff, [101])
        XCTAssertEqual(plan.items.first?.reason, MySchedule.inScheduleReason)
        // The entry's own reason wins.
        var p = MySchedule()
        _ = p.apply(ScheduleProposal(adds: [.init(target: .scheduleItem(105), reason: "Because you like jazz")]))
        XCTAssertEqual(p.dayPlan(bundle, now: now)?.items.first?.reason, "Because you like jazz")
        // Derived, so it is the same every time (not stored, nothing to drift).
        XCTAssertEqual(s.dayPlan(bundle, now: now), s.dayPlan(bundle, now: now.addingTimeInterval(600)))
    }

    func testSourceAndReasonCodecIsLenient() throws {
        let json = #"{"entries":[{"kind":"item","id":1,"source":"planner","reason":"Lunch break"},{"kind":"item","id":2,"source":"robot"},{"kind":"place","id":3}]}"#
        let s = try JSONDecoder().decode(MySchedule.self, from: Data(json.utf8))
        XCTAssertEqual(s.entry(.item, 1)?.source, .planner)
        XCTAssertEqual(s.entry(.item, 1)?.reason, "Lunch break")
        XCTAssertEqual(s.entry(.item, 2)?.source, .you)
        XCTAssertNil(s.entry(.place, 3)?.reason)
        let back = try JSONDecoder().decode(MySchedule.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        // Reasons are cut at 80 characters.
        XCTAssertEqual(ScheduleEntry.cleanReason(String(repeating: "a", count: 200))?.count, 80)
        // Preferences: lenient, everything optional.
        let prefs = try JSONDecoder().decode(SchedulePreferences.self, from: Data(#"{"pace":"packed","max_walk_minutes":10,"meals":["lunch","brunch"],"earliest":"09:30","kid_friendly":"yes"}"#.utf8))
        XCTAssertEqual(prefs.pace, .packed)
        XCTAssertEqual(prefs.maxWalkMinutes, 10)
        XCTAssertEqual(prefs.meals, [.lunch])
        XCTAssertEqual(prefs.earliest, PlanClock(hour: 9, minute: 30))
        XCTAssertFalse(prefs.kidFriendly)
        XCTAssertEqual(try JSONDecoder().decode(SchedulePreferences.self, from: JSONEncoder().encode(prefs)), prefs)
    }

    func testLegacyPlanMigrationIsIdempotent() {
        let plan = AssistantFixture.plan
        var personal = EventPersonalState()
        personal.heartedScheduleItems = [101]
        XCTAssertTrue(personal.migrateSchedule(plan: nil))
        var legacy = plan
        legacy.checkedOff = [101]
        XCTAssertTrue(personal.absorbLegacy(plan: legacy))
        let s = personal.schedule
        XCTAssertEqual(s.itemIds, Set(plan.itemIds).union([101]))
        XCTAssertEqual(s.entry(.item, 101)?.source, .you)
        for item in plan.items where item.itemId != 101 {
            XCTAssertEqual(s.entry(.item, item.itemId)?.source, .planner)
            XCTAssertEqual(s.entry(.item, item.itemId)?.reason, item.reason)
        }
        for meal in plan.days.flatMap(\.meals) {
            guard let id = meal.locationId else { continue }
            XCTAssertEqual(s.entry(.place, id)?.at, meal.start)
            XCTAssertEqual(s.entry(.place, id)?.reason, meal.kind.label)
        }
        XCTAssertEqual(personal.preferences, SchedulePreferences(plan.preferences, constraints: plan.constraints))
        XCTAssertEqual(personal.preferences.meals, [.lunch, .dinner])
        XCTAssertEqual(personal.checkedOff, [101])
        // A second run finds nothing and changes nothing.
        let once = personal
        XCTAssertFalse(personal.absorbLegacy(plan: legacy))
        XCTAssertEqual(personal, once)
    }

    func testUndoHistoryKeepsTwentySnapshots() {
        var history = ScheduleHistory()
        XCTAssertNil(history.pop())
        for id in 1...25 { history = history.push(MySchedule(entries: [ScheduleEntry(kind: .item, id: id)])) }
        XCTAssertEqual(history.snapshots.count, ScheduleHistory.max)
        XCTAssertEqual(history.pop()?.schedule.itemIds, [25])
        XCTAssertEqual(ScheduleHistory.decode(history.encode()), history)
        XCTAssertFalse(ScheduleHistory.decode("nonsense").canUndo)
    }

    func testRemindersPerEntry() {
        var s = MySchedule()
        s.add(.scheduleItem(105))  // 17:00
        s.setReminder(.scheduleItem(105), minutes: 30)
        s.add(.location(6), at: PlannerFixture.sat("19:00"))
        let reminders = ReminderPlanner.reminders(
            eventId: 42, schedule: bundle.schedule, hearted: s.itemIds, locations: bundle.locations, user: nil,
            now: now, timeZone: zone, locale: AssistantFixture.enUS,
            leadMinutes: [105: 30], places: s.entries.filter { $0.kind == .place }
        )
        XCTAssertEqual(reminders.map(\.fireDate), [PlannerFixture.sat("16:30"), PlannerFixture.sat("18:45")])
        XCTAssertEqual(reminders[0].title, "Velvet Mesquite in 30 min")
        XCTAssertEqual(reminders[1].title, "Taco Row in 15 min")
        XCTAssertEqual(reminders[1].locationId, 6)
        XCTAssertEqual(reminders[1].id, "attnd.reminder.42.p6")
        // Off: none.
        let off = ReminderPlanner.reminders(eventId: 42, schedule: bundle.schedule, hearted: [105], locations: bundle.locations,
                                            user: nil, now: now, timeZone: zone, leadMinutes: [105: 0])
        XCTAssertTrue(off.isEmpty)
    }

    func testOrganizerChanges() {
        var s = MySchedule()
        s.add(.scheduleItem(105))
        XCTAssertTrue(s.fillFingerprints(bundle))
        XCTAssertTrue(s.organizerChanges(bundle).isEmpty)
        var moved = bundle
        if let index = moved.schedule.firstIndex(where: { $0.id == 105 }) {
            moved.schedule[index].startTime = PlannerFixture.sat("20:30")
            moved.schedule[index].endTime = PlannerFixture.sat("21:30")
        }
        XCTAssertEqual(s.organizerChanges(moved).first?.kind, .moved(PlannerFixture.sat("20:30")))
        var gone = bundle
        gone.schedule.removeAll { $0.id == 105 }
        XCTAssertEqual(s.organizerChanges(gone).first?.kind, .cancelled)
        s.keepChange(105, moved)
        XCTAssertTrue(s.organizerChanges(moved).isEmpty)
    }

    func testMapPlaces_IncludeTheItemsPlaces() {
        let schedule = [
            ScheduleItem(id: 1, name: "Set", locationId: 10),
            ScheduleItem(id: 2, name: "Talk", locationId: 20),
            ScheduleItem(id: 3, name: "General"),
        ]
        XCTAssertEqual(MySchedule.placeIds(heartedLocations: [30], heartedItems: [1, 3], schedule: schedule), [10, 30])
        XCTAssertEqual(MySchedule.placeIds(heartedLocations: [], heartedItems: [], schedule: schedule), [])
    }
}
