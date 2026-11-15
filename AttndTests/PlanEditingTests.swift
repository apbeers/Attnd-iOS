// PlanEditingTests.swift
// AttndTests
//
// Assistant spec §4 (Android's `unit/PlanEditingTest.kt`, same cases and plans): plan edits on the
// fixture plan (planner rules 13–20). The fixture plan is
// 10:00 111 · 11:00 109 · 12:00 lunch · 13:00 102 · 15:00 103 · 17:00 105 · 18:15 113 · 19:00 101 · 21:00 104.

import XCTest
@testable import Attnd

final class PlanEditingTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let now = PlannerFixture.now
    private let plan = AssistantFixture.plan
    private let likes = AssistantFixture.likes
    private let saturday = PlanDate(year: 2026, month: 11, day: 14)
    private func clock(_ plan: Plan) -> [String] { AssistantFixture.clock(plan) }
    private func date(_ iso: String) -> Date { PlannerFixture.date(iso) }

    private func edit(_ ops: PlanOp..., at: Date? = nil, base: Plan? = nil, bundle b: EventBundle? = nil) -> PlanEdit {
        PlanEditor.preview(base ?? plan, ops, b ?? bundle, likes, now: at ?? now)
    }

    private func planner(_ constraints: PlanConstraints = .none, bundle b: EventBundle? = nil) -> Planner {
        Planner(bundle: b ?? bundle, preferences: AssistantFixture.musicAndBbq, heartedItems: likes.scheduleItems, constraints: constraints)
    }

    func testReSolveWithoutConstraintsIsTheSamePlan() {
        XCTAssertEqual(planner().replan(plan, from: now), plan)
        XCTAssertEqual(planner(.none).plan(from: now, request: plan.request), plan)
    }

    func testRemoveAddReplaceKeep() {
        let remove = edit(.remove(item: 109))
        XCTAssertEqual(clock(remove.after), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertEqual(remove.diff, PlanDiff(removed: [109], added: [106], mealsRemoved: [MealSlot(date: saturday, kind: .lunch)]))
        XCTAssertTrue(remove.after.constraints.excluded.contains(109))

        // A pinned item is a must-include ahead of the rest (rule 16): Kolache in, Velvet Mesquite out.
        let add = edit(.add(item: 110))
        XCTAssertEqual(clock(add.after), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "16:15 110", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertEqual(add.diff, PlanDiff(removed: [105], added: [110]))
        XCTAssertEqual(add.after.items.first { $0.itemId == 110 }?.reason, "You added this")

        let with = edit(.replace(item: 103, with: 107))
        XCTAssertEqual(clock(with.after), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "14:15 107", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])

        // "something like Neon Armadillo" in the 3 PM slot.
        let like = edit(.replace(item: 103, like: 114))
        XCTAssertEqual(clock(like.after), clock(with.after))
        XCTAssertEqual(like.notes, [])

        let tag = edit(.replace(item: 105, tag: "food"))
        XCTAssertEqual(clock(tag.after), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "16:15 110", "18:15 113", "19:00 101", "21:00 104"])

        let keep = edit(.keep(item: 106))
        XCTAssertEqual(clock(keep.after), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])

        // Not planned → no change and a note.
        let missing = edit(.replace(item: 106, with: 107))
        XCTAssertEqual(clock(missing.after), clock(plan))
        XCTAssertEqual(missing.notes, ["Brisket 101 isn't in your plan"])
    }

    func testConstraints() {
        let ate = edit(.noFoodUntil(date("2026-11-14T19:00:00Z")))
        XCTAssertEqual(clock(ate.after), ["10:00 111", "11:00 109", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertEqual(ate.after.constraints.mealsDone, [MealSlot(date: saturday, kind: .lunch)])

        XCTAssertEqual(clock(edit(.doneBy(PlanClock(hour: 21, minute: 0))).after),
                       ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"])
        XCTAssertEqual(clock(edit(.startAt(PlanClock(hour: 14, minute: 0))).after), ["15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])
        XCTAssertEqual(clock(edit(.maxWalk(3)).after), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "16:15 110", "18:00 dinner", "19:00 101"])
        XCTAssertEqual(clock(edit(.pace(.relaxed)).after),
                       ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"])
        let more = edit(.moreTag("bbq"))
        XCTAssertEqual(clock(more.after), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"])
        // bbq: 0.5 + 2·0.0551 + 1 (liked tag) + 1 (more) = 2.610.
        XCTAssertEqual(planner(more.after.constraints).score(bundle.scheduleItem(106)!), 2610)
        XCTAssertFalse(edit(.lessTag("dj")).after.itemIds.contains(104))
        // More then less of the same tag: only "less" remains.
        XCTAssertEqual(edit(.moreTag("bbq"), .lessTag("bbq")).after.constraints.lessTags, ["bbq"])
        XCTAssertEqual(edit(.moreTag("bbq"), .lessTag("bbq")).after.constraints.moreTags, [])
    }

    func testOriginRestartsTheDayFromThere() {
        // 10:58 at Panther Island Pavilion: Juniper Lane (11:00, 4 min away) can't be reached any more.
        let at = now.addingTimeInterval(58 * 60)
        let origin = edit(.fromLocation(3), at: at)
        XCTAssertEqual(origin.after.constraints.origin, PlanOrigin(locationId: 3, at: at))
        XCTAssertEqual(clock(origin.after), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "16:15 110", "18:15 113", "19:00 101", "21:00 104"])
        // Gates open has started (frozen, kept verbatim); Brisket 101 shows the walk from the pavilion.
        XCTAssertEqual(origin.after.items.map(\.itemId), [111, 106, 102, 103, 110, 113, 101, 104])
        XCTAssertEqual(origin.after.items.map(\.walkMinutes), [nil, 3, 2, 0, 2, 2, 4, 4])
        // At the plan's own time and place nothing changes.
        XCTAssertEqual(clock(edit(.fromLocation(6)).after), clock(plan))
    }

    func testStartedItemsAreFrozen() {
        // 3:30 PM: everything before stays; Big Sky Radio (in progress) is removed on request.
        let e = edit(.remove(item: 103), at: now.addingTimeInterval(330 * 60))
        XCTAssertEqual(clock(e.after), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "17:00 105", "18:15 113", "19:00 101"])
        XCTAssertEqual(e.after.days.count, 1)
        XCTAssertEqual(e.after.days.first.map { ISODate.string(from: $0.windowStart) }, "2026-11-14T21:30:00Z")
        XCTAssertEqual(Array(e.after.items.prefix(3)), Array(plan.items.prefix(3)))
        // Checked-off items stay too.
        var checked = plan
        checked.checkedOff = [105]
        XCTAssertTrue(edit(.doneBy(PlanClock(hour: 17, minute: 30)), base: checked).after.itemIds.contains(105))
    }

    func testMoveToAnotherShowing() {
        let encore = ScheduleItem(id: 115, name: "Juniper Lane", description: "", startTime: PlannerFixture.sun("15:30"), endTime: PlannerFixture.sun("16:30"),
                                  locationId: 1, locationName: "Main Stage", tags: ["live music", "folk"])
        var repeatBundle = bundle
        repeatBundle.schedule.append(encore)
        let base = planner(bundle: repeatBundle).plan(from: now, request: "")
        XCTAssertEqual(clock(base), clock(plan))
        let moved = edit(.move(item: 109, later: true), base: base, bundle: repeatBundle)
        XCTAssertEqual(moved.diff.moved, [PlanDiff.Move(from: 109, to: 115)])
        XCTAssertTrue(moved.after.itemIds.contains(115))
        XCTAssertEqual(moved.after.days.map(\.date), [saturday, PlanDate(year: 2026, month: 11, day: 15)])
        XCTAssertEqual(edit(.move(item: 101, later: true)).notes, ["The Prairie Lights has no later time"])
    }

    func testVersions() {
        let chill = PlanVersions.make(.chill, plan, bundle, likes, now: now)
        XCTAssertEqual(clock(chill.after), ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"])
        XCTAssertEqual(chill.after.constraints.pace, .relaxed)
        XCTAssertEqual(chill.after.constraints.maxWalkMinutes, 10)
        XCTAssertEqual(clock(PlanVersions.make(.everything, plan, bundle, likes, now: now).after), clock(plan))
    }

    func testUndoStack() {
        var history = PlanHistory()
        for i in 0..<25 {
            var version = plan
            version.request = "v\(i)"
            history = history.push(version)
        }
        XCTAssertEqual(history.plans.count, PlanHistory.max)
        let popped = history.pop()
        XCTAssertEqual(popped?.plan.request, "v24")
        XCTAssertEqual(popped?.rest.plans.count, 19)
        XCTAssertEqual(PlanHistory.decode(history.encode()), history)
        XCTAssertNil(PlanHistory().pop())
        XCTAssertFalse(PlanHistory.decode("nonsense").canUndo)
    }

    func testConstraintsAndCheckOffsAreStored() {
        var edited = edit(.noFoodUntil(date("2026-11-14T19:00:00Z")), .add(item: 110), .fromLocation(6), .moreTag("bbq"),
                          .doneBy(PlanClock(hour: 23, minute: 0))).after
        edited.checkedOff = [111]
        XCTAssertEqual(PlanCodec.decode(PlanCodec.encode(edited)), edited)
        var group = plan
        group.constraints = PlanConstraints(pinned: [110], excluded: [109], startAt: PlanClock(hour: 9, minute: 30), maxWalkMinutes: 7,
                                            pace: .packed, lessTags: ["dj"], groupLikes: [114: 3])
        XCTAssertEqual(PlanCodec.decode(PlanCodec.encode(group)), group)
    }

    func testOpsJSON() {
        let ops: [PlanOp] = [
            .replace(item: 103, like: 114), .remove(item: 109), .move(item: 109, later: false), .noFoodUntil(date("2026-11-14T19:00:00Z")),
            .doneBy(PlanClock(hour: 21, minute: 0)), .maxWalk(10), .pace(.relaxed), .fromLocation(6), .lessTag("dj"),
        ]
        let json = PlanOpJSON.encode(ops, timeZone: PlannerFixture.chicago)
        XCTAssertEqual(
            json.encoded,
            #"[{"op":"replace","item":"s103","like":"s114"},{"op":"remove","item":"s109"},{"op":"move","item":"s109","direction":"earlier"},{"op":"constraint","no_food_until":"2026-11-14T19:00:00Z"},{"op":"constraint","done_by":"21:00"},{"op":"constraint","max_walk_min":10},{"op":"constraint","pace":"relaxed"},{"op":"constraint","from_location":"l6"},{"op":"constraint","less_tag":"dj"}]"#
        )
        XCTAssertEqual(PlanOpJSON.parse(json, timeZone: PlannerFixture.chicago, now: now), ops)
        // Clock times are today in the event's zone; numbers and "S12" ids are accepted.
        let lenient = JSONValue.parse(#"[{"op":"constraint","no_food_until":"13:00"},{"op":"add","item":110},{"op":"keep","item":"S106"}]"#)
        XCTAssertEqual(PlanOpJSON.parse(lenient, timeZone: PlannerFixture.chicago, now: now),
                       [.noFoodUntil(date("2026-11-14T19:00:00Z")), .add(item: 110), .keep(item: 106)])
        XCTAssertNil(PlanOpJSON.parse(JSONValue.parse(#"[{"op":"teleport","item":1}]"#), timeZone: PlannerFixture.chicago, now: now))
        XCTAssertNil(PlanOpJSON.parse(JSONValue.parse(#"[{"op":"remove","item":"l3"}]"#), timeZone: PlannerFixture.chicago, now: now))
    }
}
