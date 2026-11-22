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
        // A place is saved at once without a time; the chips offer a time.
        let saved = turn("add it to my schedule", &schedule, &memory)
        XCTAssertEqual(saved.intent, .schedule)
        XCTAssertEqual(saved.actions.map(\.name), [.scheduleAdd])
        XCTAssertNotNil(schedule.entry(.place, place.id))
        XCTAssertNil(schedule.entry(.place, place.id)?.at)
        guard case .chips(let chips)? = saved.blocks.last else { return XCTFail("chips") }
        XCTAssertTrue(chips.first?.label.hasPrefix("Pick a time: ") ?? false)
        XCTAssertEqual(chips.first?.action.name, .scheduleMove)
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

    // MARK: - Build 164: "Let's do music, food, then more music" (owner, Nov 21, 2026)

    func testSequenceBecomesOneProposal() throws {
        let sentence = "Let's do music, food, then more music"
        XCTAssertEqual(PlanProposals.sequenceSteps(sentence), [.music, .food, .music])
        XCTAssertEqual(PlanProposals.sequenceSteps("tacos then a band"), [.food, .music])
        XCTAssertEqual(PlanProposals.sequenceSteps("morning music, lunch, drinks"), [.music, .food, .drinks])
        // Not sequences: no "then" / comma, one step, a name inside a step.
        XCTAssertNil(PlanProposals.sequenceSteps("music and food"))
        XCTAssertNil(PlanProposals.sequenceSteps("music"))
        XCTAssertNil(PlanProposals.sequenceSteps("Juniper Lane then tacos"))
        XCTAssertNil(PlanProposals.sequenceSteps("what's on, and where is food"))

        // Sat 10:00, no plan: Juniper Lane (11:00, Main Stage), Taco Row (nearest food) at 12:15
        // for 45 min, then Ana Morales Trio (13:00).
        let proposal = try XCTUnwrap(PlanProposals.sequence(sentence, ctx()))
        XCTAssertEqual(proposal.kind, .add)
        XCTAssertEqual(proposal.options.count, 1)
        guard case .newPlan(let plan) = proposal.options[0].apply else { return XCTFail("new plan") }
        XCTAssertEqual(AssistantFixture.clock(plan), ["11:00 109", "12:15 lunch", "13:00 102"])
        XCTAssertEqual(plan.days.first?.meals.first?.locationId, 6)
        XCTAssertTrue(proposal.text.contains("Taco Row"))
        XCTAssertEqual(proposal.options[0].edit.after, plan)
        // With a plan: its entries stay, the new ones are added.
        let withPlan = try XCTUnwrap(PlanProposals.sequence(sentence, AssistantFixture.ctx()))
        guard case .newPlan(let merged) = withPlan.options[0].apply else { return XCTFail("merged") }
        XCTAssertTrue(Set(AssistantFixture.plan.itemIds).isSubset(of: Set(merged.itemIds)))
    }

    func testTextOnlyModelAnswerGetsItsComponents() throws {
        // The stub model answers with text alone (build 164's answer, the fixture's names).
        let text = "Right now: Juniper Lane is playing folk music, and you can grab food at Taco Row. Want me to add dinner or another band to your plan?"
        let answer = AssistantModel.assemble(text: text, shown: [], actions: [], ctx())
        XCTAssertEqual(answer.blocks.map(\.type), ["text", "carousel"])
        guard case .carousel(let ids, _) = answer.blocks[1] else { return XCTFail("carousel") }
        XCTAssertEqual(ids, [s(109), l(6)])
        // Remembered, so "add it" works.
        var memory = ConversationContext()
        memory.record(answer)
        XCTAssertEqual(memory.focus, s(109))
        var schedule = MySchedule()
        let added = turn("add it to my schedule", &schedule, &memory)
        XCTAssertEqual(added.actions.map(\.name), [.scheduleAdd])
        XCTAssertTrue(schedule.contains(.scheduleItem(109)))

        // One name → a card; generic words and lower-case one-word names → nothing.
        XCTAssertEqual(AssistantModel.assemble(text: "Taco Row has tacos.", shown: [], actions: [], ctx()).blocks.map(\.type), ["text", "place_card"])
        XCTAssertEqual(AssistantModel.namedEntities(in: "There's music on the main stage and food everywhere.", ctx()), [l(1)])
        XCTAssertEqual(AssistantModel.namedEntities(in: "Grab some food and music.", ctx()), [])
        // The model showed something: nothing added.
        let shown = AssistantModel.assemble(text: text, shown: [.placeCard(id: 6)], actions: [], ctx())
        XCTAssertEqual(shown.blocks.map(\.type), ["text", "place_card"])
    }

    // MARK: - Build 165: components over text, no ids

    func testAnswerTextIsShortAndHasNoIds() {
        let long = "DJ Lone Star is now in your schedule at 1:35 PM. Here's the updated preview: DJ Lone Star (s998) at 1:35 PM, Ana Morales Trio (s995) at 11:30 AM–12:45 PM. Anything else?"
        let turn = AssistantModel.assemble(text: long, shown: [.carousel(ids: [s(104), s(102)], title: nil)], actions: [], ctx())
        guard case .text(let text)? = turn.blocks.first else { return XCTFail("text") }
        XCTAssertEqual(text, "DJ Lone Star is now in your schedule at 1:35 PM.")
        XCTAssertEqual(turn.blocks.map(\.type), ["text", "carousel"])
        // Ids never reach the attendee, with or without components; filler goes.
        XCTAssertEqual(AssistantModel.answerText("Try Taco Row (l6) or [S12] later. Anything else?", withComponents: false),
                       "Try Taco Row or later.")
        XCTAssertEqual(AssistantModel.answerText("It's at l6 near s12, see you there!", withComponents: false), "It's at near, see you there!")
        XCTAssertEqual(AssistantModel.answerText("Here are the sets: Juniper Lane, Big Sky Radio.", withComponents: true), "Here are the sets.")
        // Without components the text stays whole (minus ids and filler).
        XCTAssertEqual(AssistantModel.answerText("Gates open at 10. Bring water.", withComponents: false), "Gates open at 10. Bring water.")
        XCTAssertEqual(AssistantModel.answerText("Anything else?", withComponents: false), "Anything else?")
    }

    func testDoneLinesAreHuman() {
        XCTAssertEqual(AssistantFlow.doneLine(stage: "Adding Taco Row…", blocks: []), "Added Taco Row")
        XCTAssertEqual(AssistantFlow.doneLine(stage: "Removing DJ Lone Star…", blocks: []), "Removed DJ Lone Star")
        XCTAssertEqual(AssistantFlow.doneLine(stage: "Planning your day…", blocks: []), "Planned your day")
        XCTAssertEqual(AssistantFlow.doneLine(stage: "Searching…", blocks: [.carousel(ids: [s(104), s(102), l(6), s(103)], title: nil)]),
                       "Found 4 results")
        XCTAssertEqual(AssistantFlow.doneLine(stage: "Searching…", blocks: [.placeCard(id: 6)]), "Found 1 result")
        XCTAssertNil(AssistantFlow.doneLine(stage: "Searching…", blocks: [.text("Nothing on.")]))
        // Show-only and reading turns have no done line ("Showed carousel" is gone).
        XCTAssertNil(AssistantFlow.doneLine(stage: "Showing carousel…", blocks: [.carousel(ids: [s(104)], title: nil)]))
        XCTAssertNil(AssistantFlow.doneLine(stage: "Thinking…", blocks: []))
        XCTAssertNil(AssistantFlow.doneLine(stage: "Checking your schedule…", blocks: []))
        XCTAssertNil(AssistantFlow.doneLine(stage: nil, blocks: []))
    }
}
