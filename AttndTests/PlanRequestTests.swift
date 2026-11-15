// PlanRequestTests.swift
// AttndTests
//
// Shared spec §6–7 (the same cases as Android's `unit/PlanRequestTest.kt`): reading the model's
// preferences, the plain-rule reading, the merge, plan requests and example requests
// (PlanRequest.swift). Fixture: PlannerFixture.

import XCTest
@testable import Attnd

final class PlanRequestTests: XCTestCase {

    private var bundle: EventBundle { PlannerFixture.bundle }
    private var now: Date { PlannerFixture.now }
    private let saturday = PlanDate(year: 2026, month: 11, day: 14)
    private let sunday = PlanDate(year: 2026, month: 11, day: 15)

    func testParseValidatesEverythingAgainstTheBundle() throws {
        let raw = """
            Sure! {"liked_tags":["Live Music","bbq","opera"],"disliked_tags":["dj"],
            "liked_categories":["food","Rides"],"similar_to":[101,"S103",9999,"x"],"days":["2026-11-15","2026-12-01"],
            "earliest":"15:00","latest":"25:00","hours":2.5,"pace":"Packed","include_meals":true,"kid_friendly":"true","extra":1}
            Have fun.
            """
        let prefs = try XCTUnwrap(PlanRequest.parse(raw, bundle: bundle, now: now))
        XCTAssertEqual(prefs.likedTags, ["live music", "bbq"])
        XCTAssertEqual(prefs.dislikedTags, ["dj"])
        XCTAssertEqual(prefs.likedCategories, ["Food"])
        XCTAssertEqual(prefs.similarTo, [101, 103])
        XCTAssertEqual(prefs.days, [sunday])
        XCTAssertEqual(prefs.earliest, PlanClock(hour: 15, minute: 0))
        XCTAssertNil(prefs.latest)
        XCTAssertEqual(prefs.durationMinutes, 150)
        XCTAssertEqual(prefs.pace, .packed)
        XCTAssertTrue(prefs.includeMeals)
        XCTAssertTrue(prefs.kidFriendly)
    }

    func testParseRejectsWhatIsNotJson() {
        XCTAssertNil(PlanRequest.parse("I can't help with that.", bundle: bundle, now: now))
        XCTAssertNil(PlanRequest.parse("{broken", bundle: bundle, now: now))
        XCTAssertEqual(PlanRequest.parse("{}", bundle: bundle, now: now), PlanPreferences())
    }

    func testValidateReadsTheStructuredReplyTheSameWay() {
        // Foundation Models' @Generable reply goes through the same validation as JSON.
        var reply = PlanModelReply()
        reply.likedTags = ["Live Music", "opera"]
        reply.similarTo = ["101", "[s103]", "9999"]
        reply.days = ["2026-11-14", "2026-02-30"]
        reply.latest = "21:00"
        reply.hours = 30
        reply.pace = "relaxed"
        let prefs = PlanRequest.validate(reply, bundle: bundle, now: now)
        XCTAssertEqual(prefs.likedTags, ["live music"])
        XCTAssertEqual(prefs.similarTo, [101, 103])
        XCTAssertEqual(prefs.days, [saturday])
        XCTAssertEqual(prefs.latest, PlanClock(hour: 21, minute: 0))
        XCTAssertNil(prefs.durationMinutes)
        XCTAssertEqual(prefs.pace, .relaxed)
    }

    func testHeuristicReadsTheRequest() {
        let prefs = PlanRequest.heuristic("Plan my Saturday around live music and BBQ, no DJ please, after 3pm with dinner", bundle: bundle, now: now)
        XCTAssertEqual(prefs.likedTags, ["live music", "bbq"])
        XCTAssertEqual(prefs.dislikedTags, ["dj"])
        XCTAssertEqual(prefs.days, [saturday])
        XCTAssertEqual(prefs.earliest, PlanClock(hour: 15, minute: 0))
        XCTAssertTrue(prefs.includeMeals)
        XCTAssertFalse(prefs.kidFriendly)

        let short = PlanRequest.heuristic("I've got 3 hours, show me the highlights", bundle: bundle, now: now)
        XCTAssertEqual(short.durationMinutes, 180)
        XCTAssertEqual(short, PlanPreferences(durationMinutes: 180))

        let kids = PlanRequest.heuristic("Kid-friendly afternoon, nice and relaxed", bundle: bundle, now: now)
        XCTAssertTrue(kids.kidFriendly)
        XCTAssertEqual(kids.likedTags, ["kid-friendly"])
        XCTAssertEqual(kids.earliest, PlanClock(hour: 12, minute: 0))
        XCTAssertEqual(kids.latest, PlanClock(hour: 17, minute: 0))
        XCTAssertEqual(kids.pace, .relaxed)

        let named = PlanRequest.heuristic("More like Big Sky Radio tomorrow until 2", bundle: bundle, now: now)
        XCTAssertEqual(named.similarTo, [103])
        XCTAssertEqual(named.days, [sunday])
        XCTAssertEqual(named.latest, PlanClock(hour: 14, minute: 0))
    }

    func testMergeFillsWhatTheModelLeftOut() {
        let model = PlanPreferences(likedTags: ["country", "dj"], pace: .balanced)
        let rules = PlanPreferences(likedTags: ["bbq"], dislikedTags: ["dj"], days: [saturday], pace: .relaxed, includeMeals: true)
        let merged = PlanRequest.merge(model, rules)
        XCTAssertEqual(merged.likedTags, ["country", "bbq"])
        XCTAssertEqual(merged.dislikedTags, ["dj"])
        XCTAssertEqual(merged.days, [saturday])
        XCTAssertEqual(merged.pace, .relaxed)
        XCTAssertTrue(merged.includeMeals)
        XCTAssertEqual(PlanRequest.merge(nil, rules), rules)
    }

    func testPlanRequestsAreRecognised() {
        XCTAssertTrue(PlanRequest.looksLikePlan("Plan my Saturday around live music and BBQ"))
        XCTAssertTrue(PlanRequest.looksLikePlan("I've got 3 hours, show me the highlights"))
        XCTAssertTrue(PlanRequest.looksLikePlan("Kid-friendly afternoon"))
        XCTAssertTrue(PlanRequest.looksLikePlan("make an itinerary"))
        XCTAssertFalse(PlanRequest.looksLikePlan("What's on near me right now?"))
        XCTAssertFalse(PlanRequest.looksLikePlan("Where can I get coffee?"))
    }

    func testExamplesComeFromTheEvent() {
        XCTAssertEqual(PlanRequest.examples(bundle, now: now), [
            PlanExample(text: "Plan my Saturday around live music and food", isPlan: true),
            PlanExample(text: "I've got 3 hours, show me the highlights", isPlan: true),
            PlanExample(text: "Kid-friendly afternoon", isPlan: true),
            PlanExample(text: "What's on near me right now?", isPlan: false),
        ])
        var noFamily = bundle
        noFamily.schedule = bundle.schedule.filter { $0.id != 108 }
        XCTAssertFalse(PlanRequest.examples(noFamily, now: now).contains { $0.text == "Kid-friendly afternoon" })
    }

    func testPromptListsTheVocabularyAndTheRequest() {
        let prompt = PlanRequest.prompt(bundle, request: "Plan my Saturday", heartedItems: PlannerFixture.heartedItems, now: now)
        XCTAssertTrue(prompt.contains("DAYS: 2026-11-14 Saturday, 2026-11-15 Sunday"))
        XCTAssertTrue(prompt.contains("TAGS: live music, "))
        XCTAssertTrue(prompt.contains("CATEGORIES: Stage, Food, Family, Drinks, Services"))
        XCTAssertTrue(prompt.contains("HEARTED: 101 The Prairie Lights; 114 Neon Armadillo"))
        XCTAssertTrue(prompt.contains("NOW: Saturday 2026-11-14 10:00"))
        XCTAssertTrue(prompt.hasSuffix("REQUEST: Plan my Saturday\nJSON:"))
    }
}
