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

    func testPlannerFillsMyScheduleWithPinnedEntries() {
        var s = MySchedule()
        s.add(.scheduleItem(101))
        s.add(.scheduleItem(201))  // Sunday: not on the plan's day, stays
        let planner = Planner(bundle: bundle, preferences: AssistantFixture.musicAndBbq, heartedItems: s.itemIds)
        let plan = planner.plan(from: now, request: "Plan my Saturday around live music and BBQ")
        // My schedule's items are the planner's must-includes.
        XCTAssertTrue(plan.itemIds.contains(101))
        let changes = s.apply(plan: plan, replacing: nil)
        XCTAssertEqual(s.itemIds, Set(plan.itemIds).union([201]))
        // Counted once per item that was new.
        XCTAssertEqual(changes.filter { $0.metric == .scheduleItemHeart }.count, plan.itemIds.filter { $0 != 101 }.count)
        // A changed plan drops what it removed (on its days); clearing the plan keeps My schedule.
        var edited = plan
        edited.days[0].entries.removeAll { if case .item(let i) = $0 { return i.itemId == 109 } else { return false } }
        _ = s.apply(plan: edited, replacing: plan)
        XCTAssertFalse(s.itemIds.contains(109))
        XCTAssertTrue(s.apply(plan: nil, replacing: edited).isEmpty)
        XCTAssertTrue(s.itemIds.contains(101))
        // Reconcile: an item removed elsewhere leaves the plan; one added on its day joins it.
        s.remove(.scheduleItem(105))
        s.add(.scheduleItem(110))
        let reconciled = s.reconcile(edited, bundle)!
        XCTAssertFalse(reconciled.itemIds.contains(105))
        XCTAssertEqual(reconciled.items.first { $0.itemId == 110 }?.reason, MySchedule.inScheduleReason)
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
}
