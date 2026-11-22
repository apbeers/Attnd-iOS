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
        // Catalogue 2's tab and onboarding screens have no built-in layout: without one the app
        // draws today's tab (display styles) and its own onboarding cards.
        let ownScreens: Set<LayoutScreen> = [.scheduleTab, .placesTab, .updatesTab, .onboarding]
        for screen in LayoutScreen.allCases {
            let defaults = ScreenLayout.defaults[screen] ?? []
            XCTAssertEqual(defaults.isEmpty, ownScreens.contains(screen), "\(screen) has a default")
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
        XCTAssertEqual(types(sections), ["my_schedule", "map", "website"], "the website is always added at the end of Home")
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

    // MARK: Catalogue 2 (API-027)

    func testCatalogue2_NewScreensDecodeAndValidate() throws {
        let decoded = try layouts("""
        {"screens": {
          "schedule_tab": {"sections": [{"type": "my_schedule"}, {"type": "featured", "ids": [101, 101, 114], "title": "Don't miss"}, {"type": "by_day"}, {"type": "hologram"}]},
          "places_tab": {"sections": [{"type": "by_category"}]},
          "updates_tab": {"sections": [{"type": "urgent"}, {"type": "latest"}, {"type": "earlier"}]},
          "onboarding": {"sections": [{"type": "welcome", "title": "Hi", "text": "  Welcome to the fair  ", "image": "http://x.test/a.png"}, {"type": "intro"}, {"type": "lock_screen"}]}
        }}
        """)
        let schedule = ScreenLayout.sections(for: .scheduleTab, layouts: decoded)
        XCTAssertEqual(types(schedule), ["my_schedule", "featured", "by_day"])
        XCTAssertEqual(schedule[1].ids, [101, 114])
        let onboarding = ScreenLayout.sections(for: .onboarding, layouts: decoded)
        XCTAssertEqual(types(onboarding), ["welcome", "intro", "lock_screen"])
        XCTAssertEqual(onboarding[0].text, "Welcome to the fair")
        XCTAssertNil(onboarding[0].image, "https only")
        // Untouched screens have no built-in layout: today's tabs.
        XCTAssertTrue(ScreenLayout.sections(for: .scheduleTab, layouts: nil).isEmpty)
        XCTAssertNil(TabListLayout.schedule([]))
        XCTAssertNil(OnboardingLayout.of([]))
    }

    func testTabListLayout() {
        let schedule = TabListLayout.schedule([LayoutSection("featured", title: "Picks", ids: [3]), LayoutSection("by_place")])
        XCTAssertEqual(schedule?.style, "by_location")
        XCTAssertEqual(schedule?.showsMySchedule, false)
        XCTAssertEqual(schedule?.featured, [3])
        XCTAssertEqual(schedule?.featuredTitle, "Picks")
        XCTAssertEqual(TabListLayout.schedule([LayoutSection("my_schedule"), LayoutSection("up_next")])?.style, "now_next")
        XCTAssertEqual(TabListLayout.places([LayoutSection("all_places", show: ["image"])])?.style, "cards")
        XCTAssertEqual(TabListLayout.places([LayoutSection("nearby")])?.style, "list")
        XCTAssertEqual(TabListLayout.places([LayoutSection("by_category")])?.style, "grouped")
    }

    func testUpdatesLayout_EachOnceNewestFirst() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let notifications = [
            AppNotification(id: 1, title: "Old", sendTime: now.addingTimeInterval(-3 * 86400)),
            AppNotification(id: 2, title: "Storm", sendTime: now.addingTimeInterval(-600), priority: .urgent),
            AppNotification(id: 3, title: "Gates", sendTime: now.addingTimeInterval(-3600)),
            AppNotification(id: 4, title: "Pinned", sendTime: now.addingTimeInterval(-2 * 86400)),
        ]
        let groups = UpdatesLayout.groups([LayoutSection("urgent"), LayoutSection("pinned", ids: [4]), LayoutSection("latest")],
                                          notifications: notifications, now: now)
        XCTAssertEqual(groups.map(\.type), ["urgent", "pinned", "latest", "earlier"])
        XCTAssertEqual(groups.map(\.ids), [[2], [4], [3], [1]])
        XCTAssertTrue(UpdatesLayout.groups([LayoutSection("faq")], notifications: notifications, now: now).allSatisfy { $0.ids.isEmpty })
    }

    func testOnboardingLayout() {
        let layout = OnboardingLayout.of([LayoutSection("welcome"), LayoutSection("location"), LayoutSection("plan")])
        XCTAssertEqual(layout?.cards, [.location, .plan], "a welcome card with nothing to say is skipped")
        let welcome = OnboardingLayout.of([LayoutSection("welcome", text: "Hello"), LayoutSection("notifications")])
        XCTAssertEqual(welcome?.cards, [.welcome, .notifications])
        XCTAssertEqual(welcome?.welcomeText, "Hello")
    }

    func testLiveActivitySettings_Lenient() throws {
        func decode(_ json: String) throws -> LiveActivitySettings {
            try JSONDecoder().decode(LiveActivitySettings.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode("{}"), .defaults)
        XCTAssertEqual(try decode("{}").activityButtons, ["skip", "map"])
        let set = try decode(#"{"follows": "LOCATION", "location_id": 3, "buttons": ["map", "add", "dance", "map"], "stale_text": "Open the app", "urgent": true}"#)
        XCTAssertEqual(set.follows, .location)
        XCTAssertEqual(set.buttons, ["map", "add"])
        XCTAssertEqual(set.activityButtons, ["map"])
        XCTAssertEqual(set.staleText, "Open the app")
        XCTAssertEqual(try decode(#"{"follows": "nonsense", "buttons": []}"#).follows, .mySchedule)
        XCTAssertEqual(try decode(#"{"buttons": []}"#).activityButtons, [])
        let bundle = try JSONDecoder().decode(EventBundle.self, from: Data(#"{"event": {"id": 1, "name": "E", "event_code": "E"}, "live_activity": {"follows": "everything"}, "locations": [{"id": 3, "name": "Barn"}]}"#.utf8))
        XCTAssertEqual(bundle.liveActivity?.follows, .everything)
        XCTAssertEqual(LiveActivitySettings(follows: .location, locationId: 3).followedLocation(in: bundle), 3)
        XCTAssertNil(LiveActivitySettings(follows: .location, locationId: 99).followedLocation(in: bundle))
    }

    // MARK: Preview phones (API-026)

    func testPreviewPoll() throws {
        func answer(_ json: String) throws -> ChangesResponse {
            try JSONDecoder().decode(ChangesResponse.self, from: Data(json.utf8))
        }
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"content_version": 8, "changed": false}"#), since: 8), .wait(0))
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"content_version": 9}"#), since: 8), .refresh)
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"changed": true}"#), since: 8), .refresh)
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"retry_after": 15}"#), since: 8), .wait(15))
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"retry_after": 99999}"#), since: 8), .wait(3600))
        XCTAssertEqual(PreviewPoll.next(try answer(#"{"preview": false, "changed": true}"#), since: 8), .stop)
    }

    func testPreviewToken_LinksAndJoinBody() throws {
        let link = try XCTUnwrap(URL(string: "attnd://join/DEMO?preview=abc.DEF-1_2:z"))
        XCTAssertEqual(DeepLink.httpsURL(fromAppScheme: link)?.absoluteString, "https://attnd.app/join/DEMO/?preview=abc.DEF-1_2:z")
        XCTAssertEqual(DeepLink.httpsURL(fromAppScheme: URL(string: "attnd://join/DEMO")!)?.absoluteString, "https://attnd.app/join/DEMO/")
        XCTAssertEqual(DeepLink.previewToken(from: URL(string: "https://attnd.app/join/DEMO/?preview=tok")!), "tok")
        XCTAssertNil(DeepLink.previewToken(from: URL(string: "https://attnd.app/join/DEMO/?preview=%3Cb%3E")!))
        XCTAssertNil(DeepLink.previewToken(from: URL(string: "https://attnd.app/join/DEMO/")!))
        XCTAssertEqual(DeepLink.previewToken(fromScanned: " https://attnd.app/join/DEMO/?preview=tok \n"), "tok")
        XCTAssertNil(DeepLink.previewToken(fromScanned: "DEMO"))

        func body(_ request: JoinRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }
        XCTAssertEqual(try body(JoinRequest(deviceId: "d", pushToken: nil, appVersion: "1", previewToken: "tok"))["preview_token"] as? String, "tok")
        let plain = try body(JoinRequest(deviceId: "d", pushToken: nil, appVersion: "1"))
        XCTAssertNil(plain["preview_token"])
        XCTAssertNil(plain["push_token"], "never sent as empty")
        XCTAssertEqual(plain["app_clip"] as? Bool, false)
    }

    func testContentUpdatedJitter() {
        XCTAssertEqual(PushPayload(userInfo: ["type": "content_updated", "jitter_ms": 1000]).jitterMilliseconds, 1000)
        XCTAssertEqual(PushPayload(userInfo: ["type": "content_updated", "jitter_ms": "0"]).jitterMilliseconds, 0)
        XCTAssertEqual(PushPayload(userInfo: ["type": "content_updated", "jitter_ms": 999_999]).jitterMilliseconds, 60_000)
        XCTAssertNil(PushPayload(userInfo: ["type": "content_updated"]).jitterMilliseconds)
        XCTAssertEqual(ContentUpdatePolicy.jitter(maxMilliseconds: 0), .zero)
        XCTAssertLessThanOrEqual(ContentUpdatePolicy.jitter(maxMilliseconds: 1000), .milliseconds(1000))
        XCTAssertLessThanOrEqual(ContentUpdatePolicy.jitter(), .seconds(10))
    }

    func testSavedCopy_ETagPerCatalogueAndHomeKept() throws {
        let body = Data(#"{"event": {"id": 4, "name": "Fair", "event_code": "FAIR"}, "display": {"tabs": ["map", "schedule"]}}"#.utf8)
        let old = SavedEvent(eventId: 4, eventCode: "FAIR", etag: "\"e4-v3-s1\"", lastRefreshed: nil, bundleJSON: body)
        XCTAssertNil(old.usableETag, "a file from before (no catalogue) refetches the whole bundle")
        let saved = SavedEvent(eventId: 4, eventCode: "FAIR", etag: "\"e4-v3-s2\"", lastRefreshed: nil, bundleJSON: body,
                               sections: SectionCatalogue.version)
        let restored = try SavedEvent.decode(SavedEvent.encode(saved))
        XCTAssertEqual(restored.usableETag, "\"e4-v3-s2\"")
        XCTAssertNil(SavedEvent(eventId: 4, eventCode: "FAIR", etag: "x", lastRefreshed: nil, bundleJSON: body, sections: 1).usableETag)
        // Offline restore (and a 304 that keeps this body): Home is still the first tab.
        let bundle = try restored.decodedBundle()
        let tabs = TabLayout.resolve(bundle.display, hasFlyer: false)
        XCTAssertEqual(tabs.tabs, [.home, .map, .schedule])
        XCTAssertEqual(tabs.defaultTab, .home)
    }

    func testAppHandover_ClipToApp() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)")
        let shared = try XCTUnwrap(UserDefaults(suiteName: "test.shared.\(UUID().uuidString)"))
        let clip = try XCTUnwrap(UserDefaults(suiteName: "test.clip.\(UUID().uuidString)"))
        let app = try XCTUnwrap(UserDefaults(suiteName: "test.app.\(UUID().uuidString)"))
        let group = base.appendingPathComponent("group", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let clipFile = base.appendingPathComponent("clip/attnd-event/event.json")
        try FileManager.default.createDirectory(at: clipFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: clipFile)
        clip.set("DEMO", forKey: "pref.savedEventCode")
        clip.set(Data("{}".utf8), forKey: "pref.event.7")
        clip.set("abc", forKey: AppHandover.deviceIdKey)
        clip.set("token", forKey: "pref.pushToken")
        clip.set("other", forKey: "unrelated.key")

        AppHandover.export(from: clip, to: shared, eventFile: clipFile, sharedDirectory: group)
        XCTAssertFalse(AppHandover.appTookOver(shared))

        let appFile = base.appendingPathComponent("app/attnd-event/event.json")
        XCTAssertTrue(AppHandover.importIfNeeded(into: app, from: shared, eventFile: appFile, sharedDirectory: group))
        XCTAssertEqual(app.string(forKey: "pref.savedEventCode"), "DEMO")
        XCTAssertEqual(app.data(forKey: "pref.event.7"), Data("{}".utf8))
        XCTAssertEqual(app.string(forKey: AppHandover.deviceIdKey), "abc", "one device on the server")
        XCTAssertNil(app.string(forKey: "pref.pushToken"), "the app's push topic is its own")
        XCTAssertNil(app.string(forKey: "unrelated.key"))
        XCTAssertEqual(try Data(contentsOf: appFile), Data("saved".utf8))
        XCTAssertTrue(AppHandover.appTookOver(shared), "the clip stops its Live Activity")
        // Once only, and never over the app's own event.
        app.set("MINE", forKey: "pref.savedEventCode")
        XCTAssertFalse(AppHandover.importIfNeeded(into: app, from: shared, eventFile: appFile, sharedDirectory: group))
        XCTAssertEqual(app.string(forKey: "pref.savedEventCode"), "MINE")
        let fresh = try XCTUnwrap(UserDefaults(suiteName: "test.app2.\(UUID().uuidString)"))
        fresh.set("MINE", forKey: "pref.savedEventCode")
        XCTAssertFalse(AppHandover.importIfNeeded(into: fresh, from: shared, eventFile: nil, sharedDirectory: group))
        XCTAssertEqual(fresh.string(forKey: "pref.savedEventCode"), "MINE")
        try? FileManager.default.removeItem(at: base)
    }

    func testAssistantSettingCommands() {
        XCTAssertEqual(AssistantRouter.settingCommand("leave this event")?.name, .leave)
        XCTAssertEqual(AssistantRouter.settingCommand("switch to the dev server")?.string("server"), "dev")
        XCTAssertEqual(AssistantRouter.settingCommand("switch back to the production server")?.string("server"), "production")
        XCTAssertEqual(AssistantRouter.settingCommand("hide my location")?.bool("on"), false)
        XCTAssertEqual(AssistantRouter.settingCommand("show my location on the map")?.bool("on"), true)
        XCTAssertNil(AssistantRouter.settingCommand("where is the main stage location"))
        XCTAssertNil(AssistantRouter.settingCommand("leave now for the barn"))
        XCTAssertEqual(ActionName.leave.confirm, .chip)
        XCTAssertEqual(ActionName.switchServer.confirm, .chip)
        XCTAssertTrue(ActionName.neverAvailable.contains("leave_event"), "the shared never-available name stays refused")
    }

    func testHomeColumns_BalancedAndInOrder() {
        let sections = ["my_schedule", "map", "updates", "faq", "getting_there", "about", "website"].map { LayoutSection($0) }
        let columns = HomeColumns.split(sections)
        XCTAssertEqual(columns.leading.map(\.type), ["my_schedule", "updates", "getting_there", "website"])
        XCTAssertEqual(columns.trailing.map(\.type), ["map", "faq", "about"])
        XCTAssertEqual(columns.leading.count + columns.trailing.count, sections.count)
        XCTAssertTrue(HomeColumns.split([]).leading.isEmpty)
    }

    func testFoldRules() {
        XCTAssertEqual(FoldRules.primary(.map), "map")
        XCTAssertEqual(FoldRules.primary(.chat), "chat")
        XCTAssertEqual(FoldRules.folded(.schedule, selected: 12), .pushedDetail(12))
        XCTAssertEqual(FoldRules.folded(.places, selected: nil), .list)
        XCTAssertEqual(FoldRules.folded(.map, selected: 5), .map(selectedPin: 5))
        XCTAssertEqual(FoldRules.folded(.home, selected: nil), .same)
    }
}
