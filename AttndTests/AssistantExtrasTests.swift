// AssistantExtrasTests.swift
// AttndTests
//
// Assistant spec §5–7 (Android's `unit/AssistantExtrasTest.kt`, same cases): day routes, live
// rules, share links (API-015), group plans, why-not.

import XCTest
@testable import Attnd

final class AssistantExtrasTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let now = PlannerFixture.now
    private let plan = AssistantFixture.plan
    private let likes = AssistantFixture.likes
    private let enUS = AssistantFixture.enUS
    private let saturday = PlanDate(year: 2026, month: 11, day: 14)
    private var panther: Coordinate { bundle.location(3)!.coordinate! }
    private var mainStage: Coordinate { bundle.location(1)!.coordinate! }
    private func at(_ minutes: Int) -> Date { now.addingTimeInterval(TimeInterval(minutes * 60)) }
    private func b64(_ json: String) -> String { Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
    private func lastSegment(_ link: String) -> String { String(link.split(separator: "/").last ?? "") }

    // MARK: Share (API-015)

    func testShareCodecMatchesTheServer() {
        XCTAssertEqual(PlanShare.json([101, 114], day: saturday), #"{"v":1,"ids":[101,114],"d":"2026-11-14"}"#)
        XCTAssertEqual(PlanShare.payload([101, 114], day: saturday), "eyJ2IjoxLCJpZHMiOlsxMDEsMTE0XSwiZCI6IjIwMjYtMTEtMTQifQ")
        XCTAssertEqual(PlanShare.decode("eyJ2IjoxLCJpZHMiOlsxMDEsMTE0XSwiZCI6IjIwMjYtMTEtMTQifQ"), SharedPayload(version: 1, ids: [101, 114], day: saturday))
        XCTAssertEqual(PlanShare.json([101], day: nil), #"{"v":1,"ids":[101]}"#)
        XCTAssertEqual(PlanShare.planLink(plan, bundle),
                       "https://attnd.app/p/DEMO/eyJ2IjoxLCJpZHMiOlsxMTEsMTA5LDEwMiwxMDMsMTA1LDExMywxMDEsMTA0XSwiZCI6IjIwMjYtMTEtMTQifQ")
        XCTAssertEqual(PlanShare.decode(lastSegment(PlanShare.planLink(plan, bundle))),
                       SharedPayload(version: 1, ids: [111, 109, 102, 103, 105, 113, 101, 104], day: saturday))
        XCTAssertEqual(PlanShare.decode(lastSegment(PlanShare.itemLink(101, bundle))), SharedPayload(version: 1, ids: [101], day: nil))
        // The app's own link checker accepts the payload (Components/ShareCard.swift alphabet rules).
        XCTAssertTrue(PlanShare.payload([101, 114], day: saturday).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    func testShareDecodingIsLenient() {
        XCTAssertEqual(PlanShare.decode("eyJ2IjoxLCJpZHMiOlsxMDEsMTE0XSwiZCI6IjIwMjYtMTEtMTQifQ=="), SharedPayload(version: 1, ids: [101, 114], day: saturday))
        XCTAssertEqual(PlanShare.decode(b64(#"{"v":1,"ids":["s101",114,"l3"],"d":"Saturday","x":true}"#)), SharedPayload(version: 1, ids: [101, 114], day: nil))
        XCTAssertEqual(PlanShare.decode(b64(#"{"v":2,"plan":{}}"#)), SharedPayload(version: 2, ids: [], day: nil))
        XCTAssertEqual(PlanShare.decode(b64(#"{"v":2}"#))?.isReadable, false)
        XCTAssertNil(PlanShare.decode(b64(#"{"v":1,"ids":"101"}"#)))
        XCTAssertNil(PlanShare.decode(b64(#"{"ids":[101]}"#)))
        XCTAssertNil(PlanShare.decode("not base64 json!"))
        XCTAssertNil(PlanShare.decode(String(repeating: "A", count: 1600)))
        XCTAssertEqual(PlanShare.resolve(SharedPayload(version: 1, ids: [101, 999], day: nil), bundle), [101])
        let long = PlanShare.payload(Array(1...1000))
        XCTAssertLessThanOrEqual(long.count, PlanShare.maxPayload)
        let ids = PlanShare.decode(long)?.ids ?? []
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(ids, Array(1...ids.count))
    }

    func testShareLinks() {
        let payload = "eyJ2IjoxLCJpZHMiOlsxMDEsMTE0XSwiZCI6IjIwMjYtMTEtMTQifQ"
        func parse(_ raw: String?) -> [String]? { PlanShare.parseLink(raw).map { [$0.eventCode, $0.payload] } }
        XCTAssertEqual(parse("https://attnd.app/p/DEMO/\(payload)"), ["DEMO", payload])
        XCTAssertEqual(parse("https://www.attnd.app/p/DEMO/\(payload)/?utm=x#top"), ["DEMO", payload])
        XCTAssertEqual(parse("attnd.app/p/FW%2026/\(payload)"), ["FW 26", payload])
        XCTAssertNil(parse("https://attnd.app/p/DEMO/\(payload)/qr.svg"))
        XCTAssertNil(parse("https://attnd.app/p/DEMO/"))
        XCTAssertNil(parse("https://example.com/p/DEMO/\(payload)"))
        XCTAssertEqual(parse("https://dev.attnd.app/p/DEMO/\(payload)"), ["DEMO", payload])
        XCTAssertEqual(PlanShare.link("DEMO", [101], host: "dev.attnd.app"), "https://dev.attnd.app/p/DEMO/eyJ2IjoxLCJpZHMiOlsxMDFdfQ")
        XCTAssertNil(parse("https://attnd.app/join/DEMO/"))
        XCTAssertNil(parse(nil))
    }

    func testGroupPlan() {
        let merged = GroupPlan.merge([[103, 114], [114, 110, 999]], likes, bundle)
        XCTAssertEqual(merged.likes.scheduleItems, [101, 103, 110, 114])
        XCTAssertEqual(merged.counts, [101: 1, 103: 1, 110: 1, 114: 3])
        let group = GroupPlan.plan([[103, 114], [114, 110]], likes, bundle, AssistantFixture.musicAndBbq, now: now)
        XCTAssertEqual(AssistantFixture.clock(group), ["10:00 111", "12:00 106", "13:00 102", "15:00 103", "16:15 110", "18:15 113", "18:45 dinner", "20:00 114"])
        XCTAssertEqual(group.items.first { $0.itemId == 114 }?.reason, "Picked by 3 of you")
        XCTAssertEqual(group.items.first { $0.itemId == 103 }?.reason, "In your schedule")
    }

    // MARK: Why not

    func testWhyNot() {
        func why(_ id: Int, _ p: Plan?? = .none, at: Date? = nil) -> String? {
            let chosen: Plan? = p ?? plan
            return WhyNot.explain(id, chosen, bundle, likes, now: at ?? now, locale: enUS)?.text
        }
        XCTAssertEqual(why(114), "Neon Armadillo clashes with The Prairie Lights (in your schedule).")
        XCTAssertEqual(why(106), "There isn't time to walk between Brisket 101 and Juniper Lane.")
        XCTAssertEqual(why(201), "Los Hermanos Flores is on Sunday, and your plan covers Saturday.")
        XCTAssertEqual(why(111), "Gates open is already in your plan.")
        XCTAssertEqual(why(114, .some(nil)), "You don't have a plan yet.")
        var withoutJuniper = plan
        withoutJuniper.days = plan.days.map { day in
            var d = day
            d.entries = day.entries.filter { if case .item(let i) = $0 { return i.itemId != 109 } else { return true } }
            return d
        }
        XCTAssertEqual(why(109, withoutJuniper, at: at(180)), "Juniper Lane has ended.")
        XCTAssertEqual(why(109, withoutJuniper, at: at(70)), "Juniper Lane has already started.")
        let removed = PlanEditor.preview(plan, [.remove(item: 109)], bundle, likes, now: now).after
        XCTAssertEqual(why(109, removed), "You took Juniper Lane out of your plan.")
        let doneBy = PlanEditor.preview(plan, [.doneBy(PlanClock(hour: 21, minute: 0))], bundle, likes, now: now).after
        XCTAssertEqual(why(104, doneBy), "DJ Lone Star is outside your plan's hours (10:00 AM – 9:00 PM).")
        let kids = Planner(bundle: bundle, preferences: PlanPreferences(kidFriendly: true)).plan(from: now, request: "")
        XCTAssertEqual(WhyNot.explain(112, kids, bundle, .none, now: now, locale: enUS)?.text, "Beer tasting is 21+, and you asked for kid-friendly.")
        let ate = PlanEditor.preview(plan, [.noFoodUntil(PlannerFixture.date("2026-11-14T19:00:00Z"))], bundle, likes, now: now).after
        XCTAssertEqual(why(106, ate), "You said you already ate, so food waits until 1:00 PM.")
        let chip = WhyNot.explain(114, plan, bundle, likes, now: now, locale: enUS).flatMap { WhyNot.chip($0, bundle) }
        XCTAssertEqual(chip?.label, "Swap it in")
        XCTAssertEqual(chip?.action, .planEdit([.add(item: 114)], bundle))
        // Swapping it in pins it ahead of the liked item it clashes with.
        let swapped = PlanEditor.preview(plan, [.add(item: 114)], bundle, likes, now: now).after
        XCTAssertTrue(swapped.itemIds.contains(114))
        XCTAssertFalse(swapped.itemIds.contains(101))
        XCTAssertEqual(swapped.items.first { $0.itemId == 114 }?.orInstead, [101])
    }

    // MARK: Day route

    func testDayRoute() {
        guard let route = DayRoutes.of(plan, bundle) else { return XCTFail("route") }
        XCTAssertEqual(route.stops.map { "\($0.number):\($0.locationId)\($0.itemIds)" }, ["1:1[109]", "2:2[102, 103]", "3:1[105]", "4:2[113]", "5:1[101]", "6:3[104]"])
        XCTAssertEqual(route.legs.map { [$0.fromItem, $0.toItem] }, [[109, 102], [103, 105], [105, 113], [113, 101], [101, 104]])
        XCTAssertEqual(route.legs.map { DayRoutes.legText($0, .imperial, locale: enUS) }, Array(repeating: "about 4 min walk · 0.2 mi", count: 5))
        XCTAssertEqual(DayRoutes.totalText(route, today: saturday, .imperial, locale: enUS), "0.8 mi walking today")
        XCTAssertEqual(DayRoutes.totalText(route, today: saturday.adding(days: 1), .metric, locale: enUS), "1.3 km walking on Saturday")
        XCTAssertEqual(DayRoutes.waypoints(route)?.count, 6)
        // Service legs: plausible ones replace the estimate, a route > 2.5× the straight line doesn't.
        let upgraded = DayRoutes.withServiceLegs(route, [
            LegRoute(distanceMeters: 300, durationSeconds: 240, points: [mainStage, panther], isEstimate: false),
            LegRoute(distanceMeters: 5000, durationSeconds: 3600, points: [], isEstimate: false),
            nil,
        ])
        XCTAssertEqual(DayRoutes.legText(upgraded.legs[0], .imperial, locale: enUS), "4 min walk · 0.2 mi")
        XCTAssertTrue(upgraded.legs[1].route.isEstimate)
        XCTAssertEqual(Array(upgraded.legs.dropFirst()), Array(route.legs.dropFirst()))
        // Only checked-off items (the recap).
        XCTAssertEqual(DayRoutes.of(plan, bundle, only: [109, 102, 103])?.stops.map(\.locationId), [1, 2])
        XCTAssertNil(DayRoutes.of(plan, bundle, date: saturday.adding(days: 1)))
    }

    // MARK: Live rules

    func testRunningLate() {
        // Juniper Lane starts at 11:00 on the Main Stage, 4 min from the pavilion: leave by 10:51.
        XCTAssertNil(LiveAssist.runningLate(plan, bundle, now: at(40), user: panther))
        let leave = LiveAssist.runningLate(plan, bundle, now: at(53), user: panther)
        XCTAssertEqual(leave?.state, .leaveNow)
        XCTAssertEqual(leave?.leaveBy, PlannerFixture.date("2026-11-14T16:51:00Z"))
        XCTAssertEqual(leave?.text, "Leave now for Juniper Lane · 4 min walk")
        XCTAssertEqual(leave?.chips.map(\.label), ["Directions"])
        let late = LiveAssist.runningLate(plan, bundle, now: at(58), user: panther)
        XCTAssertEqual(late?.state, .cantMakeIt)
        XCTAssertEqual(late?.text, "You can't make Juniper Lane in time · 4 min walk")
        XCTAssertEqual(late?.chips.map(\.label), ["Swap for Brisket 101", "Remove Juniper Lane"])
        XCTAssertEqual(late?.chips.first?.action, .planEdit([.replace(item: 109, with: 106)], bundle))
        XCTAssertNil(LiveAssist.runningLate(plan, bundle, now: at(58), user: mainStage)) // already there
        XCTAssertNil(LiveAssist.runningLate(plan, bundle, now: at(58), user: nil))
        XCTAssertNil(LiveAssist.runningLate(plan, bundle, now: at(58), user: Coordinate(latitude: 30.2672, longitude: -97.7431))) // Austin
    }

    func testCheckOffAndSkipped() {
        let juniper = bundle.scheduleItem(109)!
        func sample(_ point: Coordinate, _ minute: Int) -> LocationSample {
            LocationSample(point: point, at: PlannerFixture.sat("11:00").addingTimeInterval(TimeInterval(minute * 60)))
        }
        let near = Coordinate(latitude: mainStage.latitude + 0.0005, longitude: mainStage.longitude) // ~55 m
        XCTAssertTrue(LiveAssist.autoCheck(juniper, bundle, samples: [sample(near, 5), sample(mainStage, 10), sample(near, 15)]))
        XCTAssertFalse(LiveAssist.autoCheck(juniper, bundle, samples: [sample(near, 5), sample(near, 12)]))
        XCTAssertFalse(LiveAssist.autoCheck(juniper, bundle, samples: [sample(near, 5), sample(panther, 9), sample(near, 15)]))
        XCTAssertFalse(LiveAssist.autoCheck(juniper, bundle, samples: [sample(near, -20), sample(near, -5)])) // before it started
        XCTAssertEqual(LiveAssist.checkOffs(plan, bundle, samples: [sample(near, 5), sample(near, 20)], now: at(150)), [109])
        let elsewhere = [sample(panther, 10), sample(panther, 40)]
        XCTAssertEqual(LiveAssist.skipped(plan, bundle, samples: elsewhere, now: at(150)), [109])
        XCTAssertEqual(LiveAssist.skipped(plan, bundle, samples: [], now: at(150)), [])
        var checked = plan
        checked.checkedOff = [109]
        XCTAssertEqual(LiveAssist.skipped(checked, bundle, samples: elsewhere, now: at(150)), [])
        let chip = LiveAssist.skippedChip(109, bundle)
        XCTAssertEqual(chip?.label, "You skipped Juniper Lane — fill the gap?")
        XCTAssertEqual(chip?.action, .planEdit([.remove(item: 109)], bundle))
    }

    func testGapFillerAndLikeClash() {
        XCTAssertEqual(LiveAssist.gaps(plan, bundle, likes, now: now).map(\.text), [])
        let twoItems = Plan(
            eventId: 42, createdAt: now, request: "", preferences: PlanPreferences(),
            days: [PlanDay(date: saturday, windowStart: now, windowEnd: PlannerFixture.date("2026-11-15T06:00:00Z"), entries: [
                .item(PlannedItem(itemId: 103, start: PlannerFixture.sat("15:00"), end: PlannerFixture.sat("16:00"), reason: "", walkMinutes: nil, alternatives: [], orInstead: [])),
                .item(PlannedItem(itemId: 113, start: PlannerFixture.sat("18:15"), end: PlannerFixture.sat("18:45"), reason: "", walkMinutes: 0, alternatives: [], orInstead: [])),
            ])],
            fingerprints: [:]
        )
        let gaps = LiveAssist.gaps(twoItems, bundle, .none, now: now)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.text, "135 free minutes near Trinity Stage: Kolache masterclass is 2 min away")
        XCTAssertEqual(gaps.first?.itemId, 110)
        XCTAssertEqual(gaps.first?.chip.label, "Add Kolache masterclass")

        let clash = LiveAssist.likeClash(112, plan, bundle)
        XCTAssertEqual(clash?.label, "Add to plan instead of Sundown Choir?")
        XCTAssertEqual(clash?.action, .planEdit([.replace(item: 113, with: 112)], bundle))
        XCTAssertNil(LiveAssist.likeClash(101, plan, bundle))
        XCTAssertNil(LiveAssist.likeClash(201, plan, bundle))
    }

    func testRecapAndChanges() {
        var checked = plan
        checked.checkedOff = [109, 102, 103]
        let recap = LiveAssist.recap(checked, bundle, likes, date: saturday, now: at(420), units: .imperial, locale: enUS)
        XCTAssertEqual(recap.text, "You saw 3 things, added 2 and walked 0.2 mi.")
        XCTAssertEqual(recap.checkedOff, [109, 102, 103])
        XCTAssertEqual(recap.chips.map(\.label), ["Plan tomorrow"])
        XCTAssertEqual(recap.chips.first?.action, .planMake("Plan my Sunday"))
        var moved = bundle
        moved.schedule = bundle.schedule.compactMap { item in
            if item.id == 113 { return nil }
            var copy = item
            if item.id == 105 {
                copy.startTime = PlannerFixture.sat("20:30")
                copy.endTime = PlannerFixture.sat("21:30")
            }
            return copy
        }
        XCTAssertEqual(LiveAssist.changedItems(plan, moved), [105, 113])
    }
}
