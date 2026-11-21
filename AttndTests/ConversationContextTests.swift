// ConversationContextTests.swift
// AttndTests
//
// The assistant's memory (iOS, Nov 21, 2026): pronouns, ordinals and descriptions resolved
// against what the answers showed, and the router's My schedule grammar end to end ("find
// dinner" → "add it to my schedule" → "add it at 7" → "move it to 8" → "remind me 30 min
// before it"; "add the second one"; the clash question). No model: the router alone (the model
// path is the same actions through its tools).

import XCTest
@testable import Attnd

final class ConversationContextTests: XCTestCase {
    private let bundle = PlannerFixture.bundle
    private func s(_ id: Int) -> EntityRef { EntityRef(kind: .schedule, id: id) }
    private func l(_ id: Int) -> EntityRef { EntityRef(kind: .location, id: id) }

    /// The router with My schedule and memory, no likes or plan.
    private func ctx(_ schedule: MySchedule = MySchedule(), _ memory: ConversationContext = ConversationContext()) -> RouterContext {
        var c = RouterContext(bundle: bundle, likes: LikeSet(locations: schedule.placeIds, scheduleItems: schedule.itemIds),
                              plan: nil, now: PlannerFixture.now)
        c.schedule = schedule
        c.memory = memory
        return c
    }

    /// Runs a turn like the controller: route, apply its schedule actions, remember it.
    private func turn(_ input: String, _ schedule: inout MySchedule, _ memory: inout ConversationContext) -> RoutedTurn {
        let routed = AssistantRouter.route(input, ctx(schedule, memory))
        for action in routed.actions { apply(action, &schedule) }
        memory.record(routed.turn)
        return routed
    }

    private func apply(_ action: AssistantAction, _ schedule: inout MySchedule) {
        guard let ref = action.scheduleTarget() else { return }
        let target = AssistantRouter.target(ref)
        let zone = bundle.event.timeZone
        let at = action.string("time").flatMap(PlanClock.parse).map { MySchedule.date($0, near: schedule.entry(for: target)?.at, now: PlannerFixture.now, timeZone: zone) }
        switch action.name {
        case .scheduleAdd:
            if let replaced = action.scheduleTarget("replace") { schedule.remove(AssistantRouter.target(replaced)) }
            schedule.add(target, at: ref.kind == .location ? at : nil)
        case .scheduleRemove: schedule.remove(target)
        case .scheduleMove: schedule.move(target, to: at)
        case .scheduleReminder: schedule.setReminder(target, minutes: action.params["minutes"]?.intValue)
        default: break
        }
    }

    func testResolution() {
        var memory = ConversationContext()
        memory.record(AssistantTurn(blocks: [.carousel(ids: [l(6), l(5), l(4)], title: "Places")]))
        let kinds: Set<RefKind> = [.schedule, .location]
        XCTAssertEqual(memory.focus, l(6))
        XCTAssertEqual(memory.resolve("it", kinds: kinds, bundle), [l(6)])
        XCTAssertEqual(memory.resolve("that one", kinds: kinds, bundle), [l(6)])
        XCTAssertEqual(memory.resolve("there", kinds: kinds, bundle), [l(6)])
        XCTAssertEqual(memory.resolve("the second one", kinds: kinds, bundle), [l(5)])
        XCTAssertEqual(memory.resolve("the last one", kinds: kinds, bundle), [l(4)])
        XCTAssertEqual(memory.resolve("option 3", kinds: kinds, bundle), [l(4)])
        XCTAssertEqual(memory.resolve("both", kinds: kinds, bundle), [l(6), l(5)])
        XCTAssertEqual(memory.resolve("them", kinds: kinds, bundle), [l(6), l(5), l(4)])
        XCTAssertEqual(memory.resolve("the taco place", kinds: kinds, bundle), [l(6)])
        XCTAssertEqual(memory.resolve("the bbq one", kinds: kinds, bundle), [l(5)])
        XCTAssertNil(memory.resolve("the prairie lights", kinds: kinds, bundle))
        XCTAssertNil(memory.resolve("3", kinds: kinds, bundle))
        XCTAssertNil(memory.resolve("it", kinds: [.schedule], bundle))
        // A turn showing nothing keeps the memory; an action's target becomes the focus.
        memory.record(AssistantTurn(blocks: [.text("When?")]))
        XCTAssertEqual(memory.shown, [l(6), l(5), l(4)])
        memory.record(AssistantTurn(blocks: [.text("Added.")], actions: [.scheduleAdd(l(5), time: "19:00")]))
        XCTAssertEqual(memory.focus, l(5))
        XCTAssertEqual(memory.lastAction, "schedule_add")
        // Stored with the conversation.
        let conversation = AssistantConversation(turns: [ConversationTurn(fromUser: true, text: "hi")], memory: memory)
        let decoded = AssistantConversation.decode(conversation.encode())
        XCTAssertEqual(decoded.memory, memory)
        XCTAssertEqual(decoded.turns, conversation.turns)
        // Older builds stored the turns array alone.
        XCTAssertEqual(AssistantConversation.decode(#"[{"fromUser":true,"text":"hi"}]"#).turns.count, 1)
    }

    func testFindDinnerAddItMoveItRemindMe() {
        var schedule = MySchedule()
        var memory = ConversationContext()
        let found = turn("find dinner", &schedule, &memory)
        XCTAssertEqual(found.intent, .search)
        XCTAssertEqual(memory.focus?.kind, .location)
        let place = memory.focus!
        // A place without a time asks "When?" with times and "Just save it".
        let when = turn("add it to my schedule", &schedule, &memory)
        XCTAssertEqual(when.intent, .schedule)
        XCTAssertTrue(when.actions.isEmpty)
        guard case .chips(let chips)? = when.blocks.last else { return XCTFail("chips") }
        XCTAssertEqual(chips.last?.label, "Just save it")
        // "add it at 7" → 7:00 PM today.
        let added = turn("add it at 7", &schedule, &memory)
        XCTAssertEqual(added.actions.map(\.name), [.scheduleAdd])
        XCTAssertEqual(schedule.entry(.place, place.id)?.at, PlannerFixture.sat("19:00"))
        // "move it to 8" → 8:00 PM.
        let moved = turn("move it to 8", &schedule, &memory)
        XCTAssertEqual(moved.actions.map(\.name), [.scheduleMove])
        XCTAssertEqual(schedule.entry(.place, place.id)?.at, PlannerFixture.sat("20:00"))
        // "remind me 30 min before it".
        let reminded = turn("remind me 30 min before it", &schedule, &memory)
        XCTAssertEqual(reminded.actions.map(\.name), [.scheduleReminder])
        XCTAssertEqual(schedule.entry(.place, place.id)?.reminderMinutes, 30)
        // What's on my schedule lists it.
        let mine = turn("what's on my schedule", &schedule, &memory)
        XCTAssertEqual(mine.intent, .schedule)
        XCTAssertTrue(BlockJSON.encode(mine.turn).encoded.contains("\"\(place.code)\""))
        // Remove it.
        _ = turn("remove it from my itinerary", &schedule, &memory)
        XCTAssertNil(schedule.entry(.place, place.id))
    }

    func testAddTheSecondOne() {
        var schedule = MySchedule()
        var memory = ConversationContext()
        _ = turn("what's on tonight", &schedule, &memory)
        let second = memory.shown[1]
        let added = turn("add the second one", &schedule, &memory)
        XCTAssertEqual(added.actions.first?.scheduleTarget(), second)
        XCTAssertTrue(schedule.itemIds.contains(second.id))
        // Items keep the organizer's time.
        let move = turn("move it to 8", &schedule, &memory)
        XCTAssertTrue(move.actions.isEmpty)
    }

    func testClashFlow() {
        var schedule = MySchedule()
        schedule.add(.scheduleItem(113))  // Sundown Choir 6:15 PM
        var memory = ConversationContext()
        let clash = turn("add beer tasting", &schedule, &memory)
        XCTAssertTrue(clash.actions.isEmpty)
        guard case .text(let text)? = clash.blocks.first, case .chips(let chips)? = clash.blocks.last else { return XCTFail("blocks") }
        XCTAssertEqual(text, "That overlaps **Sundown Choir** at 6:15 PM. Replace it or keep both?")
        XCTAssertEqual(chips.map(\.label), ["Replace Sundown Choir", "Keep both"])
        apply(chips[0].action, &schedule)
        XCTAssertEqual(schedule.itemIds, [112])
        // Ambiguous names ask which one.
        let which = turn("add stage", &schedule, &memory)
        XCTAssertEqual(which.intent, .pick)
    }

    func testVocabulary() {
        var schedule = MySchedule()
        var memory = ConversationContext()
        XCTAssertEqual(turn("put juniper lane in my agenda", &schedule, &memory).actions.map(\.name), [.scheduleAdd])
        XCTAssertEqual(turn("book the prairie lights", &schedule, &memory).actions.map(\.name), [.scheduleAdd])
        XCTAssertEqual(turn("drop juniper lane", &schedule, &memory).actions.map(\.name), [.scheduleRemove])
        XCTAssertEqual(turn("don't remind me about the prairie lights", &schedule, &memory).actions.map(\.name), [.scheduleReminder])
        XCTAssertEqual(schedule.entry(.item, 101)?.reminderMinutes, 0)
        // Small typos go through the search.
        XCTAssertEqual(turn("add the prairie ligts", &schedule, &memory).intent, .schedule)
    }

    func testForeignQuestionsGoToTheModel() {
        XCTAssertEqual(AssistantFlow.path(.noMatch, "¿Dónde hay comida?", modelAvailable: true), .ask)
        XCTAssertEqual(AssistantFlow.path(.search, "wo gibt es essen", modelAvailable: true), .ask)
        XCTAssertEqual(AssistantFlow.path(.search, "tacos", modelAvailable: true), .search)
        XCTAssertEqual(AssistantFlow.path(.search, "wo gibt es essen", modelAvailable: false), .search)
        XCTAssertFalse(AssistantFlow.looksForeign("where is the food"))
    }

    func testChatTranscriptRoundTripAndFollowUps() {
        let chip = AssistantChip(label: "Remind me 30 min before", action: .scheduleReminder(l(6), minutes: 30))
        let entries = (1...45).map { i in
            ChatTranscript.Entry(id: i, input: "q\(i)", blocks: [.text("a\(i)"), .component(Component(type: "my_schedule")), .chips([chip])],
                                 fromModel: i % 2 == 0, status: i == 45 ? "Added Taco Row" : nil)
        }
        let decoded = ChatTranscript.decode(ChatTranscript(entries: entries).encode())
        XCTAssertEqual(decoded.entries.count, ChatTranscript.maxTurns)
        XCTAssertEqual(decoded.entries.first?.id, 6)
        XCTAssertEqual(decoded.entries.last, entries.last)
        XCTAssertEqual(ChatTranscript.followUps(decoded.entries).map(\.label), ["Remind me 30 min before"])
        XCTAssertTrue(ChatTranscript.decode("nonsense").entries.isEmpty)
    }
}
