// PlanDockTests.swift
// AttndTests
//
// The plan rules kept from the plan page's dock (PlanDock.swift; iOS only for now) on `AssistantFixture`: now Sat
// 10:00 AM, plan 10:00 111 · 11:00 109 · 12:00 lunch · 13:00 102 · 15:00 103 · 17:00 105 ·
// 18:15 113 · 19:00 101 · 21:00 104; likes 101, 114.

import XCTest
@testable import Attnd

final class PlanDockTests: XCTestCase {

    private let ctx = AssistantFixture.ctx()

    func testAddWithoutAClash() throws {
        // Street tacos at home (14:15–15:00) fits between 102 and 103.
        guard case .proposal(let p) = PlanDock.addToPlan(107, ctx) else { return XCTFail("expected a proposal") }
        XCTAssertEqual(p.kind, .add)
        XCTAssertNil(p.replaced)
        XCTAssertEqual(p.options.count, 1)
        XCTAssertEqual(p.options[0].edit.diff.added, [107])
        let preview = PlanPreview.of(p, plan: AssistantFixture.plan, PlannerFixture.bundle)
        let day = PlanDate(PlannerFixture.now, in: PlanCalendar.calendar(PlannerFixture.chicago))
        XCTAssertEqual(preview.suggestions[day]?.map(\.itemId), [107])
        XCTAssertEqual(preview.suggestions[day]?.first?.after, 102)
    }

    func testAddThatClashesReplaces() {
        // Beer tasting (18:00–19:00) overlaps Sundown Choir (113, 18:15–18:45).
        guard case .proposal(let p) = PlanDock.addToPlan(112, ctx) else { return XCTFail("expected a proposal") }
        XCTAssertEqual(p.kind, .replace)
        XCTAssertEqual(p.replaced, 113)
        XCTAssertEqual(p.text, "Add Beer tasting instead of Sundown Choir?")
        XCTAssertEqual(p.options.map(\.label), ["Instead of Sundown Choir"])
        XCTAssertTrue(p.options[0].edit.diff.added.contains(112))
        XCTAssertTrue(p.options[0].edit.diff.removed.contains(113))
    }

    func testAddMessages() {
        XCTAssertEqual(PlanDock.addToPlan(109, ctx), .message("Juniper Lane is already in your plan."))
        XCTAssertEqual(PlanDock.addToPlan(111, ctx), .message("Gates open has already started."))
        XCTAssertEqual(PlanDock.addToPlan(999, ctx), .message("That item isn't on the schedule any more."))
    }

    func testAddWithoutAPlanProposesOne() {
        guard case .proposal(let p) = PlanDock.addToPlan(107, AssistantFixture.ctx(plan: nil)) else { return XCTFail("expected a proposal") }
        XCTAssertEqual(p.kind, .change)
        XCTAssertEqual(p.options.count, 1)
        XCTAssertEqual(p.options[0].label, "Use This Plan")
        guard case .newPlan(let plan) = p.options[0].apply else { return XCTFail("expected a new plan") }
        XCTAssertTrue(plan.itemIds.contains(107))
        XCTAssertEqual(plan.request, "Plan around Street tacos at home")
        XCTAssertTrue(p.text.hasPrefix("A plan around Street tacos at home: "))
        XCTAssertEqual(p.options[0].edit.diff.added.sorted(), plan.itemIds.sorted())
    }

    func testPlanAroundAPlace() {
        // Chef Demo Kitchen: 106 (12:00), 107 (14:15), 110 (16:15); none planned.
        guard case .proposal(let p) = PlanDock.planAround(4, ctx) else { return XCTFail("expected a proposal") }
        XCTAssertEqual(p.kind, .add)
        XCTAssertEqual(p.text, "Add from Chef Demo Kitchen:")
        XCTAssertEqual(p.options.map(\.label), ["Brisket 101", "Street tacos at home", "Kolache masterclass"])
        XCTAssertEqual(PlanDock.planAround(9, ctx), .message("Nothing else is on at Info Booth."))
    }

    func testPlanAroundAPlaceWithoutAPlan() {
        guard case .proposal(let p) = PlanDock.planAround(4, AssistantFixture.ctx(plan: nil)) else { return XCTFail("expected a proposal") }
        guard case .newPlan(let plan) = p.options[0].apply else { return XCTFail("expected a new plan") }
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(plan.itemIds.contains { PlannerFixture.bundle.scheduleItem($0)?.locationId == 4 })
        XCTAssertTrue(p.text.hasPrefix("A plan around Chef Demo Kitchen: "))
    }

    // MARK: Summary line

    func testSummaryLine() {
        let bundle = PlannerFixture.bundle
        XCTAssertEqual(PlanDock.summaryLine(plan: nil, bundle, now: PlannerFixture.now, locale: AssistantFixture.enUS),
                       "No plan yet · type to plan or search")
        // 10:00: Gates open (no place) is on.
        XCTAssertEqual(PlanDock.summaryLine(plan: AssistantFixture.plan, bundle, now: PlannerFixture.now, locale: AssistantFixture.enUS),
                       "Now: Gates open")
        XCTAssertEqual(PlanDock.summaryLine(plan: AssistantFixture.plan, bundle, now: PlannerFixture.sat("10:40"), locale: AssistantFixture.enUS),
                       "Next: Juniper Lane · 11:00 AM · Main Stage")
        XCTAssertEqual(PlanDock.summaryLine(plan: AssistantFixture.plan, bundle, now: PlannerFixture.sat("11:30"), locale: AssistantFixture.enUS),
                       "Now: Juniper Lane · Main Stage")
        XCTAssertTrue(PlanDock.summaryLine(plan: AssistantFixture.plan, bundle, now: PlannerFixture.sun("08:00"), locale: AssistantFixture.enUS)
            .hasPrefix("Your plan is done · "))
    }
}
