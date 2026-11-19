// PlanPageTests.swift
// AttndTests
//
// The plan page's rules (PlanPage.swift; iOS only for now) on `AssistantFixture`: now Sat
// 10:00 AM, plan 10:00 111 · 11:00 109 · 12:00 lunch · 13:00 102 · 15:00 103 · 17:00 105 ·
// 18:15 113 · 19:00 101 · 21:00 104; likes 101, 114.

import XCTest
@testable import Attnd

final class PlanPageTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private let plan = AssistantFixture.plan
    private let likes = AssistantFixture.likes
    private let now = PlannerFixture.now
    private let enUS = AssistantFixture.enUS
    private var saturday: PlanDate { PlanDate(now, in: PlanCalendar.calendar(PlannerFixture.chicago)) }

    private func model(_ plan: Plan?, preview: PlanPreview? = nil, now: Date? = nil) -> PlanPageModel {
        PlanPage.model(plan: plan, bundle, likes: likes, now: now ?? self.now, preview: preview, locale: enUS)
    }

    // MARK: Rows and chips

    func testRowsOfOneDay() {
        let page = model(plan)
        XCTAssertEqual(page.days.count, 1)
        XCTAssertEqual(page.days[0].itemCount, 8)
        XCTAssertEqual(page.days[0].countText, "8 items")
        XCTAssertEqual(page.rows.map(\.id), [
            "item-111", "gap-2026-11-14-0", "item-109", "meal-2026-11-14-lunch",
            "leg-102", "item-102", "gap-2026-11-14-3", "item-103", "gap-2026-11-14-4",
            "leg-105", "item-105", "leg-113", "item-113", "leg-101", "item-101",
            "gap-2026-11-14-7", "leg-104", "item-104",
        ])
        guard case .leg(let leg) = page.rows[4].kind else { return XCTFail("expected a leg") }
        XCTAssertEqual(leg.title, "Main Stage → Trinity Stage")
        XCTAssertEqual(leg.detail, "about 4 min walk · 0.2 mi")
        guard case .gap(let gap) = page.rows[6].kind else { return XCTFail("expected a gap") }
        XCTAssertEqual(gap.minutes, 60)
        XCTAssertEqual(gap.afterItem, 102)
        XCTAssertEqual(gap.text, "1 h free", "nothing fits 14:00–15:00 with the 5 min buffer")
    }

    func testPartChipsAnchorTheFirstRowOfEachPart() {
        let page = model(plan)
        XCTAssertEqual(page.chips.map(\.label), ["Morning", "Afternoon", "Evening"])
        XCTAssertEqual(page.chips.map(\.anchor), ["item-111", "meal-2026-11-14-lunch", "leg-105"])
        XCTAssertEqual(page.chip(for: "item-103"), "part-afternoon")
        XCTAssertEqual(page.chip(for: "item-104"), "part-evening")
        XCTAssertEqual(page.chip(for: nil), "part-morning")
        XCTAssertEqual(page.chip(for: "day-2026-11-14"), "part-morning", "the day header is under its first row's chip")
    }

    func testDayChipsForAPlanOverDays() {
        let sunday = saturday.adding(days: 1)
        let twoDays = Planner(bundle: bundle, preferences: PlanPreferences(likedTags: ["live music"], days: [saturday, sunday]),
                              heartedItems: likes.scheduleItems).plan(from: now, request: "Both days")
        let page = model(twoDays)
        XCTAssertEqual(page.days.map(\.date), [saturday, sunday])
        XCTAssertEqual(page.chips.map(\.label), ["1 Sat", "2 Sun"])
        XCTAssertEqual(page.chips.map(\.anchor), ["day-2026-11-14", "day-2026-11-15"])
        XCTAssertTrue(page.days[1].rows.allSatisfy { $0.chip == "day-2026-11-15" })
        XCTAssertEqual(page.chip(for: page.days[1].rows.last?.id), "day-2026-11-15")
    }

    func testNoPlanNoRows() {
        let page = model(nil)
        XCTAssertTrue(page.days.isEmpty)
        XCTAssertTrue(page.chips.isEmpty)
    }

    func testPreviewMarksAndSuggestionsInPlace() {
        guard case .proposal(let p) = PlanPanel.addToPlan(112, AssistantFixture.ctx()) else { return XCTFail("expected a proposal") }
        let preview = PlanPreview.of(p, plan: plan, bundle)
        let page = model(plan, preview: preview)
        let marked = page.rows.compactMap { row -> Int? in
            if case .item(let item, .removed?) = row.kind { return item.itemId }
            return nil
        }
        XCTAssertTrue(marked.contains(113), "Beer tasting would replace Sundown Choir")
        XCTAssertEqual(Set(marked), Set(preview.marks.filter { $0.value == .removed }.map(\.key)), "every mark is on its row")
        let suggested = page.rows.compactMap { row -> Int? in
            if case .suggestion(let s) = row.kind { return s.itemId }
            return nil
        }
        XCTAssertTrue(suggested.contains(112))
        XCTAssertEqual(suggested.count, preview.suggestions.values.reduce(0) { $0 + $1.count }, "every suggestion has a row")
    }

    func testGapsAreOnlyAhead() {
        // At 15:30 the 10:00 and 14:00 gaps are over; 16:00–17:00 and 20:30–21:00 remain.
        let page = model(plan, now: PlannerFixture.sat("15:30"))
        XCTAssertEqual(page.rows.filter { if case .gap = $0.kind { return true }; return false }.map(\.id),
                       ["gap-2026-11-14-4", "gap-2026-11-14-7"])
        // A gap that started counts from now.
        let later = model(plan, now: PlannerFixture.sat("16:20"))
        let gap = later.rows.compactMap { row -> PlanPageGap? in if case .gap(let g) = row.kind { return g }; return nil }.first
        XCTAssertEqual(gap?.minutes, 40)
        XCTAssertEqual(gap?.text, "40 min free")
    }

    func testGapIdeas() throws {
        // Without Big Sky Radio (15:00) there are 3 hours free after Ana Morales Trio.
        var shorter = plan
        shorter.days[0].entries.removeAll { if case .item(let p) = $0 { return p.itemId == 103 }; return false }
        let page = model(shorter)
        let gap = try XCTUnwrap(page.rows.compactMap { row -> PlanPageGap? in
            if case .gap(let g) = row.kind, g.afterItem == 102 { return g }
            return nil
        }.first)
        XCTAssertEqual(gap.minutes, 180)
        XCTAssertEqual(gap.ideas, [103, 107], "best score first; Kolache (16:15–17:00) leaves no time for Velvet Mesquite")
        XCTAssertEqual(gap.text, "3 h free · 2 ideas nearby")
    }

    // MARK: Change options

    func testChangeOptions() {
        let options = PlanPage.changeOptions(105, plan, bundle, likes, now: now)
        XCTAssertEqual(options.map(\.itemId), [110])
        XCTAssertEqual(options.first?.isAlternative, true)
        XCTAssertEqual(options.first?.reason, "Fits your day")
        XCTAssertEqual(options.first?.timeText, "45 min earlier")
        XCTAssertEqual(options.first?.walkText, "4 min less walking")
        let lunchSlot = PlanPage.changeOptions(103, plan, bundle, likes, now: now)
        XCTAssertEqual(lunchSlot.map(\.itemId), [107])
        XCTAssertEqual(lunchSlot.first?.walkText, "Same walk")
        // Without coordinates (Gates open has no place) the walk difference is unknown.
        let juniper = PlanPage.changeOptions(109, plan, bundle, likes, now: now)
        XCTAssertEqual(juniper.map(\.itemId), [106])
        XCTAssertEqual(juniper.first?.timeText, "1 h later")
        XCTAssertNil(juniper.first?.walkText)
        XCTAssertEqual(PlanPage.changeOptions(999, plan, bundle, likes, now: now), [])
    }

    func testChangeOptionsSkipStartedItems() {
        // At 16:30 Kolache masterclass (16:15) has started.
        XCTAssertEqual(PlanPage.changeOptions(105, plan, bundle, likes, now: PlannerFixture.sat("16:30")), [])
    }

    func testDeltaTexts() {
        XCTAssertEqual(PlanPage.deltaText(0, same: "Same time", more: "later", less: "earlier"), "Same time")
        XCTAssertEqual(PlanPage.deltaText(75, same: "Same time", more: "later", less: "earlier"), "1 h 15 min later")
        XCTAssertEqual(PlanPage.deltaText(-120, same: "Same time", more: "later", less: "earlier"), "2 h earlier")
    }

    func testLegOptions() throws {
        let route = try XCTUnwrap(DayRoutes.of(plan, bundle))
        let leg = try XCTUnwrap(route.legs.first { $0.toItem == 105 })
        let options = PlanPage.legOptions(leg, plan, bundle, likes, now: now)
        XCTAssertEqual(options.closer.map(\.itemId), [110], "Chef Demo Kitchen is 2 min from Trinity Stage, Main Stage 4")
        XCTAssertEqual(options.leaveEarlier.map(\.itemId), [107], "Street tacos ends at 15:00, Big Sky Radio at 16:00")
        // Leave Trinity Stage by 17:00 − 4 min walk − 5 min.
        XCTAssertEqual(options.leaveBy, PlannerFixture.sat("16:51"))
    }

    func testMealOptions() throws {
        let lunch = try XCTUnwrap(plan.days[0].meals.first)
        let options = PlanPage.mealOptions(lunch, plan, bundle, likes, now: now)
        XCTAssertEqual(options.foodItems, [], "Brisket 101 (12:00) clashes with the plan")
        XCTAssertEqual(options.places.map(\.locationId), [4, 6, 5], "by walk from Main Stage, then id")
        XCTAssertEqual(options.places.map(\.walkMinutes), [2, 2, 3])
    }

    func testRemoveOffersToFillTheGap() throws {
        let ctx = AssistantFixture.ctx()
        let proposal = try XCTUnwrap(PlanProposals.from(action: .planEdit([.remove(item: 103)], bundle), label: "Remove Big Sky Radio", ctx))
        let removal = try XCTUnwrap(PlanPage.removal(proposal, bundle, now: now))
        XCTAssertEqual(removal.itemId, 103)
        let ideas = PlanPage.fillIdeas(removal.edit, removed: 103, bundle, likes, now: now)
        XCTAssertFalse(ideas.contains(103), "never the removed item itself")
        XCTAssertLessThanOrEqual(ideas.count, 3)
        // A swap isn't a removal.
        let swap = try XCTUnwrap(PlanProposals.from(action: .planEdit([.replace(item: 105, with: 110)], bundle), ctx))
        XCTAssertNil(PlanPage.removal(swap, bundle, now: now))
    }

    // MARK: Bottom bar, titles

    func testStats() {
        let stats = PlanPage.stats(plan, bundle)
        XCTAssertEqual(stats.items, 8)
        XCTAssertEqual(stats.days, 1)
        XCTAssertEqual(stats.text(zone: PlannerFixture.chicago, units: .imperial, locale: enUS), "8 items · 10 AM – 11 PM · 0.8 mi walking")
        XCTAssertEqual(stats.text(zone: PlannerFixture.chicago, units: .metric, locale: enUS), "8 items · 10 AM – 11 PM · 1.3 km walking")
        let none = PlanPageStats(items: 1, days: 1, first: PlannerFixture.sat("10:30"), last: PlannerFixture.sat("11:00"), walkedMeters: 0)
        XCTAssertEqual(none.text(zone: PlannerFixture.chicago, units: .imperial, locale: enUS), "1 item · 10:30 AM – 11 AM")
        let days = PlanPageStats(items: 5, days: 2, first: nil, last: nil, walkedMeters: 0)
        XCTAssertEqual(days.text(zone: PlannerFixture.chicago, units: .imperial, locale: enUS), "5 items over 2 days")
    }

    func testDayTitleAndSummaryFallback() {
        XCTAssertEqual(PlanPage.dayTitle(saturday, locale: enUS), "Saturday, Nov 14")
        XCTAssertEqual(PlanPage.fallbackSummary(plan, saturday, timeZone: PlannerFixture.chicago, locale: enUS),
                       "8 items, 10:00 AM – 11:00 PM, with a lunch break")
    }

    func testSummaryKeyFollowsTheDaysEntries() {
        let key = PlanPage.summaryKey(plan, saturday)
        XCTAssertEqual(key, PlanPage.summaryKey(plan, saturday))
        var changed = plan
        changed.days[0].entries.removeLast()
        XCTAssertNotEqual(key, PlanPage.summaryKey(changed, saturday))
        var checked = plan
        checked.checkedOff = [111]
        XCTAssertEqual(key, PlanPage.summaryKey(checked, saturday), "a check-off doesn't change the day")
        XCTAssertTrue(key.hasPrefix("\(plan.eventId):2026-11-14:s111@"))
    }

    func testSummaryPrompt() {
        let prompt = PlanPage.summaryPrompt(plan, saturday, bundle, forecast: "Sat Nov 14: 72°F / 58°F, sunny", locale: enUS)
        let lines = prompt.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), [
            "EVENT: \(bundle.event.name)", "DAY: Saturday, Nov 14", "WEATHER: Sat Nov 14: 72°F / 58°F, sunny", "PLAN:",
        ])
        XCTAssertEqual(lines[4], "- 10:00 AM Gates open at General (general, free)")
        XCTAssertTrue(lines.contains("- 12:00 PM Lunch break near Main Stage") || lines.contains { $0.hasPrefix("- 12:00 PM Lunch") })
    }

    // MARK: Weather

    private func forecast(fetchedAt: Date) -> PlanForecast {
        PlanForecast(
            eventId: 1, fetchedAt: fetchedAt, latitude: 32.75, longitude: -97.33,
            days: [
                PlanDayForecast(date: "2026-11-14", high: 22.2, low: 14.4, precipitationChance: 0.4, symbol: "cloud.sun.rain", condition: "Scattered Showers"),
                PlanDayForecast(date: "2026-11-15", high: 18, low: 9.6, precipitationChance: 0.1, symbol: "sun.max", condition: "Sunny"),
            ],
            hours: [
                PlanHourForecast(date: PlannerFixture.sat("06:00"), temperature: 15, precipitationChance: 0.6, symbol: "cloud.rain"),
                PlanHourForecast(date: PlannerFixture.sat("14:00"), temperature: 21, precipitationChance: 0.2, symbol: "cloud"),
                PlanHourForecast(date: PlannerFixture.sat("15:00"), temperature: 21, precipitationChance: 0.45, symbol: "cloud.rain"),
            ]
        )
    }

    func testWeatherChipAndSpokenText() {
        let f = forecast(fetchedAt: now)
        XCTAssertEqual(PlanWeather.chipText(f.days[0], fahrenheit: true), "72°/58° · 40%")
        XCTAssertEqual(PlanWeather.chipText(f.days[0], fahrenheit: false), "22°/14° · 40%")
        XCTAssertEqual(PlanWeather.chipText(f.days[1], fahrenheit: true), "64°/49°", "rain below 30 % isn't shown")
        XCTAssertEqual(PlanWeather.spokenText(f.days[0], fahrenheit: true), "Scattered Showers, high 72°, low 58°, 40% chance of rain")
        XCTAssertEqual(f.day(saturday)?.condition, "Scattered Showers")
        XCTAssertNil(f.day(saturday.adding(days: 5)), "only days in the forecast's range")
    }

    func testWeatherPromptLines() {
        let f = forecast(fetchedAt: now)
        XCTAssertEqual(PlanWeather.rainStart(f, saturday, zone: PlannerFixture.chicago, locale: enUS), "after 3 PM", "the 6 AM shower is before 8")
        XCTAssertEqual(PlanWeather.promptLines(f, days: [saturday, saturday.adding(days: 1), saturday.adding(days: 2)],
                                               zone: PlannerFixture.chicago, fahrenheit: true, locale: enUS), [
            "Sat Nov 14: 72°F / 58°F, scattered showers, 40% rain after 3 PM",
            "Sun Nov 15: 64°F / 49°F, sunny",
        ])
        XCTAssertEqual(PlanWeather.promptLines(nil, days: [saturday], zone: PlannerFixture.chicago, fahrenheit: true, locale: enUS), [])
    }

    func testWeatherFetchRuleAndAsOf() {
        let point = Coordinate(latitude: 32.75, longitude: -97.33)
        XCTAssertTrue(PlanWeather.needsFetch(nil, at: point, now: now))
        XCTAssertFalse(PlanWeather.needsFetch(forecast(fetchedAt: now.addingTimeInterval(-1800)), at: point, now: now))
        XCTAssertTrue(PlanWeather.needsFetch(forecast(fetchedAt: now.addingTimeInterval(-3600)), at: point, now: now))
        XCTAssertTrue(PlanWeather.needsFetch(forecast(fetchedAt: now), at: Coordinate(latitude: 33.0, longitude: -97.33), now: now))
        XCTAssertTrue(PlanWeather.needsFetch(forecast(fetchedAt: now.addingTimeInterval(600)), at: point, now: now), "a clock change")
        let zone = PlannerFixture.chicago
        XCTAssertEqual(PlanWeather.asOfText(PlannerFixture.sat("14:14"), now: PlannerFixture.sat("16:00"), zone: zone, locale: enUS), "as of 2:14 PM")
        XCTAssertEqual(PlanWeather.asOfText(PlannerFixture.sat("14:14"), now: PlannerFixture.sun("09:00"), zone: zone, locale: enUS), "as of Sat 2:14 PM")
    }

    func testWeatherCoordinate() {
        XCTAssertNotNil(PlanWeather.coordinate(bundle))
        var noEvent = bundle
        noEvent.event.latitude = nil
        noEvent.event.longitude = nil
        let centre = PlanWeather.coordinate(noEvent)
        let points = bundle.locations.compactMap(\.coordinate)
        XCTAssertEqual(centre?.latitude ?? 0, points.map(\.latitude).reduce(0, +) / Double(points.count), accuracy: 1e-9)
        noEvent.locations = []
        XCTAssertNil(PlanWeather.coordinate(noEvent))
    }

    func testForecastCodecRoundTrip() {
        let f = forecast(fetchedAt: Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(PlanForecast.decode(f.encoded()), f)
        XCTAssertNil(PlanForecast.decode(Data("{}".utf8)))
        XCTAssertNil(PlanForecast.decode(nil))
    }
}
