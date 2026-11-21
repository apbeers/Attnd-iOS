// ComponentTests.swift
// AttndTests
//
// One component catalogue (iOS, Nov 21, 2026): server layouts (API-024) and chat components
// decode to the same `Component`; older names map across; unknown types are skipped; the model
// path's token budget; API-023 theme decoding.

import XCTest
@testable import Attnd

final class ComponentTests: XCTestCase {
    private let bundle = PlannerFixture.bundle

    func testLayoutsAndChatDecodeTheSameComponent() throws {
        let menuSection = LayoutSection("menu", title: "Food")
        let fromLayout = ComponentCatalogue.component(menuSection, subject: EntityRef(kind: .location, id: 6))
        let fromChat = ComponentCatalogue.decode(JSONValue.parse(#"{"type":"menu","ids":["l6"],"title":"Food"}"#)!.objectValue!)
        XCTAssertEqual(fromLayout, fromChat)
        // Event-wide parts carry no subject either way.
        XCTAssertEqual(ComponentCatalogue.component(LayoutSection("faq", limit: 3)),
                       ComponentCatalogue.decode(JSONValue.parse(#"{"type":"faq","limit":3}"#)!.objectValue!))
        // Older names map across; a subject of the wrong kind or none is refused.
        XCTAssertEqual(ComponentCatalogue.component(LayoutSection("liked")).type, "my_schedule")
        XCTAssertEqual(ComponentCatalogue.chat("plan_today")?.type, "my_schedule")
        XCTAssertNil(ComponentCatalogue.chat("menu", ids: [EntityRef(kind: .schedule, id: 101)]))
        XCTAssertNil(ComponentCatalogue.chat("walk_map"))
        XCTAssertNil(ComponentCatalogue.chat("weather"))
    }

    func testBlockJSONCarriesScreenComponents() {
        // A screen component in a chat answer is a block; unknown types are dropped.
        guard case .ok(.component(let c)) = BlockJSON.decode(JSONValue.parse(#"{"type":"performers","ids":["s101"]}"#)) else {
            return XCTFail("component")
        }
        XCTAssertEqual(c.type, "performers")
        XCTAssertEqual(BlockJSON.encode(.component(c)).encoded, #"{"type":"performers","ids":["s101"]}"#)
        XCTAssertEqual(BlockJSON.decode(JSONValue.parse(#"{"type":"calendar"}"#)), .unknown)
        // The validator keeps a component only when its data is there (no menu in the fixture).
        let ctx = BlockContext(bundle: bundle, plan: nil, now: PlannerFixture.now)
        XCTAssertTrue(BlockValidator.validate([.component(Component(type: "menu", ids: [EntityRef(kind: .location, id: 6)]))], ctx).isEmpty)
        XCTAssertEqual(BlockValidator.validate([.component(Component(type: "my_schedule"))], ctx).count, 1)
        // The renderer's input from a block keeps its ids.
        XCTAssertEqual(ComponentCatalogue.component(.carousel(ids: [EntityRef(kind: .location, id: 6)], title: nil)).ids.map(\.code), ["l6"])
    }

    func testCatalogueIsTheLayoutSide() {
        XCTAssertNotNil(SectionCatalogue.type("my_schedule", on: .home))
        XCTAssertNotNil(SectionCatalogue.type("liked", on: .home))
        XCTAssertNil(SectionCatalogue.type("my_schedule", on: .placeDetail))
        XCTAssertEqual(SectionCatalogue.type("header", on: .placeDetail)?.parts, SectionCatalogue.placeHeaderParts)
        XCTAssertTrue(ComponentCatalogue.chatScreenTypes.isSuperset(of: ["menu", "performers", "faq", "getting_there", "my_schedule", "amenities"]))
    }

    func testShowToolBlocks() {
        let ctx = AssistantFixture.ctx()
        XCTAssertEqual(AssistantModel.showBlock("card", ids: ["l6"], title: nil, ctx), .placeCard(id: 6))
        XCTAssertEqual(AssistantModel.showBlock("carousel", ids: ["l6", "l5", "l99"], title: "Food", ctx),
                       .carousel(ids: [EntityRef(kind: .location, id: 6), EntityRef(kind: .location, id: 5)], title: "Food"))
        XCTAssertEqual(AssistantModel.showBlock("my_schedule", ids: [], title: "", ctx), .component(Component(type: "my_schedule")))
        XCTAssertNil(AssistantModel.showBlock("menu", ids: ["l6"], title: nil, ctx))
        XCTAssertNil(AssistantModel.showBlock("nonsense", ids: [], title: nil, ctx))
        // Write tools: valid, or an error for the model to fix.
        if case .failure(let error) = AssistantModel.toolAction(.scheduleAdd, ["target": "l999"], ctx) {
            XCTAssertTrue(error.message.hasPrefix("Error:"))
        } else { XCTFail("l999") }
        if case .success(let action) = AssistantModel.toolAction(.scheduleAdd, ["target": "s112"], ctx) {
            XCTAssertEqual(action.name, .scheduleAdd)
        } else { XCTFail("s112") }
        // The answer: text, components, then confirmations.
        let turn = AssistantModel.assemble(text: "Taco Row has tacos.", shown: [.placeCard(id: 6)],
                                           actions: [.scheduleAdd(EntityRef(kind: .location, id: 6)), .toggle(.reminders, on: true)], ctx)
        XCTAssertEqual(turn.blocks.map(\.type), ["text", "place_card", "confirm"])
        XCTAssertEqual(turn.actions.map(\.name), [.scheduleAdd])
    }

    func testTokenBudgetTrimsInOrder() {
        let parts = AssistantModel.PromptParts(
            header: ["NOW: Saturday"], facts: [String(repeating: "f", count: 700)], schedule: ["MY SCHEDULE: empty"],
            memory: [], history: (1...6).map { "Attendee: question \($0) " + String(repeating: "h", count: 100) },
            items: (1...12).map { "[s\($0)] item " + String(repeating: "i", count: 100) }, input: "tacos?"
        )
        let roomy = AssistantModel.budget(parts, limit: 10_000)
        XCTAssertEqual(roomy.trimmed, [])
        // Oldest turns first.
        let some = AssistantModel.budget(parts, limit: roomy.tokens - 50)
        XCTAssertEqual(some.trimmed, ["history:2"])
        XCTAssertFalse(some.text.contains("question 1 "))
        XCTAssertTrue(some.text.contains("question 6"))
        // Then items, then facts; header, schedule and input always stay.
        let tight = AssistantModel.budget(parts, limit: 60)
        XCTAssertEqual(tight.trimmed, ["history:6", "items:12", "facts"])
        XCTAssertTrue(tight.text.contains("NOW: Saturday") && tight.text.contains("MY SCHEDULE") && tight.text.hasSuffix("INPUT: tacos?"))
        XCTAssertTrue(TokenBudget.fits(used: 0, prompt: TokenBudget.freshPrompt))
        XCTAssertFalse(TokenBudget.fits(used: 2_000, prompt: TokenBudget.freshPrompt))
        // A real prompt fits a fresh session.
        let prompt = AssistantModel.toolPrompt("where are the tacos", AssistantFixture.ctx(), AssistantConversation(),
                                               AssistantModel.retrieve("where are the tacos", AssistantFixture.ctx()),
                                               freshSession: true, limit: TokenBudget.freshPrompt)
        XCTAssertLessThanOrEqual(prompt.tokens, TokenBudget.freshPrompt)
        XCTAssertTrue(prompt.text.contains("MY SCHEDULE:"))
    }

    func testThemeDecoding() throws {
        struct Wrapper: Decodable { var event: Event }
        func event(_ theme: String) throws -> Event {
            let json = ##"{"event":{"id":1,"name":"X","event_code":"X","theme":"## + theme + "}}"
            return try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).event
        }
        let full = try event(##"{"light":{"primary":"#b23a1e","secondary":"#F2A65A","tertiary":"#1F7A8C","x":1},"dark":{"primary":"#F4895F","secondary":"#7A3B24","tertiary":"#4FB3C4"}}"##)
        XCTAssertEqual(full.theme?.light?.primary, "#B23A1E")
        XCTAssertEqual(full.theme?.hex(\.tertiary, dark: true), "#4FB3C4")
        // Lenient: a bad value or a missing role / mode means the default for it.
        let partial = try event(##"{"light":{"primary":"red","secondary":"#F2A65A"},"dark":null}"##)
        XCTAssertNil(partial.theme?.light?.primary)
        XCTAssertEqual(partial.theme?.light?.secondary, "#F2A65A")
        XCTAssertNil(partial.theme?.dark)
        XCTAssertNil(try event("null").theme)
        XCTAssertNil(try event(##"{"light":{"primary":"#12345"}}"##).theme)
        XCTAssertNil(try event(##""nope""##).theme)
    }
}
