// TabLayoutTests.swift
// AttndTests
//
// The plan-first tab bar (plan tab spec; Android's `unit/TabLayoutTest.kt`, same cases).

import XCTest
@testable import Attnd

final class TabLayoutTests: XCTestCase {

    private func layout(_ tabs: [EventTab]?, default tab: EventTab? = nil, flyer: Bool = false,
                        plan: Bool = true, explore: Bool = true) -> TabLayout {
        var display = DisplayConfig()
        display.tabs = tabs
        display.defaultTab = tab
        return TabLayout.resolve(display, hasFlyer: flyer, plan: plan, explore: explore)
    }

    func testPlanFirstAndExplore() {
        let l = layout([.map, .schedule, .flyer, .notifications])
        XCTAssertEqual(l.tabs, [.plan, .explore, .event(.flyer), .event(.notifications)])
        XCTAssertEqual(l.exploreViews, [.map, .schedule])
        XCTAssertEqual(l.initialExploreView, .map)
        XCTAssertEqual(l.defaultTab, .plan)
    }

    func testOneViewAndNone() {
        let one = layout([.schedule])
        XCTAssertEqual(one.tabs, [.plan, .explore])
        XCTAssertEqual(one.exploreViews, [.schedule])
        XCTAssertEqual(one.initialExploreView, .schedule)

        let none = layout([.flyer, .notifications])
        XCTAssertEqual(none.tabs, [.plan, .event(.flyer), .event(.notifications)])
        XCTAssertEqual(none.exploreViews, [])
        XCTAssertNil(none.initialExploreView)
    }

    func testEmptyTabsUseTheDefaults() {
        let l = layout([])
        XCTAssertEqual(l.tabs, [.plan, .explore, .event(.notifications)])
        XCTAssertEqual(l.exploreViews, [.map, .schedule, .places])
        XCTAssertEqual(layout(nil, flyer: true).tabs, [.plan, .explore, .event(.flyer), .event(.notifications)])
    }

    func testSwitchOrderAndInitialView() {
        // Always Map | Schedule | Places; the first view = default_tab when listed, else the first listed.
        let l = layout([.notifications, .locations, .schedule], default: .notifications)
        XCTAssertEqual(l.tabs, [.plan, .explore, .event(.notifications)])
        XCTAssertEqual(l.exploreViews, [.schedule, .places])
        XCTAssertEqual(l.initialExploreView, .places)
        XCTAssertEqual(l.defaultTab, .plan, "My plan ignores default_tab")
        XCTAssertEqual(layout([.map, .locations, .schedule], default: .schedule).initialExploreView, .schedule)
        XCTAssertEqual(layout([.map, .schedule], default: .locations).initialExploreView, .map)
    }

    func testAppClipWithoutPlan() {
        XCTAssertEqual(layout([.map, .schedule, .notifications], default: .schedule, plan: false).defaultTab, .explore)
        XCTAssertEqual(layout([.map, .notifications], default: .notifications, plan: false).defaultTab, .event(.notifications))
        XCTAssertEqual(layout([.flyer, .notifications], plan: false).defaultTab, .event(.flyer))
    }

    func testScreenshotModeKeepsTheOldTabs() {
        let l = layout([.map, .locations, .schedule, .notifications], default: .schedule, plan: false, explore: false)
        XCTAssertEqual(l.tabs, [.event(.map), .event(.locations), .event(.schedule), .event(.notifications)])
        XCTAssertEqual(l.defaultTab, .event(.schedule))
        XCTAssertEqual(l.exploreViews, [])
    }

    func testPlaces() {
        let l = layout([.map, .locations, .notifications])
        XCTAssertEqual(l.place(of: .locations)?.tab, .explore)
        XCTAssertEqual(l.place(of: .locations)?.view, .places)
        XCTAssertEqual(l.place(of: .notifications)?.tab, .event(.notifications))
        XCTAssertNil(l.place(of: .schedule))
        XCTAssertNil(l.place(of: .flyer))
        XCTAssertEqual(l.exploreView(remembered: .places), .places)
        XCTAssertEqual(l.exploreView(remembered: .schedule), .map)
        XCTAssertEqual(ExploreView.places.eventTab, .locations)
    }

    func testIconsAreDistinct() {
        let l = layout(nil, flyer: true)
        XCTAssertEqual(Set(l.tabs.map(\.systemImage)).count, l.tabs.count)
        XCTAssertEqual(AppTab.plan.systemImage, "sparkles")
        XCTAssertEqual(AppTab.explore.systemImage, "map")
    }
}
