// MapArrangement.swift
// Attnd
//
// The Map tab on wide layouts (an unfolded iPhone Duo): the map plus the
// pane named by `display.secondary_pane` (locations, schedule or now/next).
//
// `ArrangementView { primary } secondary: { … }` with `.arrangementViewStyle(.split)`
// (iOS 27.1, iPhone Duo): side by side when wide, stacked when tall, split on the fold.
// Older systems and SDKs get an equivalent fallback.
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
        // The `map-pane` App Store screenshot (iPhone Duo) always shows the arrangement.
        let showsPane = horizontalSizeClass == .regular || ScreenshotMode.current?.screen == .mapPane
        if showsPane, pane != .none {
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
                .optionsToolbarItem()
        }
    }
}

/// Primary + secondary arrangement. Isolated so the new API is easy to adjust.
struct MapArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        #if IOS27_SDK
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split)
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
        .usesUserLocation(heading: true)
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.pullToRefresh() }
        .overlay {
            if appState.locations.isEmpty {
                ContentUnavailableView("No Locations", systemImage: "mappin.slash")
            }
        }
    }
}
