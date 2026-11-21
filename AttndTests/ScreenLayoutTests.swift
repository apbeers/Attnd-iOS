// ScreenLayoutTests.swift
// AttndTests
//
// API-024 server-driven screens: validation, fallbacks, overrides, conditions, facts and decoding
// (`ScreenLayout.swift`), on the planner fixture (DEMO-like festival, now Sat Nov 14 2026 10:00 AM
// America/Chicago). The same cases as attnd-web's `events/tests_layout.py` where they overlap.

import XCTest
@testable import Attnd

final class ScreenLayoutTests: XCTestCase {

    private let bundle = PlannerFixture.bundle
    private var state: ScreenFacts.State { ScreenFacts.State(now: PlannerFixture.now) }

    private func types(_ sections: [LayoutSection]) -> [String] { sections.map(\.type) }

    private func layouts(_ json: String) throws -> ScreenLayouts {
        try JSONDecoder().decode(ScreenLayouts.self, from: Data(json.utf8))
    }

    // MARK: Defaults (today's screens)

    func testDefaultsAreTodaysScreens() {
        XCTAssertEqual(types(ScreenLayout.sections(for: .itemDetail, layouts: nil)),
                       ["header", "about", "performers", "good_to_know", "links", "place_link"])
        XCTAssertEqual(types(ScreenLayout.sections(for: .placeDetail, layouts: nil)),
                       ["header", "walk_map", "about", "hours", "good_to_know", "menu", "links", "at_this_location"])
        XCTAssertEqual(types(ScreenLayout.sections(for: .eventInfo, layouts: nil)),
                       ["header", "about", "faq", "amenities", "getting_there", "accessibility", "policies", "weather_plan", "links"])
        XCTAssertEqual(types(ScreenLayout.sections(for: .optionsEvent, layouts: nil)), ["header", "website", "event_info_link"])
        XCTAssertEqual(types(ScreenLayout.sections(for: .mapOverlay, layouts: nil)), ["now_playing", "selected_place"])
        XCTAssertEqual(ScreenLayout.sections(for: .itemDetail, layouts: nil).first?.show, ["time", "status", "tags"])
    }

    func testEveryDefaultSectionIsInTheCatalogue() {
        for screen in LayoutScreen.allCases {
            let defaults = ScreenLayout.defaults[screen] ?? []
            XCTAssertFalse(defaults.isEmpty, "\(screen) has a default")
            XCTAssertEqual(ScreenLayout.validate(defaults, on: screen), defaults, "\(screen) defaults are valid as they are")
        }
    }

    func testItemDetailVisibilityFollowsTheData() {
        // Gates open: a description, no location, no context, no model.
        let gates = bundle.scheduleItem(111)!
        let facts = ScreenFacts.item(gates, bundle, state)
        XCTAssertEqual(types(ScreenLayout.resolve(.itemDetail, layouts: nil, facts: facts)), ["header", "about", "place_link"])
        // No Ask About This any more (Nov 21, 2026), with or without the model.
        var withModel = state
        withModel.modelAvailable = true
        let modelFacts = ScreenFacts.item(gates, bundle, withModel)
        XCTAssertEqual(types(ScreenLayout.resolve(.itemDetail, layouts: nil, facts: modelFacts)), ["header", "about", "place_link"])
        // Context parts.
        var item = bundle.scheduleItem(109)!
        item.context = ScheduleItemContext(performers: [Performer(name: "Juniper Lane")], price: "$5")
        XCTAssertEqual(types(ScreenLayout.resolve(.itemDetail, layouts: nil, facts: ScreenFacts.item(item, bundle, state))),
                       ["header", "performers", "good_to_know", "place_link"])
    }

    func testPlaceDetailVisibilityFollowsTheData() {
        let info = bundle.location(9)! // no coordinate, no items
        XCTAssertEqual(types(ScreenLayout.resolve(.placeDetail, layouts: nil, facts: ScreenFacts.place(info, bundle, state))), ["header"])
        let main = bundle.location(1)!
        XCTAssertEqual(types(ScreenLayout.resolve(.placeDetail, layouts: nil, facts: ScreenFacts.place(main, bundle, state))),
                       ["header", "walk_map", "at_this_location"])
    }

    // MARK: Validation and fallback

    func testValidationDropsUnknownDuplicatesAndCleans() {
        let raw = [
            LayoutSection("HEADER", show: ["tags", "sparkles", "tags"]),
            LayoutSection("hologram"),
            LayoutSection("about", title: "   "),
            LayoutSection("header"),
            LayoutSection("links", title: String(repeating: "x", count: 90), limit: 400),
        ]
        let kept = ScreenLayout.validate(raw, on: .itemDetail)
        XCTAssertEqual(types(kept), ["header", "about", "links"])
        XCTAssertEqual(kept[0].show, ["tags"])
        XCTAssertNil(kept[1].title)
        XCTAssertEqual(kept[2].title?.count, ScreenLayout.maxTitle)
        XCTAssertEqual(kept[2].limit, ScreenLayout.maxLimit)
        XCTAssertEqual(ScreenLayout.validate([LayoutSection("header", show: ["nope"])], on: .itemDetail)[0].show,
                       SectionCatalogue.itemHeaderParts, "no known part → the defaults")
        XCTAssertEqual(ScreenLayout.validate([LayoutSection("menu")], on: .itemDetail), [], "menu belongs to places")
    }

    func testAtMost24Sections() {
        let many = (0..<40).map { LayoutSection("type\($0)") } + ScreenLayout.defaults[.home]!
        XCTAssertEqual(ScreenLayout.validate(many, on: .home).count, ScreenLayout.defaults[.home]!.count)
        let all = SectionCatalogue.types[.home]!.keys.sorted().map { LayoutSection($0) }
        XCTAssertLessThanOrEqual(ScreenLayout.validate(all + all, on: .home).count, ScreenLayout.maxSections)
    }

    func testFallbackToDefaults() throws {
        let defaults = ScreenLayout.defaults[.itemDetail]!
        XCTAssertEqual(ScreenLayout.sections(for: .itemDetail, layouts: ScreenLayouts()), defaults, "no screen entry")
        let unknownOnly = try layouts(#"{"catalogue": 1, "screens": {"item_detail": {"sections": [{"type": "hologram"}]}}}"#)
        XCTAssertEqual(ScreenLayout.sections(for: .itemDetail, layouts: unknownOnly), defaults, "nothing known")
        let empty = try layouts(#"{"screens": {"item_detail": {"sections": []}}}"#)
        XCTAssertEqual(ScreenLayout.sections(for: .itemDetail, layouts: empty), defaults, "empty list")
    }

    func testServerOrderIsKept() throws {
        let l = try layouts(#"""
        {"catalogue": 1, "screens": {"place_detail": {"sections": [
          {"type": "menu"}, {"type": "hours", "title": "Opening hours"}, {"type": "header", "show": ["image"]},
          {"type": "at_this_location"}]}}}
        """#)
        let sections = ScreenLayout.sections(for: .placeDetail, layouts: l)
        XCTAssertEqual(types(sections), ["menu", "hours", "header", "at_this_location"])
        XCTAssertEqual(sections[1].title, "Opening hours")
        XCTAssertEqual(sections[2].show, ["image"])
    }

    // MARK: Overrides

    func testCategoryAndTagOverrides() throws {
        let l = try layouts(#"""
        {"catalogue": 1, "screens": {
          "place_detail": {"sections": [{"type": "header"}, {"type": "about"}],
            "overrides": [{"match": "category:FOOD", "sections": [{"type": "menu"}, {"type": "hours"}, {"type": "header"}]}]},
          "item_detail": {"sections": [{"type": "header"}],
            "overrides": [{"match": "tag:nothing", "sections": [{"type": "hologram"}]},
                          {"match": "tag:live music", "sections": [{"type": "performers"}, {"type": "header"}]},
                          {"match": "category:Stage", "sections": [{"type": "place_link"}]}]}}}
        """#)
        let taco = ScreenFacts.subject(bundle.location(6)!)
        XCTAssertEqual(types(ScreenLayout.sections(for: .placeDetail, layouts: l, subject: taco)), ["menu", "hours", "header"])
        let stage = ScreenFacts.subject(bundle.location(1)!)
        XCTAssertEqual(types(ScreenLayout.sections(for: .placeDetail, layouts: l, subject: stage)), ["header", "about"])
        // The first matching override wins (tag before category here, in the server's order).
        let juniper = ScreenFacts.subject(bundle.scheduleItem(109)!, bundle)
        XCTAssertEqual(juniper.category, "Stage")
        XCTAssertEqual(types(ScreenLayout.sections(for: .itemDetail, layouts: l, subject: juniper)), ["performers", "header"])
        // An item at a stage without the tag: the category override.
        var item = bundle.scheduleItem(109)!
        item.tags = ["folk"]
        XCTAssertEqual(types(ScreenLayout.sections(for: .itemDetail, layouts: l, subject: ScreenFacts.subject(item, bundle))), ["place_link"])
        // No category, no tag: the base.
        XCTAssertEqual(types(ScreenLayout.sections(for: .itemDetail, layouts: l, subject: ScreenFacts.subject(bundle.scheduleItem(203)!, bundle))), ["header"])
    }

    func testMatchSyntax() {
        let s = ScreenLayout.Subject(category: "Food", tags: ["bbq"])
        XCTAssertTrue(ScreenLayout.matches("category:food", s))
        XCTAssertTrue(ScreenLayout.matches(" tag: BBQ ", s))
        XCTAssertFalse(ScreenLayout.matches("tag:", s))
        XCTAssertFalse(ScreenLayout.matches("bbq", s))
        XCTAssertFalse(ScreenLayout.matches("location:5", s))
    }

    // MARK: Conditions

    func testConditions() {
        let facts: Set<String> = ["plan", "model_available", "during", "day:2026-11-14", "context.menu"]
        XCTAssertTrue(ScreenLayout.holds("has_plan", facts))
        XCTAssertTrue(ScreenLayout.holds("model_available", facts))
        XCTAssertTrue(ScreenLayout.holds("has:context.menu", facts))
        XCTAssertFalse(ScreenLayout.holds("has:context.hours", facts))
        XCTAssertTrue(ScreenLayout.holds("day:2026-11-14", facts))
        XCTAssertFalse(ScreenLayout.holds("day:2026-11-15", facts))
        XCTAssertTrue(ScreenLayout.holds("not:after_end", facts))
        XCTAssertFalse(ScreenLayout.holds("not:during", facts))
        XCTAssertFalse(ScreenLayout.holds("phase_of_moon", facts), "unknown → false")
        XCTAssertFalse(ScreenLayout.holds("not:phase_of_moon", facts), "unknown stays false when negated")
        XCTAssertFalse(ScreenLayout.holds("has:secret", ["has:secret", "secret"]), "only catalogue facts")
        XCTAssertFalse(ScreenLayout.holds("day:tomorrow", ["day:tomorrow"]))
    }

    func testWhenFiltersSections() throws {
        let l = try layouts(#"""
        {"screens": {"home": {"sections": [
          {"type": "header"}, {"type": "countdown", "when": "before_start"}, {"type": "now_next", "when": ["during", "has:schedule"]},
          {"type": "about", "when": ["day:2026-11-15"]}, {"type": "updates", "when": ["sometime"]}]}}}
        """#)
        let facts = ScreenFacts.event(bundle, state)
        // Sat 10:00 AM is the event's start: during, not before it.
        XCTAssertTrue(facts.contains("during"))
        XCTAssertFalse(facts.contains("before_start"))
        XCTAssertTrue(facts.contains("day:2026-11-14"))
        XCTAssertEqual(types(ScreenLayout.resolve(.home, layouts: l, facts: facts)), ["header", "now_next"])
    }

    // MARK: Facts

    func testEventFacts() {
        let facts = ScreenFacts.event(bundle, state)
        for fact in ["description", "schedule", "locations", "pins", "updates", "urgent", "coordinate"] {
            XCTAssertTrue(facts.contains(fact), fact)
        }
        XCTAssertFalse(facts.contains("flyer"))
        XCTAssertFalse(facts.contains("plan"))
        XCTAssertFalse(facts.contains("likes"))
        var before = state
        before.now = PlannerFixture.sat("08:00")
        XCTAssertTrue(ScreenFacts.event(bundle, before).contains("before_start"))
        var after = state
        after.now = PlannerFixture.date("2026-11-16T12:00:00Z")
        let late = ScreenFacts.event(bundle, after)
        XCTAssertTrue(late.contains("after_end"))
        XCTAssertFalse(late.contains("during"))
        XCTAssertFalse(late.contains("urgent"), "urgent only for 12 h")
    }

    func testNowPlayingNeedsAPinnedPlace() {
        var s = state
        s.now = PlannerFixture.sat("11:30") // Juniper Lane on the Main Stage
        XCTAssertTrue(ScreenFacts.common(bundle, s).contains("now_playing"))
        s.now = PlannerFixture.sat("10:15") // only Gates open, no place
        XCTAssertFalse(ScreenFacts.common(bundle, s).contains("now_playing"))
        XCTAssertEqual(types(ScreenLayout.resolve(.mapOverlay, layouts: nil, facts: ScreenFacts.common(bundle, s))), ["selected_place"])
    }

    func testHomeDefaults() {
        var s = state
        s.hasLikes = true
        s.hasPlan = true
        XCTAssertEqual(types(ScreenLayout.resolve(.home, layouts: nil, facts: ScreenFacts.event(bundle, s))),
                       ["header", "urgent", "my_schedule", "map", "updates", "about"])
        XCTAssertEqual(ScreenLayout.sections(for: .home, layouts: nil).first { $0.type == "updates" }?.limit, 3)
        // Without anything in My schedule the section still shows (its empty state).
        XCTAssertTrue(types(ScreenLayout.resolve(.home, layouts: nil, facts: ScreenFacts.event(bundle, state))).contains("my_schedule"))
    }

    func testOlderHomeNamesMapToMySchedule() throws {
        let l = try layouts(#"{"screens": {"home": {"sections": [{"type": "plan_today"}, {"type": "liked", "title": "Faves"}, {"type": "map"}]}}}"#)
        let sections = ScreenLayout.sections(for: .home, layouts: l)
        XCTAssertEqual(types(sections), ["my_schedule", "map"])
        XCTAssertEqual(SectionCatalogue.version, 2)
    }

    // MARK: Decoding

    func testLenientDecoding() throws {
        let l = try layouts(#"""
        {"catalogue": "x", "extra": 1, "screens": {
          "unknown_screen": {"sections": [{"type": "header"}]},
          "event_info": {"sections": [{"type": "faq", "limit": "many", "show": ["a", 3]}, {"no_type": true}, 7, {"type": "about"}],
                         "overrides": [{"sections": []}, {"match": "tag:x", "sections": [{"type": "faq"}]}]},
          "home": "broken"}}
        """#)
        XCTAssertEqual(l.catalogue, 0)
        XCTAssertEqual(Set(l.screens.keys), [.eventInfo])
        let info = l.screens[.eventInfo]!
        XCTAssertEqual(types(info.sections), ["faq", "about"])
        XCTAssertNil(info.sections[0].limit)
        XCTAssertEqual(info.sections[0].show, ["a"])
        XCTAssertEqual(info.overrides.map(\.match), ["tag:x"])
    }

    func testBundleWithoutLayout() throws {
        let json = #"{"event": {"id": 1, "name": "E", "event_code": "E"}}"#
        let decoded = try JSONDecoder().decode(EventBundle.self, from: Data(json.utf8))
        XCTAssertNil(decoded.layout)
        let withLayout = #"{"event": {"id": 1, "name": "E", "event_code": "E"}, "layout": {"catalogue": 1, "screens": {"home": {"sections": [{"type": "header"}]}}}}"#
        XCTAssertEqual(try JSONDecoder().decode(EventBundle.self, from: Data(withLayout.utf8)).layout?.screens[.home]?.sections.count, 1)
        let nullLayout = #"{"event": {"id": 1, "name": "E", "event_code": "E"}, "layout": null}"#
        XCTAssertNil(try JSONDecoder().decode(EventBundle.self, from: Data(nullLayout.utf8)).layout)
    }

    // MARK: Home tab

    func testHomeTabAndScreenshotMode() {
        var display = DisplayConfig()
        display.tabs = [.home, .map, .schedule]
        display.defaultTab = .home
        XCTAssertEqual(TabLayout.resolve(display, hasFlyer: false).tabs, [.home, .map, .schedule])
        XCTAssertEqual(TabLayout.resolve(display, hasFlyer: false).defaultTab, .home)
        let shots = TabLayout.resolve(display, hasFlyer: false, screenshotMode: true)
        XCTAssertEqual(shots.tabs, [.map, .schedule])
        XCTAssertEqual(shots.defaultTab, .map)
        XCTAssertEqual(EventTab.home.systemImage, "house")
    }

    func testHomeTabDecodes() throws {
        let json = #"{"tabs": ["home", "map", "tickets", "notifications"], "default_tab": "home"}"#
        let display = try JSONDecoder().decode(DisplayConfig.self, from: Data(json.utf8))
        XCTAssertEqual(display.tabs, [.home, .map, .notifications])
        XCTAssertEqual(display.defaultTab, .home)
    }

    // MARK: - iPhone Duo: two columns and tabletop

    func testDetailColumnsFromTheContainerWidth() throws {
        let place = ScreenLayout.sections(for: .placeDetail, layouts: nil)
        XCTAssertNil(DetailColumns.split(place, screen: .placeDetail, width: 699))
        let wide = try XCTUnwrap(DetailColumns.split(place, screen: .placeDetail, width: 700))
        XCTAssertEqual(wide.leading.first?.type, "header")
        XCTAssertTrue(wide.leading.allSatisfy { DetailColumns.leadingTypes[.placeDetail]!.contains($0.type) })
        XCTAssertEqual(wide.leading.count + wide.trailing.count, place.count)
        XCTAssertFalse(wide.trailing.isEmpty)
        let item = try XCTUnwrap(DetailColumns.split(ScreenLayout.sections(for: .itemDetail, layouts: nil), screen: .itemDetail, width: 900))
        XCTAssertEqual(item.leading.first?.type, "header")
        // Screens without columns, or nothing for one side.
        XCTAssertNil(DetailColumns.split(ScreenLayout.sections(for: .home, layouts: nil), screen: .home, width: 900))
        XCTAssertNil(DetailColumns.split([LayoutSection("header")], screen: .placeDetail, width: 900))
    }

    func testHomeTabletopHalves() throws {
        let home = ScreenLayout.sections(for: .home, layouts: nil)
        let halves = try XCTUnwrap(TabletopSplit.home(home))
        XCTAssertEqual(halves.top.map(\.type), ["header", "urgent", "countdown", "map"])
        XCTAssertEqual(halves.bottom.first?.type, "my_schedule")
        XCTAssertNil(TabletopSplit.home([LayoutSection("header")]))
    }

    func testAboutTextOnce() {
        let line = "Twenty food trucks, a beer garden and a band on Main Street."
        XCTAssertEqual(AboutText.merged(description: line, about: line), line)
        XCTAssertEqual(AboutText.merged(description: line, about: "  twenty food trucks, a beer garden and a band on main street "), "twenty food trucks, a beer garden and a band on main street")
        XCTAssertEqual(AboutText.merged(description: line, about: line + " Free entry."), line + " Free entry.")
        XCTAssertEqual(AboutText.merged(description: line + " Dogs welcome.", about: line), line + " Dogs welcome.")
        XCTAssertEqual(AboutText.merged(description: "", about: line), line)
        XCTAssertEqual(AboutText.merged(description: line, about: nil), line)
        XCTAssertEqual(AboutText.merged(description: "Rain or shine.", about: line), line + "\n\nRain or shine.")
    }
}
