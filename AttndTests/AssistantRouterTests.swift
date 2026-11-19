// AssistantRouterTests.swift
// AttndTests
//
// Assistant spec §9: the rule-based router's exact output (intent, block + action JSON, and the
// plan after a plan edit) for a fixed list of inputs on `AssistantFixture` — the same cases and
// JSON as Android's `unit/AssistantRouterTest.kt`.

import XCTest
@testable import Attnd

final class AssistantRouterTests: XCTestCase {

    private struct Case {
        var input: String
        var ctx: RouterContext
        var intent: AssistantIntent
        var json: String
        var planAfter: [String]?
    }

    private let cases: [Case] = [
        Case(input: "tacos", ctx: AssistantFixture.ctx(), intent: .search,
             json: #"{"blocks":[{"type":"place_card","id":"l6","show":["image","distance","now_next","like","actions"]},{"type":"item_card","id":"s107","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"location","id":"l6"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l6"}},{"label":"Directions","action":"directions","params":{"location":"l6"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "what's on tonight", ctx: AssistantFixture.ctx(), intent: .whatsOn,
             json: #"{"blocks":[{"type":"timeline","ids":["s105","s112","s113","s101","s114","s104"],"title":"Tonight"},{"type":"chips","chips":[{"label":"Show the map","action":"open","params":{"screen":"map"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "food near me", ctx: AssistantFixture.ctx(user: AssistantFixture.atMainStage), intent: .nearMe,
             json: #"{"blocks":[{"type":"map","pins":["l6","l4","l5"]},{"type":"carousel","ids":["l6","l4","l5"],"title":"Near you"},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"location","id":"l6"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l6"}},{"label":"Directions","action":"directions","params":{"location":"l6"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "food near me", ctx: AssistantFixture.ctx(), intent: .nearMe,
             json: #"{"blocks":[{"type":"text","text":"Turn on location to see what's closest."},{"type":"carousel","ids":["l5","l4","l6"],"title":"Places"},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"location","id":"l5"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l5"}},{"label":"Directions","action":"directions","params":{"location":"l5"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "like prairie lights", ctx: AssistantFixture.ctx(likes: .none), intent: .like,
             json: #"{"blocks":[{"type":"text","text":"Liked The Prairie Lights."},{"type":"item_card","id":"s101","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Unlike","action":"unlike","params":{"kind":"schedule","id":"s101"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l1"}}]}],"actions":[{"name":"like","params":{"kind":"schedule","id":"s101"}}]}"#,
             planAfter: nil),
        Case(input: "like prairie lights", ctx: AssistantFixture.ctx(), intent: .like,
             json: #"{"blocks":[{"type":"text","text":"You already like The Prairie Lights."},{"type":"item_card","id":"s101","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Unlike","action":"unlike","params":{"kind":"schedule","id":"s101"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l1"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "replace the 3pm thing with something like neon armadillo", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"Removed Big Sky Radio. Added Street tacos at home."},{"type":"plan_diff","diff":{"removed":["s103"],"added":["s107"],"moved":[],"meals_removed":[],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"replace","item":"s103","like":"s114"}]}}]}"#,
             planAfter: ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "14:15 107", "17:00 105", "18:15 113", "19:00 101", "21:00 104"]),
        Case(input: "I already ate", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"No lunch break."},{"type":"plan_diff","diff":{"removed":[],"added":[],"moved":[],"meals_removed":["2026-11-14:lunch"],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"constraint","no_food_until":"2026-11-14T19:00:00Z"}]}}]}"#,
             planAfter: ["10:00 111", "11:00 109", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"]),
        Case(input: "done by 9", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"Removed DJ Lone Star."},{"type":"plan_diff","diff":{"removed":["s104"],"added":[],"moved":[],"meals_removed":[],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"constraint","done_by":"21:00"}]}}]}"#,
             planAfter: ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"]),
        Case(input: "share my plan", ctx: AssistantFixture.ctx(), intent: .share,
             json: #"{"blocks":[{"type":"share","target":"plan"}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "why isn't neon armadillo in my plan", ctx: AssistantFixture.ctx(), intent: .whyNot,
             json: #"{"blocks":[{"type":"text","text":"Neon Armadillo clashes with The Prairie Lights (liked)."},{"type":"item_card","id":"s114","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Swap it in","action":"plan_edit","params":{"ops":[{"op":"add","item":"s114"}]}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "turn on reminders", ctx: AssistantFixture.ctx(), intent: .toggle,
             json: #"{"blocks":[{"type":"confirm","action":"reminders","params":{"on":true},"prompt":"Turn on reminders before liked and planned items?"}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "xqzv blorp", ctx: AssistantFixture.ctx(), intent: .noMatch,
             json: #"{"blocks":[{"type":"text","text":"Nothing matches that. Try one of these:"},{"type":"chips","chips":[{"label":"Happening now","action":"search","params":{"query":"now"}},{"label":"Up next","action":"search","params":{"query":"next"}},{"label":"Liked","action":"liked","params":{}},{"label":"Stage","action":"search","params":{"query":"Stage"}},{"label":"Food","action":"search","params":{"query":"Food"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "", ctx: AssistantFixture.ctx(), intent: .empty,
             json: #"{"blocks":[{"type":"chips","chips":[{"label":"Happening now","action":"search","params":{"query":"now"}},{"label":"Up next","action":"search","params":{"query":"next"}},{"label":"Liked","action":"liked","params":{}},{"label":"Stage","action":"search","params":{"query":"Stage"}},{"label":"Food","action":"search","params":{"query":"Food"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "like stage", ctx: AssistantFixture.ctx(), intent: .pick,
             json: #"{"blocks":[{"type":"text","text":"Which one do you mean?"},{"type":"chips","chips":[{"label":"Main Stage","action":"like","params":{"kind":"location","id":"l1"}},{"label":"Trinity Stage","action":"like","params":{"kind":"location","id":"l2"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "I already ate", ctx: AssistantFixture.ctx(plan: nil), intent: .noPlan,
             json: #"{"blocks":[{"type":"text","text":"You don't have a plan yet."},{"type":"chips","chips":[{"label":"Plan my Saturday around live music and food","action":"plan_make","params":{"request":"Plan my Saturday around live music and food"}},{"label":"I've got 3 hours, show me the highlights","action":"plan_make","params":{"request":"I've got 3 hours, show me the highlights"}},{"label":"Kid-friendly afternoon","action":"plan_make","params":{"request":"Kid-friendly afternoon"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "like beer tasting", ctx: AssistantFixture.ctx(), intent: .like,
             json: #"{"blocks":[{"type":"text","text":"Liked Beer tasting."},{"type":"item_card","id":"s112","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Add to plan instead of Sundown Choir?","action":"plan_edit","params":{"ops":[{"op":"replace","item":"s113","with":"s112"}]}},{"label":"Unlike","action":"unlike","params":{"kind":"schedule","id":"s112"}},{"label":"Add to my plan","action":"plan_edit","params":{"ops":[{"op":"add","item":"s112"}]}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l8"}}]}],"actions":[{"name":"like","params":{"kind":"schedule","id":"s112"}}]}"#,
             planAfter: nil),
        Case(input: "where can I get tacos?", ctx: AssistantFixture.ctx(), intent: .question,
             json: #"{"blocks":[{"type":"text","text":"Ask needs on-device AI, which isn't available on this phone. Here's what matches."},{"type":"place_card","id":"l6","show":["image","distance","now_next","like","actions"]},{"type":"item_card","id":"s107","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"location","id":"l6"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l6"}},{"label":"Directions","action":"directions","params":{"location":"l6"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "show the map", ctx: AssistantFixture.ctx(), intent: .open,
             json: #"{"blocks":[{"type":"text","text":"Opening the map."}],"actions":[{"name":"open","params":{"screen":"map"}}]}"#,
             planAfter: nil),
        Case(input: "what's next on my plan", ctx: AssistantFixture.ctx(), intent: .planNext,
             json: #"{"blocks":[{"type":"text","text":"Next in your plan: **Juniper Lane**, in 1 h."},{"type":"item_card","id":"s109","show":["time","place","distance","like","actions"]},{"type":"countdown","id":"s109"},{"type":"chips","chips":[{"label":"Like","action":"like","params":{"kind":"schedule","id":"s109"}},{"label":"Show on map","action":"open","params":{"screen":"map","id":"l1"}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "add my plan to calendar", ctx: AssistantFixture.ctx(), intent: .calendar,
             json: #"{"blocks":[{"type":"text","text":"Attnd doesn't add things to your calendar."},{"type":"chips","chips":[{"label":"Share my plan","action":"share_plan","params":{}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "plan my sunday", ctx: AssistantFixture.ctx(), intent: .planMake,
             json: #"{"blocks":[{"type":"text","text":"Making your plan."}],"actions":[{"name":"plan_make","params":{"request":"plan my sunday"}}]}"#,
             planAfter: nil),
        Case(input: "liked", ctx: AssistantFixture.ctx(), intent: .liked,
             json: #"{"blocks":[{"type":"list","ids":["s101","s114"],"title":"Liked"}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "follow on lock screen", ctx: AssistantFixture.ctx(), intent: .toggle,
             json: #"{"blocks":[{"type":"confirm","action":"follow_lock_screen","params":{"on":true},"prompt":"Follow your day on the Lock Screen?"}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "turn off notifications", ctx: AssistantFixture.ctx(), intent: .toggle,
             json: #"{"blocks":[{"type":"confirm","action":"notifications","params":{"on":false},"prompt":"Turn off notifications from the organizer?"}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "chill version", ctx: AssistantFixture.ctx(), intent: .planVersion,
             json: #"{"blocks":[{"type":"text","text":"Chill: Removed DJ Lone Star."},{"type":"plan_diff","diff":{"removed":["s104"],"added":[],"moved":[],"meals_removed":[],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_version","params":{"kind":"chill"}}]}"#,
             planAfter: ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"]),
        Case(input: "remove juniper lane", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"Removed Juniper Lane. Added Brisket 101. No lunch break."},{"type":"plan_diff","diff":{"removed":["s109"],"added":["s106"],"moved":[],"meals_removed":["2026-11-14:lunch"],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"remove","item":"s109"}]}}]}"#,
             planAfter: ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"]),
        Case(input: "I'm tired", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"Removed DJ Lone Star."},{"type":"plan_diff","diff":{"removed":["s104"],"added":[],"moved":[],"meals_removed":[],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"constraint","pace":"relaxed"}]}}]}"#,
             planAfter: ["10:00 111", "11:00 109", "12:00 lunch", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101"]),
        Case(input: "how far am I walking", ctx: AssistantFixture.ctx(), intent: .walking,
             json: #"{"blocks":[{"type":"text","text":"0.8 mi walking today"},{"type":"summary","kind":"walking"},{"type":"map","pins":["l1","l2","l3"],"route":["l1","l2","l1","l2","l1","l3"]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "more bbq", ctx: AssistantFixture.ctx(), intent: .planEdit,
             json: #"{"blocks":[{"type":"text","text":"Removed Juniper Lane. Added Brisket 101. No lunch break."},{"type":"plan_diff","diff":{"removed":["s109"],"added":["s106"],"moved":[],"meals_removed":["2026-11-14:lunch"],"meals_added":[],"meals_moved":[]}},{"type":"chips","chips":[{"label":"Undo","action":"plan_undo","params":{}},{"label":"Show my plan","action":"plan","params":{}}]}],"actions":[{"name":"plan_edit","params":{"ops":[{"op":"constraint","more_tag":"bbq"}]}}]}"#,
             planAfter: ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "17:00 105", "18:15 113", "19:00 101", "21:00 104"]),
        Case(input: "why isn't brisket 101 in my plan", ctx: AssistantFixture.ctx(), intent: .whyNot,
             json: #"{"blocks":[{"type":"text","text":"There isn't time to walk between Brisket 101 and Juniper Lane."},{"type":"item_card","id":"s106","show":["time","place","distance","like","actions"]},{"type":"chips","chips":[{"label":"Swap it in","action":"plan_edit","params":{"ops":[{"op":"add","item":"s106"}]}}]}],"actions":[]}"#,
             planAfter: nil),
        Case(input: "compare versions", ctx: AssistantFixture.ctx(), intent: .planCompare,
             json: #"{"blocks":[{"type":"compare","a":"plan:chill","b":"plan:everything"}],"actions":[]}"#,
             planAfter: nil),    ]

    func testRouterOutputs() {
        XCTAssertEqual(cases.count, 32)
        for c in cases {
            let routed = AssistantRouter.route(c.input, c.ctx)
            XCTAssertEqual(routed.intent, c.intent, c.input)
            XCTAssertEqual(BlockJSON.encode(routed.turn).encoded, c.json, c.input)
            XCTAssertEqual(routed.edit.map { AssistantFixture.clock($0.after) }, c.planAfter, c.input)
        }
    }

    func testSpecCasesInWords() {
        let ctx = AssistantFixture.ctx()
        // "tacos" → the place card for Taco Row (places lead), then the item, then chips.
        XCTAssertEqual(AssistantRouter.route("tacos", ctx).blocks.map(\.type), ["place_card", "item_card", "chips"])
        // "I already ate" → no_food_until now + 3 h (1:00 PM) and the lunch break gone.
        let ate = AssistantRouter.route("I already ate", ctx)
        XCTAssertEqual(ate.actions.single?.params.encoded, #"{"ops":[{"op":"constraint","no_food_until":"2026-11-14T19:00:00Z"}]}"#)
        XCTAssertEqual(ate.edit?.diff.mealsRemoved.map(\.encoded), ["2026-11-14:lunch"])
        // "done by 9" at 10 AM → 21:00; "done by 11" → 11:00; "home by 9:30pm" → 21:30.
        XCTAssertEqual(AssistantRouter.route("done by 9", ctx).actions.single?.params.encoded, #"{"ops":[{"op":"constraint","done_by":"21:00"}]}"#)
        XCTAssertEqual(AssistantRouter.route("done by 11", ctx).actions.single?.params.encoded, #"{"ops":[{"op":"constraint","done_by":"11:00"}]}"#)
        XCTAssertEqual(AssistantRouter.route("home by 9:30pm", ctx).actions.single?.params.encoded, #"{"ops":[{"op":"constraint","done_by":"21:30"}]}"#)
    }

    func testEntityResolution() {
        let ctx = AssistantFixture.ctx()
        func s(_ id: Int) -> EntityRef { EntityRef(kind: .schedule, id: id) }
        func l(_ id: Int) -> EntityRef { EntityRef(kind: .location, id: id) }
        XCTAssertEqual(AssistantRouter.resolve("the prairie lights", [.schedule], ctx), .found(s(101)))
        XCTAssertEqual(AssistantRouter.resolve("the 3pm thing", [.schedule], ctx, preferPlanned: true), .found(s(103)))
        XCTAssertEqual(AssistantRouter.resolve("taco row", [.location], ctx), .found(l(6)))
        XCTAssertEqual(AssistantRouter.resolve("stage", [.location], ctx), .ambiguous([l(1), l(2)]))
        XCTAssertEqual(AssistantRouter.resolve("xqzv", [.schedule], ctx), .notFound)
        XCTAssertEqual(AssistantRouter.resolve("the", [.schedule], ctx), .notFound)
    }
}

extension Array {
    /// Kotlin `single()`: the only element, nil otherwise.
    var single: Element? { count == 1 ? first : nil }
}
