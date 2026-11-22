// TabLayoutTests.swift
// AttndTests
//
// The tab bar (iOS, Nov 16, 2026): the event's own tabs again, no My plan / Explore tab.

import XCTest
@testable import Attnd

final class TabLayoutTests: XCTestCase {

    /// The event's own tabs (screenshot mode: no Home) unless `home`.
    private func layout(_ tabs: [EventTab]?, default tab: EventTab? = nil, flyer: Bool = false, home: Bool = false) -> TabLayout {
        var display = DisplayConfig()
        display.tabs = tabs
        display.defaultTab = tab
        return TabLayout.resolve(display, hasFlyer: flyer, screenshotMode: !home)
    }

    func testServerTabRules_API_V2() {
        // API_V2.md tab rules (Nov 22, 2026): Home first and the default; Home alone when that's all.
        XCTAssertEqual(layout([.home], home: true).tabs, [.home])
        XCTAssertEqual(layout([.home, .map, .schedule], default: .map, home: true).defaultTab, .home)
        // Home plus five: the flyer is left out first.
        XCTAssertEqual(layout([.home, .map, .locations, .schedule, .flyer, .notifications], home: true).tabs,
                       [.home, .map, .locations, .schedule, .notifications])
    }

    func testRemoveThenReAddATab() {
        // The preview phone (batch 7 report): Schedule removed in the console, then added back.
        let full = layout([.home, .map, .locations, .schedule, .notifications], home: true)
        XCTAssertEqual(full.tabs, [.home, .map, .locations, .schedule, .notifications])
        let removed = layout([.home, .map, .locations, .notifications], home: true)
        XCTAssertFalse(removed.tabs.contains(.schedule))
        let readded = layout([.home, .map, .locations, .notifications, .schedule], home: true)
        XCTAssertTrue(readded.tabs.contains(.schedule), "a tab added back shows again, wherever it is listed")
        // Five tabs without Home listed: Home is added and Flyer, not Schedule, makes room.
        let withFlyer = layout([.map, .schedule, .locations, .flyer, .notifications], home: true)
        XCTAssertEqual(withFlyer.tabs, [.home, .map, .schedule, .locations, .notifications])
        // Six listed: Home's rule cuts Flyer, so Schedule listed last stays.
        XCTAssertEqual(layout([.home, .map, .locations, .flyer, .notifications, .schedule], home: true).tabs,
                       [.home, .map, .locations, .notifications, .schedule])
    }

    func testHomeAlwaysFirstAndDefault() {
        // A bundle without Home (older catalogue, organizer's list) still gets it: Home doesn't come and go.
        let l = layout([.map, .locations, .schedule, .notifications], default: .schedule, home: true)
        XCTAssertEqual(l.tabs, [.home, .map, .locations, .schedule, .notifications])
        XCTAssertEqual(l.defaultTab, .home)
        XCTAssertEqual(l.optionsTab, .home, "the gear is on Home, so Updates is optional")
        XCTAssertEqual(layout([.schedule, .home, .map], home: true).tabs, [.home, .schedule, .map])
        // Five at most: Flyer goes first, then Places when the Map is there.
        XCTAssertEqual(layout([.map, .locations, .schedule, .flyer, .notifications], home: true).tabs,
                       [.home, .map, .locations, .schedule, .notifications])
        XCTAssertEqual(layout(nil, home: true).tabs, [.home, .map, .locations, .schedule, .notifications])
        // Screenshot mode keeps today's tabs.
        XCTAssertFalse(layout([.home, .map]).tabs.contains(.home))
    }

    func testListedTabsInOrder() {
        let l = layout([.schedule, .map, .flyer, .notifications])
        XCTAssertEqual(l.tabs, [.schedule, .map, .flyer, .notifications])
        XCTAssertEqual(l.defaultTab, .map, "no default_tab → Map when listed")
    }

    func testDefaults() {
        XCTAssertEqual(layout(nil).tabs, [.map, .locations, .schedule, .notifications])
        XCTAssertEqual(layout([]).tabs, [.map, .locations, .schedule, .notifications])
        XCTAssertEqual(layout(nil, flyer: true).tabs, [.map, .locations, .schedule, .flyer, .notifications])
        XCTAssertEqual(layout(nil).defaultTab, .map)
    }

    func testDefaultTab() {
        XCTAssertEqual(layout([.map, .schedule, .notifications], default: .schedule).defaultTab, .schedule)
        XCTAssertEqual(layout([.map, .notifications], default: .schedule).defaultTab, .map, "an unlisted default_tab is ignored")
        XCTAssertEqual(layout([.flyer, .notifications]).defaultTab, .flyer, "no Map → the first tab")
    }

    func testAtMostFiveTabs() {
        let l = layout([.map, .locations, .schedule, .flyer, .notifications, .map])
        XCTAssertEqual(l.tabs.count, DisplayConfig.maxTabs)
    }

    func testTitles() {
        XCTAssertEqual(TabLayout.title(.locations, screenshotMode: false), "Places")
        XCTAssertEqual(TabLayout.title(.locations, screenshotMode: true), "Locations")
        XCTAssertEqual(TabLayout.title(.notifications, screenshotMode: false), "Updates")
        XCTAssertEqual(TabLayout.title(.map, screenshotMode: false), "Map")
    }

    func testIconsAreDistinct() {
        let l = layout(nil, flyer: true)
        XCTAssertEqual(Set(l.tabs.map(\.systemImage)).count, l.tabs.count)
        XCTAssertEqual(EventTab.locations.systemImage, "list.bullet")
    }

    func testOptionsTab() {
        XCTAssertEqual(layout(nil).optionsTab, .notifications, "Options lives on Updates")
        XCTAssertEqual(layout([.schedule, .map, .notifications]).optionsTab, .notifications)
        XCTAssertEqual(layout([.schedule, .map]).optionsTab, .schedule, "no Updates → the first tab")
        XCTAssertEqual(layout([.flyer]).optionsTab, .flyer)
    }

    func testShowOnMapPopsBackToTheMap() {
        var nav = MapNavigation()
        nav.open(12)
        XCTAssertEqual(nav.path, [12])
        // Show on Map from the detail pushed over the map: back to the map, the pin focused.
        nav.showOnMap(12)
        XCTAssertEqual(nav.path, [])
        XCTAssertEqual(nav.focusLocationId, 12)
        XCTAssertEqual(nav.takeFocus(), 12)
        XCTAssertNil(nav.focusLocationId)
        XCTAssertNil(nav.takeFocus())
        // From another tab (nothing pushed) it only focuses.
        nav.showOnMap(5)
        XCTAssertEqual(nav, MapNavigation(path: [], focusLocationId: 5))
        nav.open(3); nav.open(4)
        nav.reset()
        XCTAssertEqual(nav, MapNavigation())
    }
}
