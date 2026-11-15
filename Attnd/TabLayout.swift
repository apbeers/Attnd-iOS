// TabLayout.swift
// Attnd (app and App Clip; pure, unit tested in TabLayoutTests — same cases as Android's
// `domain/TabLayout.kt`)
//
// The plan-first tab bar (plan tab spec, Nov 15, 2026; client-side only, no API change):
//   - My plan: always the first tab and the default tab, whatever `display.default_tab` says
//     (the full app only, never in screenshot mode).
//   - Explore: replaces the Map, Schedule and Locations tabs — one tab with a segmented switch
//     (Map | Schedule | Places, always in that order) holding only the views `display.tabs`
//     lists (one view → no switch; none → no Explore tab). Its first view = `default_tab` when
//     that is one of them, else the first of them in `display.tabs` order.
//   - Then Flyer and Updates in `display.tabs` order. At most 4 tabs, so never a More tab.
//   - Screenshot mode keeps the old layout (each listed tab, `default_tab`, else Map, else the
//     first), so the store screenshots stay as they are. The App Clip has no planner: Explore,
//     Flyer, Updates, opening on `default_tab`'s tab (else Explore).

import Foundation

/// One view inside the Explore tab.
enum ExploreView: String, CaseIterable, Hashable, Sendable, Identifiable {
    case map, schedule, places

    var id: String { rawValue }

    /// The switch's order.
    static let order: [ExploreView] = [.map, .schedule, .places]

    init?(_ tab: EventTab) {
        switch tab {
        case .map: self = .map
        case .schedule: self = .schedule
        case .locations: self = .places
        case .flyer, .notifications: return nil
        }
    }

    /// The display config's tab (and the `tab_view` usage detail: map / schedule / locations).
    var eventTab: EventTab {
        switch self {
        case .map: return .map
        case .schedule: return .schedule
        case .places: return .locations
        }
    }

    var title: String {
        switch self {
        case .map: return "Map"
        case .schedule: return "Schedule"
        case .places: return "Places"
        }
    }

    var systemImage: String { eventTab.systemImage }
}

/// One tab of the tab bar.
enum AppTab: Hashable, Sendable, Identifiable {
    case plan
    case explore
    /// Flyer and Updates; in screenshot mode every listed tab (the old layout).
    case event(EventTab)

    var id: String {
        switch self {
        case .plan: return "plan"
        case .explore: return "explore"
        case .event(let tab): return tab.rawValue
        }
    }

    var title: String {
        switch self {
        case .plan: return "My Plan"
        case .explore: return "Explore"
        case .event(let tab): return tab.title
        }
    }

    /// Distinct from every other tab: My plan `sparkles`, Explore `map` (Map is never a tab of its own then).
    var systemImage: String {
        switch self {
        case .plan: return "sparkles"
        case .explore: return "map"
        case .event(let tab): return tab.systemImage
        }
    }
}

/// The resolved tab bar for one event.
struct TabLayout: Hashable, Sendable {
    var tabs: [AppTab]
    /// Explore's views in switch order (empty: no Explore tab).
    var exploreViews: [ExploreView]
    /// The view Explore shows first (nil without Explore).
    var initialExploreView: ExploreView?
    /// The tab selected after joining.
    var defaultTab: AppTab

    /// `plan`: the My plan tab exists (full app, not screenshot mode). `explore`: Map, Schedule
    /// and Locations are merged into Explore (false only in screenshot mode).
    static func resolve(_ display: DisplayConfig, hasFlyer: Bool, plan: Bool, explore: Bool) -> TabLayout {
        let listed = display.resolvedTabs(hasFlyer: hasFlyer)
        guard explore else {
            return TabLayout(
                tabs: listed.map(AppTab.event),
                exploreViews: [],
                initialExploreView: nil,
                defaultTab: .event(display.resolvedDefaultTab(hasFlyer: hasFlyer))
            )
        }
        let views = ExploreView.order.filter { view in listed.contains(view.eventTab) }
        let fromDefault = display.defaultTab.flatMap(ExploreView.init).flatMap { views.contains($0) ? $0 : nil }
        let initial = fromDefault ?? listed.lazy.compactMap(ExploreView.init).first
        var tabs: [AppTab] = plan ? [.plan] : []
        if !views.isEmpty { tabs.append(.explore) }
        tabs += listed.filter { ExploreView($0) == nil }.map(AppTab.event)
        let defaultTab: AppTab
        if plan {
            defaultTab = .plan
        } else if fromDefault != nil {
            defaultTab = .explore
        } else if let tab = display.defaultTab, listed.contains(tab), ExploreView(tab) == nil {
            defaultTab = .event(tab)
        } else {
            defaultTab = tabs.first ?? .explore
        }
        return TabLayout(tabs: tabs, exploreViews: views, initialExploreView: initial, defaultTab: defaultTab)
    }

    /// The tab and Explore view that show `tab` (nil: hidden by `display.tabs`).
    func place(of tab: EventTab) -> (tab: AppTab, view: ExploreView?)? {
        if tabs.contains(.event(tab)) { return (.event(tab), nil) }
        if let view = ExploreView(tab), exploreViews.contains(view) { return (.explore, view) }
        return nil
    }

    /// The remembered Explore view when it is still listed, else the initial one.
    func exploreView(remembered: ExploreView?) -> ExploreView? {
        if let remembered, exploreViews.contains(remembered) { return remembered }
        return initialExploreView
    }
}
