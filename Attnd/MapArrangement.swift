// MapArrangement.swift
// Attnd
//
// The Map tab on wide layouts (an unfolded iPhone Duo, iPad): the map plus the
// pane named by `display.secondary_pane` (locations, schedule or now/next).
//
// ⚠️ COMPILE-TIME CHECK: `ArrangementView` / `.arrangementViewStyle(.split)` are the
// iPhone Duo-era SwiftUI container for a primary + secondary view (side by side when
// wide, stacked when tall). They were written from Apple's guidance without a
// compiler — if the spelling differs, fix it in `MapArrangement.body` only.
// The iOS 27 check is the assumed SDK; older systems get an equivalent fallback.
//
// Rules from Apple's guidance this file follows:
//   - ArrangementView sits at the top of the tab, never inside a NavigationSplitView,
//     List or ScrollView. Each pane brings its own NavigationStack.
//   - Layout decisions use size classes and container geometry, never screen size.

import MapKit
import SwiftUI

struct MapTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Owned here so the camera survives switching between compact and wide layouts.
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasPositioned = false

    var body: some View {
        let pane = appState.display.secondaryPane
        if horizontalSizeClass == .regular, pane != .none {
            MapArrangement {
                mapStack
            } secondary: {
                NavigationStack {
                    SecondaryPaneView(pane: pane)
                }
            }
        } else {
            mapStack
        }
    }

    private var mapStack: some View {
        NavigationStack {
            MapView(cameraPosition: $cameraPosition, hasPositioned: $hasPositioned)
                .eventStatusBanners()
        }
    }
}

/// Primary + secondary arrangement. Isolated so the new API is easy to adjust.
struct MapArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split) // ⚠️ VERIFY spelling
        } else {
            FallbackArrangement(primary: primary, secondary: secondary)
        }
        #else
        FallbackArrangement(primary: primary, secondary: secondary)
        #endif
    }
}

/// Side by side when the container is wider than tall, stacked otherwise.
private struct FallbackArrangement<Primary: View, Secondary: View>: View {
    let primary: Primary
    let secondary: Secondary

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= proxy.size.height
            let layout = isWide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                primary
                Divider()
                secondary
                    .frame(
                        width: isWide ? min(400, proxy.size.width * 0.4) : nil,
                        height: isWide ? nil : proxy.size.height * 0.45
                    )
            }
        }
    }
}

// MARK: - Secondary pane

/// What sits beside the map on wide layouts.
struct SecondaryPaneView: View {
    let pane: SecondaryPane

    @Environment(AppState.self) private var appState

    var body: some View {
        switch pane {
        case .locations, .none:
            MapLocationsPane()
        case .schedule:
            ScheduleView(style: appState.display.scheduleStyle)
        case .nowNext:
            ScheduleView(style: .nowNext, title: "Now & Next")
        }
    }
}

/// A compact location list; tapping a row focuses that pin on the map.
private struct MapLocationsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(appState.locations) { location in
            Button {
                appState.mapFocusLocationId = location.id
            } label: {
                LocationRow(location: location, showImage: appState.display.showLocationImages)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(location.coordinate == nil)
        }
        .listStyle(.plain)
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.refreshBundle() }
        .overlay {
            if appState.locations.isEmpty {
                ContentUnavailableView("No Locations", systemImage: "mappin.slash")
            }
        }
    }
}
