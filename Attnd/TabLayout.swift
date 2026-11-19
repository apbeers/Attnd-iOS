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
//   - The Locations tab is titled "Places" (the app's word for locations); screenshot mode keeps
//     "Locations" so the store screenshots stay exactly as they were.

import Foundation

struct TabLayout: Hashable, Sendable {
    var tabs: [EventTab]
    /// The tab selected after joining.
    var defaultTab: EventTab

    static func resolve(_ display: DisplayConfig, hasFlyer: Bool) -> TabLayout {
        TabLayout(tabs: display.resolvedTabs(hasFlyer: hasFlyer), defaultTab: display.resolvedDefaultTab(hasFlyer: hasFlyer))
    }

    /// The tab bar's (and the tab's navigation) title.
    static func title(_ tab: EventTab, screenshotMode: Bool) -> String {
        if tab == .locations && !screenshotMode { return "Places" }
        return tab.title
    }

    func contains(_ tab: EventTab) -> Bool { tabs.contains(tab) }
}
