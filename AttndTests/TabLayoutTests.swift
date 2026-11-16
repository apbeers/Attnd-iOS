// TabLayoutTests.swift
// AttndTests
//
// The tab bar (iOS, Nov 16, 2026): the event's own tabs again, no My plan / Explore tab.

import XCTest
@testable import Attnd

final class TabLayoutTests: XCTestCase {

    private func layout(_ tabs: [EventTab]?, default tab: EventTab? = nil, flyer: Bool = false) -> TabLayout {
        var display = DisplayConfig()
        display.tabs = tabs
        display.defaultTab = tab
        return TabLayout.resolve(display, hasFlyer: flyer)
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
}
