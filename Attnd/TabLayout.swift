// TabLayout.swift
// Attnd (app and App Clip; pure, unit tested in TabLayoutTests)
//
// The tab bar (Nov 16, 2026: iOS went back to the event's own tabs; Android keeps the shared plan
// tab spec's My plan + Explore tabs for now):
//   - The tabs `display.tabs` lists, in its order (Map, Places, Schedule, Flyer, Updates; Flyer only
//     when listed or, by default, when the event has a flyer), at most `DisplayConfig.maxTabs` (5),
//     so never a More tab. No My plan tab and no Explore tab: the plan is the plan page, a
//     full-screen cover opened by the floating "My plan" button on every tab (AssistantView.swift).
//   - The tab selected after joining: `default_tab` when listed, else Map, else the first.
//   - Home (API-024, when `display.tabs` lists it): the event's `home` layout sections
//     (`HomeTab` in ScreenLayoutViews.swift); never in screenshot mode.
//   - The Locations tab is titled "Places" (the app's word for locations); screenshot mode keeps
//     "Locations" so the store screenshots stay exactly as they were.
//   - Options (the gear) is on one tab's root screen only: Updates, or the first tab when the
//     event hides Updates (`optionsTab`), so it is always reachable.
//   - `MapNavigation`: the Map tab's stack of pushed place details and its pending pin focus
//     ("Show on Map" pops back to the map and selects the pin).

import Foundation

struct TabLayout: Hashable, Sendable {
    var tabs: [EventTab]
    /// The tab selected after joining.
    var defaultTab: EventTab

    /// Screenshot mode drops the Home tab (API-024): the store screenshots keep the built-in tabs.
    static func resolve(_ display: DisplayConfig, hasFlyer: Bool, screenshotMode: Bool = false) -> TabLayout {
        var display = display
        if screenshotMode, let tabs = display.tabs {
            display.tabs = tabs.filter { $0 != .home }
            if display.defaultTab == .home { display.defaultTab = nil }
        }
        return TabLayout(tabs: display.resolvedTabs(hasFlyer: hasFlyer), defaultTab: display.resolvedDefaultTab(hasFlyer: hasFlyer))
    }

    /// The tab bar's (and the tab's navigation) title.
    static func title(_ tab: EventTab, screenshotMode: Bool) -> String {
        if tab == .locations && !screenshotMode { return "Places" }
        return tab.title
    }

    func contains(_ tab: EventTab) -> Bool { tabs.contains(tab) }

    /// The tab whose root screen has the Options button: Updates, else the first tab.
    var optionsTab: EventTab? {
        tabs.contains(.notifications) ? .notifications : tabs.first
    }
}

/// The Map tab's navigation: place details pushed over the map (by location id) and the pin to
/// focus next. "Show on Map" (from any detail, including one pushed over the map itself) pops
/// back to the map and focuses the pin, so the selected-location card and walking route show.
struct MapNavigation: Hashable, Sendable {
    /// Location ids of the place details pushed on the Map tab's stack.
    var path: [Int] = []
    /// The pin to select and frame once the map is on screen (consumed by the map).
    var focusLocationId: Int?

    /// A pin's card tapped: its detail over the map.
    mutating func open(_ locationId: Int) {
        path.append(locationId)
    }

    /// Back to the map (every pushed detail pops) with `locationId` focused.
    mutating func showOnMap(_ locationId: Int) {
        path = []
        focusLocationId = locationId
    }

    /// The pending focus, cleared.
    mutating func takeFocus() -> Int? {
        defer { focusLocationId = nil }
        return focusLocationId
    }

    mutating func reset() {
        path = []
        focusLocationId = nil
    }
}
