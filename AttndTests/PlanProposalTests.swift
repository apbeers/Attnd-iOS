// PlanProposalTests.swift
// AttndTests
//
// In-place plan edits (plan tab spec; Android's `unit/PlanProposalTest.kt`, same cases) on the
// assistant fixture plan:
// 10:00 111 · 11:00 109 · 12:00 lunch · 13:00 102 · 15:00 103 · 17:00 105 · 18:15 113 · 19:00 101 · 21:00 104.

import XCTest
@testable import Attnd

final class PlanProposalTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let plan = AssistantFixture.plan
    private let saturday = PlanDate(year: 2026, month: 11, day: 14)
    private var ctx: RouterContext { AssistantFixture.ctx() }

    private func proposal(_ ops: PlanOp...) -> PlanProposal {
        PlanProposals.from(action: .planEdit(ops, bundle), ctx)!
    }

    private func preview(_ p: PlanProposal) -> PlanPreview { PlanPreview.of(p, plan: plan, bundle) }

    func testRemoveIsAChangeWithMarksAndPill() {
        let p = proposal(.remove(item: 109))
        XCTAssertEqual(p.kind, .change)
        XCTAssertFalse(p.hasOptionRows)
        XCTAssertEqual(p.options.count, 1)
        let v = preview(p)
        XCTAssertEqual(v.marks, [109: .removed])
        XCTAssertEqual(v.mealMarks, [MealSlot(date: saturday, kind: .lunch): .removed])
        XCTAssertEqual(v.suggestions[saturday]?.map(\.itemId), [106])
        XCTAssertEqual(v.suggestions[saturday]?.first?.after, 109)
        XCTAssertEqual(v.pill, "\u{2212}1 item, +1 item, \u{2212}1 lunch break")
    }

    /// One list §3: a proposal previews without touching My schedule; Apply turns the option's
    /// result into one set of My schedule edits (what the request removed leaves even when the
    /// person added it; what the re-solve dropped leaves only when the planner had added it).
    func testProposalAppliesAsMyScheduleEdits() {
        // My schedule = the fixture plan: 109 added by the person, the rest by the planner.
        var schedule = MySchedule()
        _ = schedule.apply(schedule.proposal(for: plan, bundle))
        schedule.entries = schedule.entries.map { var e = $0; if e.id == 109 { e.source = .you }; return e }
        let untouched = schedule
        let p = proposal(.remove(item: 109))
        _ = preview(p)
        XCTAssertEqual(schedule, untouched)
        let after = p.options[0].edit.after
        let edits = schedule.proposal(for: after, explicit: after.constraints.excluded, bundle)
        XCTAssertTrue(edits.removes.map(\.target).contains(.scheduleItem(109)))
        XCTAssertTrue(edits.adds.map(\.target).contains(.scheduleItem(106)))
        var history = ScheduleHistory()
        history = history.push(schedule)
        _ = schedule.apply(edits)
        XCTAssertFalse(schedule.itemIds.contains(109))
        XCTAssertTrue(schedule.itemIds.contains(106))
        XCTAssertEqual(history.pop()?.schedule, untouched)
        // The derived day view of the result matches the edit's items.
        XCTAssertEqual(Set(schedule.dayPlan(bundle, now: PlannerFixture.now)?.itemIds ?? []), Set(after.itemIds))
    }

    func testAddSuggestsAtItsPosition() {
        let p = proposal(.add(item: 110))
        XCTAssertEqual(p.kind, .add)
        XCTAssertNil(p.replaced)
        let v = preview(p)
        XCTAssertEqual(v.suggestions[saturday], [ProposalSuggestion(itemId: 110, option: 0, after: 103, start: PlannerFixture.date("2026-11-14T16:15:00-06:00"))])
        XCTAssertEqual(v.marks, [105: .removed])
        XCTAssertEqual(v.pill, "\u{2212}1 item, +1 item")
    }

    func testReplaceCrossesOutAndSuggestsUnderIt() {
        let p = proposal(.replace(item: 103, with: 107))
        XCTAssertEqual(p.kind, .replace)
        XCTAssertEqual(p.replaced, 103)
        let v = preview(p)
        XCTAssertEqual(v.marks[103], .removed)
        XCTAssertEqual(v.suggestions[saturday]?.map(\.itemId), [107])
        XCTAssertEqual(v.suggestions[saturday]?.first?.after, 103)
    }

    func testChipOptions() {
        let chips = [107, 110].map { (id: Int) in AssistantChip(label: "s\(id)", action: .planEdit([.replace(item: 103, with: id)], bundle)) }
        let p = PlanProposals.from(chips: chips, text: "Which one?", ctx)!
        XCTAssertEqual(p.kind, .replace)
        XCTAssertEqual(p.replaced, 103)
        XCTAssertEqual(p.options.map(\.label), ["s107", "s110"])
        let v = preview(p)
        XCTAssertEqual(v.pill, "Pick one of 2")
        XCTAssertEqual(v.marks[103], .removed)
        let rows = v.suggestions[saturday] ?? []
        XCTAssertTrue(rows.allSatisfy { $0.after == 103 })
        XCTAssertTrue(rows.contains { $0.itemId == 107 && $0.option == 0 })
        XCTAssertTrue(rows.contains { $0.itemId == 110 && $0.option == 1 })
        XCTAssertLessThanOrEqual(rows.count, PlanProposal.maxOptions)
    }

    func testRouterEditsBecomeProposalsNotWrites() {
        let ctx = self.ctx
        // iOS: "remove X" is a My schedule command now; "more bbq" is still a plan edit (it drops Juniper Lane).
        let routed = AssistantRouter.route("more bbq", ctx)
        let p = PlanProposals.from(routed: routed, ctx)
        XCTAssertEqual(p?.options.first?.edit.diff.removed, [109])
        XCTAssertEqual(p?.kind, .change)
        XCTAssertNil(PlanProposals.from(routed: AssistantRouter.route("tacos", ctx), ctx))
        let version = PlanProposals.from(routed: AssistantRouter.route("chill version", ctx), ctx)
        XCTAssertEqual(version?.kind, .change)
        XCTAssertEqual(version?.options.first?.label, "Chill")
    }

    func testNoPlanNoProposal() {
        XCTAssertNil(PlanProposals.from(action: .planEdit([.add(item: 110)], bundle), AssistantFixture.ctx(plan: nil)))
    }

    func testSwapTheNextThing() {
        guard case .proposal(let p)? = PlanProposals.swap("swap the next thing", ctx) else { return XCTFail("no proposal") }
        XCTAssertEqual(p.kind, .replace)
        XCTAssertEqual(p.replaced, 109)
        XCTAssertFalse(p.options.isEmpty)
        XCTAssertLessThanOrEqual(p.options.count, 4)
        XCTAssertNil(PlanProposals.swap("swap Juniper Lane for Kolache masterclass", ctx), "with / for is the router's")
        XCTAssertEqual(PlanProposals.swap("swap the next thing", AssistantFixture.ctx(plan: nil)), .message(AssistantRouter.noPlanText))
    }

    func testReplies() {
        XCTAssertEqual(ProposalReply.parse("do it", options: 1), .apply(0))
        XCTAssertEqual(ProposalReply.parse("Yes!", options: 3), .apply(0))
        XCTAssertEqual(ProposalReply.parse("the second one", options: 3), .apply(1))
        XCTAssertEqual(ProposalReply.parse("option 3", options: 3), .apply(2))
        XCTAssertEqual(ProposalReply.parse("#2", options: 2), .apply(1))
        XCTAssertEqual(ProposalReply.parse("2", options: 2), .apply(1))
        XCTAssertEqual(ProposalReply.parse("go with the first", options: 2), .apply(0))
        XCTAssertEqual(ProposalReply.parse("the last one", options: 4), .apply(3))
        XCTAssertEqual(ProposalReply.parse("option 3", options: 2), .none)
        XCTAssertEqual(ProposalReply.parse("no", options: 2), .cancel)
        XCTAssertEqual(ProposalReply.parse("Never mind", options: 2), .cancel)
        XCTAssertEqual(ProposalReply.parse("add tacos", options: 2), .none)
        XCTAssertEqual(ProposalReply.parse("", options: 2), .none)
    }

    func testDiffText() {
        XCTAssertEqual(PlanPreview.diffText(PlanDiff()), "No change")
        let diff = PlanDiff(removed: [1, 2], added: [3], moved: [PlanDiff.Move(from: 4, to: 5)],
                            mealsAdded: [MealSlot(date: saturday, kind: .lunch)], mealsMoved: [MealSlot(date: saturday, kind: .dinner)])
        XCTAssertEqual(PlanPreview.diffText(diff), "\u{2212}2 items, +1 item, 1 moved, +1 lunch break, dinner break moved")
    }

    func testSharedPlan() {
        let p = PlanProposals.shared(use: plan, merged: nil, current: nil, eventId: bundle.event.id, bundle)
        XCTAssertEqual(p.kind, .change)
        XCTAssertEqual(p.options.map(\.label), ["Use This Plan"])
        XCTAssertEqual(p.options[0].edit.diff.added, plan.itemIds)
        let v = PlanPreview.of(p, plan: nil, bundle)
        XCTAssertEqual(v.suggestions.values.map(\.count).reduce(0, +), plan.itemIds.count)
        XCTAssertNil(v.suggestions[saturday]?.first?.after)
    }
}
