// ExploreTab.swift
// Attnd (app and App Clip)
//
// The Explore tab (plan tab spec, Nov 15, 2026): Map, Schedule and Places in one tab, switched by
// a segmented control at the top (Map | Schedule | Places, only the views `display.tabs` lists;
// one view → no switch). Each view keeps its own navigation (MapTab, ScheduleTab, LocationsTab);
// the switch sits under the navigation bar of each view's root screen (`exploreSwitcher()`), on
// the controls layer (Liquid Glass). The chosen view is `AppState.exploreView`, remembered per
// event; jumps (search, Siri, Live Activity links, notifications, Show on Map) select it through
// `AppState.select(_:)`.

import SwiftUI

struct ExploreTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let views = appState.tabLayout.exploreViews
        Group {
            switch appState.exploreView {
            case .map:
                MapTab()
            case .schedule:
                ScheduleTab()
            case .places:
                LocationsTab()
            }
        }
        .environment(\.showsExploreSwitcher, views.count > 1)
    }
}

extension EnvironmentValues {
    /// The root screens of Explore's views show the Map | Schedule | Places switch.
    @Entry var showsExploreSwitcher = false
}

extension View {
    /// The Explore switch above a view's root screen content (only inside Explore with 2+ views).
    func exploreSwitcher() -> some View {
        modifier(ExploreSwitcherModifier())
    }
}

private struct ExploreSwitcherModifier: ViewModifier {
    @Environment(\.showsExploreSwitcher) private var shows

    @ViewBuilder
    func body(content: Content) -> some View {
        if shows {
            content.safeAreaInset(edge: .top, spacing: 0) {
                ExploreSwitcher()
            }
        } else {
            content
        }
    }
}

private struct ExploreSwitcher: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Picker("Explore", selection: $state.exploreView) {
            ForEach(appState.tabLayout.exploreViews) { view in
                Label(view.title, systemImage: view.systemImage)
                    .labelStyle(.titleOnly)
                    .tag(view)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}
