// AssistantBlocksTests.swift
// AttndTests
//
// Assistant spec §1–3 (Android's `unit/AssistantBlocksTest.kt`, same cases): the action registry
// and dispatcher, block JSON and validation, the model path (parse, fallback, streaming, prompt).

import XCTest
@testable import Attnd

final class AssistantBlocksTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let now = PlannerFixture.now
    private var blockCtx: BlockContext { BlockContext(bundle: bundle, plan: AssistantFixture.plan, now: now) }
    private func s(_ id: Int) -> EntityRef { EntityRef(kind: .schedule, id: id) }
    private func l(_ id: Int) -> EntityRef { EntityRef(kind: .location, id: id) }
    private func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    func testRegistry() {
        XCTAssertEqual(ActionName.allCases.map(\.key), [
            "search", "get_item", "get_location", "get_update", "event_info", "now_next", "whats_on", "liked", "plan", "near_me", "why_not", "route", "day_route",
            "my_schedule", "like", "unlike", "plan_make", "plan_edit", "plan_undo", "plan_version", "checkoff", "follow_lock_screen", "reminders", "notifications",
            "share_plan", "share_item", "open", "directions",
            // iOS (My schedule, Nov 21, 2026)
            "schedule_add", "schedule_remove", "schedule_move", "schedule_reminder",
        ])
        XCTAssertEqual(Set(ActionName.allCases.filter { $0.confirm == .chip }), [.followLockScreen, .reminders, .notifications])
        XCTAssertEqual(Set(ActionName.allCases.filter { $0.confirm == .sheet }), [.sharePlan, .shareItem])
        XCTAssertEqual(Set(ActionName.allCases.filter(\.undoable)), [.like, .unlike, .planMake, .planEdit, .planVersion, .checkoff, .scheduleAdd, .scheduleRemove])
        XCTAssertTrue(ActionName.allCases.filter { !$0.mutates }.allSatisfy { $0.confirm == .none })
        XCTAssertEqual(ActionName.neverAvailable, ["leave_event", "debug_mode", "copy_support_info", "add_to_calendar"])
    }

    private func check(_ name: String, _ params: String = "{}") -> ActionCheck {
        ActionRegistry.check(name, json(params).objectValue, bundle, now: now)
    }

    private func isValid(_ check: ActionCheck) -> Bool { if case .valid = check { return true } else { return false } }

    func testParamValidation() {
        XCTAssertTrue(isValid(check("like", #"{"kind":"schedule","id":"s101"}"#)))
        XCTAssertTrue(isValid(check("like", #"{"kind":"location","id":6}"#)))
        XCTAssertEqual(check("like", #"{"kind":"schedule","id":"l6"}"#), .invalid("bad id"))
        XCTAssertEqual(check("like", #"{"kind":"schedule","id":"s999"}"#), .invalid("bad id"))
        XCTAssertEqual(check("search"), .invalid("missing query"))
        XCTAssertEqual(check("teleport"), .invalid("unknown action"))
        XCTAssertEqual(check("leave_event"), .invalid("not available to the assistant"))
        XCTAssertEqual(check("whats_on", #"{"day":"2026-12-01"}"#), .invalid("bad day"))
        XCTAssertTrue(isValid(check("whats_on", #"{"day":"2026-11-15","from":"18:00"}"#)))
        XCTAssertEqual(check("whats_on", #"{"from":"6pm"}"#), .invalid("bad from"))
        XCTAssertEqual(check("open", #"{"screen":"debug"}"#), .invalid("bad screen"))
        XCTAssertEqual(check("plan_edit", #"{"ops":[{"op":"teleport"}]}"#), .invalid("bad ops"))
        // iOS has no Add to Calendar (Android keeps it): the action is never available.
        XCTAssertEqual(check("add_to_calendar", #"{"ids":["s101"]}"#), .invalid("not available to the assistant"))
    }

    private final class Recorder: ActionExecutor {
        var ran: [String] = []
        func execute(_ action: AssistantAction) -> ActionOutcome {
            ran.append(action.name.key)
            return .done()
        }
    }

    func testDispatcher() {
        let recorder = Recorder()
        let dispatcher = ActionDispatcher(executor: recorder)
        let context = ActionContext(bundle: bundle, now: now, hasLocation: false, hasPlan: true)
        let reminders = AssistantAction.toggle(.reminders, on: true)
        XCTAssertEqual(dispatcher.dispatch(reminders, context: context, source: .rules),
                       .needsConfirmation(.confirm(action: reminders, prompt: "Turn on reminders before things in your schedule?")))
        XCTAssertTrue(recorder.ran.isEmpty)
        XCTAssertEqual(dispatcher.dispatch(reminders, context: context, source: .rules, confirmed: true), .executed(.done(), undo: nil))
        XCTAssertEqual(dispatcher.dispatch(reminders, context: context, source: .manual), .executed(.done(), undo: nil))
        // Like applies at once with its Undo.
        let like = AssistantAction.like(.schedule, 101)
        XCTAssertEqual(dispatcher.dispatch(like, context: context, source: .model), .executed(.done(), undo: .like(.schedule, 101, liked: false)))
        let edit = AssistantAction.planEdit([.remove(item: 109)], bundle)
        XCTAssertEqual(dispatcher.dispatch(edit, context: context, source: .rules), .executed(.done(), undo: AssistantAction(name: .planUndo)))
        var noPlan = context
        noPlan.hasPlan = false
        XCTAssertEqual(dispatcher.dispatch(edit, context: noPlan, source: .rules), .rejected("no plan"))
        XCTAssertEqual(dispatcher.dispatch(AssistantAction(name: .nearMe), context: context, source: .model), .rejected("needs location"))
        // The App Clip runs the same assistant as the app (no write restriction on iOS).
        XCTAssertEqual(recorder.ran, ["reminders", "reminders", "like", "plan_edit"])
    }

    func testJSONRoundTrip() {
        let blocks: [AssistantBlock] = [
            .text("**Hi**"), .itemCard(id: 101), .placeCard(id: 6, show: ["image"]), .updateCard(id: 31),
            .list(ids: [s(101), l(6)], title: "Mixed", limit: 5), .carousel(ids: [l(4), l(5)], title: "Food"),
            .timeline(ids: [105, 101], title: "Tonight"), .timeline(source: "plan"),
            .map(pins: [1, 2], route: [1, 2]), .gallery(flyer: true), .nowNext(location: 1), .countdown(id: 101),
            .compare(a: "plan:chill", b: "plan:everything"),
            .planDiff(PlanDiff(removed: [103], added: [107], moved: [PlanDiff.Move(from: 109, to: 115)])),
            .plan(day: PlanDate(year: 2026, month: 11, day: 14)), .setting("reminders"), .summary("walking"),
            .share("item:s101"), .chips([AssistantChip(label: "Liked", action: AssistantAction(name: .liked))]),
            .confirm(action: .toggle(.reminders, on: true), prompt: "Sure?"),
        ]
        for block in blocks {
            XCTAssertEqual(BlockJSON.decode(JSONValue.parse(BlockJSON.encode(block).encoded)), .ok(block), block.type)
        }
        XCTAssertEqual(BlockJSON.encode(AssistantBlock.placeCard(id: 6, show: ["image"])).encoded, #"{"type":"place_card","id":"l6","show":["image"]}"#)
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"hologram"}"#)), .unknown)
        // Android's calendar block isn't an iOS type: dropped like any unknown one.
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"calendar","ids":[],"plan":true}"#)), .unknown)
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"item_card"}"#)), .malformed("item_card"))
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"list","ids":["x12"]}"#)), .malformed("list"))
        // Ids as numbers or upper case are read.
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"item_card","id":101}"#)), .ok(.itemCard(id: 101)))
        XCTAssertEqual(BlockJSON.decode(json(#"{"type":"carousel","ids":["S101","[l6]"]}"#)), .ok(.carousel(ids: [s(101), l(6)])))
    }

    func testValidation() {
        let v = BlockValidator.validate([
            .text("   "),
            .text(String(repeating: "x", count: 450)),
            .itemCard(id: 999),
            .carousel(ids: [s(999), l(6)]),
            .list(ids: [s(101), s(101), l(999), l(1)]),
            .map(pins: [9, 1, 1, 2]), // the Info Booth has no coordinates
            .countdown(id: 111), // already started
            .timeline(ids: [104, 101, 999]),
            .gallery(ids: [1], flyer: true), // no images, no flyer
            .compare(a: "s101", b: "s101"),
            .share("item:s999"),
            .chips([AssistantChip(label: "A", action: AssistantAction(name: .liked))]),
        ], blockCtx)
        XCTAssertEqual(v, [
            .text(String(repeating: "x", count: 399) + "…"),
            .placeCard(id: 6),
            .list(ids: [s(101), l(1)]),
            .map(pins: [1, 2]),
            .timeline(ids: [101, 104]),
            .chips([AssistantChip(label: "A", action: AssistantAction(name: .liked))]),
        ])
        // More than 8 blocks: 7 + the (last) chips block.
        let chips = AssistantBlock.chips((1...7).map { AssistantChip(label: "C\($0)", action: .search("c\($0)")) } + [AssistantChip(label: "Bad", action: .search(""))])
        let many = (1...10).map { AssistantBlock.text("t\($0)") } + [.chips([AssistantChip(label: "Old", action: AssistantAction(name: .liked))]), chips]
        let cut = BlockValidator.validate(many, blockCtx)
        XCTAssertEqual(cut.count, 8)
        XCTAssertEqual(cut.prefix(7).map { block -> String in if case .text(let t) = block { return t } else { return "" } }, (1...7).map { "t\($0)" })
        if case .chips(let kept) = cut.last { XCTAssertEqual(kept.map(\.label), (1...5).map { "C\($0)" }) } else { XCTFail("chips last") }
        XCTAssertEqual(BlockValidator.validate((1...10).map { AssistantBlock.text("t\($0)") }, blockCtx).count, 8)
        // Plan blocks need a plan.
        XCTAssertEqual(BlockValidator.validate([.plan(day: nil), .share("plan"), .summary("walking")], BlockContext(bundle: bundle, plan: nil, now: now)), [])
    }

    func testModelTurns() {
        let c = AssistantFixture.ctx()
        // Valid: unknown block types and ids are dropped, a reminders write becomes a confirm block.
        let raw = #"Sure! {"blocks":[{"type":"text","text":"The **Prairie Lights** play at 7."},{"type":"item_card","id":"s101"},{"type":"item_card","id":"s999"},{"type":"hologram"},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"schedule","id":"s101"}},{"label":"Leave","action":"leave_event"}]}],"actions":[{"name":"reminders","params":{"on":true}}]} hope that helps"#
        guard case .valid(let turn) = AssistantModel.parse(raw, c) else { return XCTFail("valid reply") }
        XCTAssertEqual(
            BlockJSON.encode(turn).encoded,
            #"{"blocks":[{"type":"text","text":"The **Prairie Lights** play at 7."},{"type":"item_card","id":"s101","show":["time","place","distance","like","actions"]},{"type":"confirm","action":"reminders","params":{"on":true},"prompt":"Turn on reminders before things in your schedule?"},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"schedule","id":"s101"}}]}],"actions":[]}"#
        )
        // A read action is rendered with the router's layout; open stays an action.
        guard case .valid(let read) = AssistantModel.parse(#"{"blocks":[{"type":"text","text":"Here"}],"actions":[{"name":"search","params":{"query":"tacos"}},{"name":"open","params":{"screen":"map"}}]}"#, c)
        else { return XCTFail("valid read") }
        XCTAssertEqual(read.blocks.map(\.type), ["text", "place_card", "item_card"])
        XCTAssertEqual(read.actions, [.open("map")])
        // Invalid → the router answers.
        XCTAssertEqual(AssistantModel.parse(#"{"blocks":[{"type":"item_card"}]}"#, c), .invalid("malformed item_card"))
        XCTAssertEqual(AssistantModel.parse("I can't do that.", c), .invalid("no json"))
        XCTAssertEqual(AssistantModel.parse(#"{"answer":"x"}"#, c), .invalid("no blocks"))
        XCTAssertEqual(AssistantModel.parse(#"{"blocks":[],"actions":[{"name":"leave_event"}]}"#, c), .invalid("action leave_event: not available to the assistant"))
        XCTAssertEqual(AssistantModel.parse(#"{"blocks":[{"type":"item_card","id":"s12345"}]}"#, c), .invalid("nothing left"))
        let fallback = AssistantModel.resolve("tacos", raw: #"{"blocks":[{"type":"item_card"}]}"#, c)
        XCTAssertEqual(fallback.source, .rules)
        XCTAssertEqual(fallback.turn.blocks.map(\.type), ["place_card", "item_card", "chips"])
        let model = AssistantModel.resolve("tacos", raw: #"{"blocks":[{"type":"place_card","id":"l6"}]}"#, c)
        XCTAssertEqual(model.source, .model)
        XCTAssertEqual(model.turn, AssistantTurn(blocks: [.placeCard(id: 6)]))
    }

    func testStreamingAndPrompt() {
        let c = AssistantFixture.ctx()
        let partial = #"{"blocks":[{"type":"text","text":"Tonight: {fun}"},{"type":"item_card","id":"s101"},{"type":"carou"#
        XCTAssertEqual(AssistantModel.completeBlocks(partial, c), [.text("Tonight: {fun}"), .itemCard(id: 101)])

        let retrieved = AssistantModel.retrieve("What's good tonight?", c)
        XCTAssertEqual(retrieved.prefix(6).map(\.id), [105, 112, 113, 101, 114, 104])
        XCTAssertLessThanOrEqual(retrieved.count, 12)
        let conversation = (1...8).reduce(AssistantConversation()) { acc, i in
            acc.with(ConversationTurn(fromUser: i % 2 == 1, text: i == 1 ? "Where are the tacos?" : "turn \(i)"))
        }
        XCTAssertEqual(conversation.promptLines(), [
            "(earlier: 1 more requests about tacos)", "Attendee: turn 3", "Assistant: turn 4", "Attendee: turn 5",
            "Assistant: turn 6", "Attendee: turn 7", "Assistant: turn 8",
        ])
        XCTAssertEqual(AssistantConversation.decode(conversation.encode()), conversation)
        let prompt = AssistantModel.prompt("What's good tonight?", c, conversation, retrieved)
        XCTAssertTrue(prompt.contains("PLAN: 8 items, 10:00 AM – 11:00 PM, with a lunch break — s111; s109; s102; s103; s105; s113; s101; s104"))
        XCTAssertTrue(prompt.contains("LIKED: s101 The Prairie Lights; s114 Neon Armadillo"))
        XCTAssertTrue(prompt.contains("[s101] The Prairie Lights — Sat 7:00–8:30 PM · Main Stage — tags: live music, country — liked, in plan"), prompt)
        XCTAssertFalse(prompt.contains("leave_event"))
        XCTAssertTrue(prompt.trimmingTrailingSpaces().hasSuffix("INPUT: What's good tonight?\nJSON:"))
    }

    func testJSONValue() {
        let text = #"{"a":[1,2.5,true,null,"x\"\né"],"b":{}}"#
        let value = JSONValue.parse(text)
        XCTAssertEqual(value?.encoded, #"{"a":[1,2.5,true,null,"x\"\né"],"b":{}}"#)
        XCTAssertNil(JSONValue.parse(#"{"a":}"#))
        XCTAssertEqual(JSONObject(dictionaryLiteral: ("a", 1), ("b", 2)), JSONObject(dictionaryLiteral: ("b", 2), ("a", 1)))
        XCTAssertEqual(JSONValue.string("12").intValue, 12)
        XCTAssertNil(JSONValue.number("1.0").intValue)
    }
}
