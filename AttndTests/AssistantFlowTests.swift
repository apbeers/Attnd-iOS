// AssistantFlowTests.swift
// AttndTests
//
// The assistant screen's pure helpers (AssistantFlow.swift), the same cases as Android's
// `unit/AssistantFlowTest.kt`: turn paths, forced turns, reply texts, Ask about this, block data,
// shared plans, live hints and the stored transcript.

import XCTest
@testable import Attnd

final class AssistantFlowTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let now = PlannerFixture.now
    private let plan = AssistantFixture.plan
    private let likes = AssistantFixture.likes
    private let enUS = AssistantFixture.enUS
    private func ctx() -> RouterContext { AssistantFixture.ctx() }

    func testPathCommandsStayOnTheRouterQuestionsGoToTheModel() {
        func path(_ input: String, model: Bool, forced: TurnPath? = nil) -> TurnPath {
            AssistantFlow.path(AssistantRouter.route(input, ctx()).intent, input, modelAvailable: model, forced: forced)
        }
        XCTAssertEqual(path("tacos", model: true), .search)
        XCTAssertEqual(path("like prairie lights", model: true), .search)
        XCTAssertEqual(path("what's on tonight", model: true), .search)
        XCTAssertEqual(path("done by 9", model: true), .plan)
        XCTAssertEqual(path("why isn't neon armadillo in my plan", model: false), .plan)
        XCTAssertEqual(path("where can I get something vegetarian?", model: true), .ask)
        XCTAssertEqual(path("where can I get something vegetarian?", model: false), .search)
        XCTAssertEqual(path("xqzv blorp", model: true), .ask)
        XCTAssertEqual(path("done by 9", model: false, forced: .ask), .search)
        XCTAssertEqual(path("done by 9", model: true, forced: .search), .search)
        XCTAssertEqual(path("tacos", model: true, forced: .plan), .plan)
    }

    func testForcedSearchAndPlanTurns() {
        let search = AssistantFlow.searchTurn("tacos", ctx())
        XCTAssertTrue(search.blocks.contains { if case .placeCard(6, _) = $0 { return true } else { return false } })
        XCTAssertTrue(search.actions.isEmpty)
        let nothing = AssistantFlow.searchTurn("xqzv blorp", ctx())
        XCTAssertEqual(nothing.blocks.first, .text(AssistantRouter.noMatchText))

        let routed = AssistantRouter.route("live music", ctx())
        let planned = AssistantFlow.planTurn("live music", routed, ctx())
        XCTAssertEqual(planned.actions.map(\.name), [.planMake])
        var noPlanner = ctx()
        noPlanner.canPlan = false
        XCTAssertEqual(AssistantFlow.planTurn("live music", AssistantRouter.route("live music", noPlanner), noPlanner),
                       AssistantRouter.route("live music", noPlanner).turn)
        let edit = AssistantRouter.route("done by 9", ctx())
        XCTAssertEqual(edit.intent, .planEdit)
        XCTAssertEqual(AssistantFlow.planTurn("done by 9", edit, ctx()), edit.turn)
    }

    func testReplyTextTextElseNamesElseTypes() {
        XCTAssertEqual(AssistantFlow.replyText(AssistantTurn(blocks: [.text("Liked **The Prairie Lights**.")]), bundle), "Liked The Prairie Lights.")
        XCTAssertEqual(AssistantFlow.replyText(AssistantTurn(blocks: [.placeCard(id: 6), .itemCard(id: 107)]), bundle), "Showed Taco Row, Street tacos at home")
        XCTAssertEqual(AssistantFlow.replyText(AssistantTurn(blocks: [.share("plan")]), bundle), "Showed share")
    }

    func testAskAbout() {
        XCTAssertEqual(AssistantFlow.askAbout(EntityRef(kind: .schedule, id: 101), bundle), "Tell me about The Prairie Lights")
        XCTAssertNil(AssistantFlow.askAbout(EntityRef(kind: .schedule, id: 999), bundle))
        let turn = AssistantFlow.aboutTurn(EntityRef(kind: .location, id: 6), ctx())
        XCTAssertEqual(turn.blocks.first, .placeCard(id: 6))
        XCTAssertTrue(turn.blocks.last?.isChips == true)
    }

    func testTimelineSources() {
        XCTAssertEqual(BlockData.timeline([1, 2], source: nil, bundle, plan, now: now), [1, 2])
        XCTAssertEqual(BlockData.timeline([], source: "plan", bundle, plan, now: now), plan.days.first!.items.map(\.itemId))
        XCTAssertEqual(BlockData.timeline([], source: "plan", bundle, nil, now: now), [])
        XCTAssertEqual(BlockData.timeline([], source: "whats_on", bundle, plan, now: now), [111, 109, 108, 106])
    }

    func testCompareSides() {
        guard case .item(let item)? = BlockData.compare("s101", plan, bundle, likes, now: now) else { return XCTFail("item") }
        XCTAssertEqual(item.id, 101)
        guard case .version(let kind, _)? = BlockData.compare("plan:chill", plan, bundle, likes, now: now) else { return XCTFail("version") }
        XCTAssertEqual(kind, .chill)
        XCTAssertNil(BlockData.compare("plan:chill", nil, bundle, likes, now: now))
        XCTAssertNil(BlockData.compare("l1", plan, bundle, likes, now: now))
    }

    func testSummaries() {
        XCTAssertEqual(BlockData.summary("liked_counts", plan, bundle, likes, now: now, units: .imperial, locale: enUS), "2 liked items and 0 liked places")
        XCTAssertEqual(BlockData.likedCounts(LikeSet(locations: [1], scheduleItems: [101])), "1 liked item and 1 liked place")
        let walking = BlockData.summary("walking", plan, bundle, likes, now: now, units: .imperial, locale: enUS)
        XCTAssertTrue(walking?.hasSuffix(" walking today") == true, walking ?? "nil")
        XCTAssertEqual(BlockData.summary("recap", plan, bundle, likes, now: now, units: .imperial, locale: enUS), "You saw 0 things, liked 2 and walked 10 ft.")
        XCTAssertNil(BlockData.summary("walking", nil, bundle, likes, now: now, units: .imperial, locale: enUS))
    }

    func testTranscriptRoundTripsAndIsLenient() {
        let routed = AssistantRouter.route("tacos", ctx())
        let turns = [StoredTurn(input: "tacos", turn: AssistantTurn(blocks: routed.blocks)), StoredTurn(input: nil, turn: AssistantTurn(blocks: [.text("Hi")]))]
        let decoded = AssistantTranscript.decode(AssistantTranscript.encode(turns))
        XCTAssertEqual(decoded, turns)
        let text = #"[{"input":"x","blocks":[{"type":"hologram"},{"type":"text","text":"ok"}],"actions":[{"name":"nope"}]},{"blocks":"no"},7]"#
        XCTAssertEqual(AssistantTranscript.decode(text), [StoredTurn(input: "x", turn: AssistantTurn(blocks: [.text("ok")]))])
        XCTAssertEqual(AssistantTranscript.decode("{"), [])
        XCTAssertEqual(AssistantTranscript.decode(nil), [])
        let many = (1...40).map { StoredTurn(input: "\($0)", turn: AssistantTurn(blocks: [.text("\($0)")])) }
        XCTAssertEqual(AssistantTranscript.decode(AssistantTranscript.encode(many)).first?.input, "11")
    }

    func testSharedPlanUseIsExactlyTheSharedItemsAhead() {
        let used = SharedPlans.use([109, 103, 999, 101], day: PlanDate(year: 2026, month: 11, day: 14), bundle, .none, now: now)
        XCTAssertEqual(used?.itemIds, [109, 103, 101])
        XCTAssertEqual(used?.constraints.pinned, [109, 103, 101])
        XCTAssertEqual(used?.constraints.excluded, [])
        XCTAssertNil(SharedPlans.use([999], day: nil, bundle, .none, now: now))
        let evening = PlannerFixture.date("2026-11-15T02:00:00Z")
        XCTAssertEqual(SharedPlans.use([109, 104], day: nil, bundle, .none, now: evening)?.itemIds, [104])
    }

    func testSharedPlanMergeWeighsEveryone() {
        let merged = SharedPlans.merge([[103, 105], [103]], likes, bundle, current: plan, now: now)
        XCTAssertNotNil(merged)
        XCTAssertTrue(Set(merged?.itemIds ?? []).isSuperset(of: [103, 101]))
        XCTAssertEqual(merged?.constraints.groupLikes[103], 2)
        XCTAssertNil(SharedPlans.merge([], likes, bundle, current: plan, now: now))
        XCTAssertEqual(SharedPlans.decode(SharedPlans.encode([[1, 2], [3]])), [[1, 2], [3]])
        XCTAssertEqual(SharedPlans.adding([1, 2], to: [[1, 2], [3]]), [[3], [1, 2]])
    }

    func testLiveHints() {
        XCTAssertTrue(LiveHintRules.of(nil, bundle, likes, now: now, user: nil, samples: []).isEmpty)
        let morning = LiveHintRules.of(plan, bundle, likes, now: now, user: nil, samples: [])
        XCTAssertNil(morning.runningLate)
        XCTAssertFalse(morning.recapReady)
        XCTAssertTrue(morning.changed.isEmpty)
        let late = PlannerFixture.date("2026-11-15T05:30:00Z")
        XCTAssertTrue(LiveHintRules.of(plan, bundle, likes, now: late, user: nil, samples: []).recapReady)
    }
}
