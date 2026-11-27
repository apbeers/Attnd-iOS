// MapArrangement.swift
// Attnd
//
// The Map tab: the map (primary pane) and, on regular width, the pane named by
// `display.secondary_pane` (locations, schedule or now/next) in a `PanePair`
// (ArrangementView on iOS 27.1+). Each pane brings its own NavigationStack.

import MapKit
import SwiftUI

/// The Map tab's state that must survive fold / unfold (batch 7 fix round): the selected pin, the
/// chips, the linked schedule pane's highlighted set and the time-travel scrubber's time.
struct MapUIState: Equatable {
    var selectedLocationId: Int?
    var selectedCategory: String?
    var heartedOnly = false
    /// The set picked in the schedule pane (highlighted there; its stage is the selected pin).
    var paneItemId: Int?
    /// A pin tapped on the map: the schedule pane scrolls to that place's next set.
    var paneScrollLocationId: Int?
    /// Time travel (unfolded): nil = now (the live map).
    var timeTravel: Date?
}

struct MapTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Owned here so the camera survives switching between compact and wide layouts.
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasPositioned = false
    @State private var ui = MapUIState()

    var body: some View {
        let pane = appState.display.secondaryPane
        // The `map-pane` App Store screenshot (iPhone Duo) always shows the pane.
        let wantsPane = (horizontalSizeClass == .regular || ScreenshotMode.current?.screen == .mapPane) && pane != .none
        // The map is the primary pane: alone on phones and wherever the system shows one pane,
        // with the pane beside or below it where there is room (split on the fold). It is always
        // the same view, so the MKMapView, the camera and the selection survive fold / unfold.
        PanePair(showsSecondary: wantsPane) { split in
            ZStack {
                mapStack(showsFloatingButton: !split)
                // With the pane, the floating button sits bottom-trailing over the map.
                if split { FloatingButtonLayer() }
            }
        } secondary: {
            NavigationStack {
                SecondaryPaneView(pane: pane, ui: $ui)
            }
        }
        // The pane slides in and out (Reduce Motion: no animation).
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: wantsPane)
    }

    /// The map in its own stack: place details pushed over it (`AppState.mapNavigation`;
    /// "Show on Map" pops back here and focuses the pin).
    private func mapStack(showsFloatingButton: Bool) -> some View {
        @Bindable var state = appState
        return NavigationStack(path: $state.mapNavigation.path) {
            MapView(cameraPosition: $cameraPosition, hasPositioned: $hasPositioned, ui: $ui,
                    showsFloatingButton: showsFloatingButton, showsTimeTravel: horizontalSizeClass == .regular)
                .eventStatusBanners(reservesSpace: false)
                .optionsToolbarItem(for: .map)
        }
    }
}

/// The floating My plan / search button alone, bottom-trailing, clear of the fold and cameras
/// (for screens that keep their content's identity and can't wrap it in the modifier).
struct FloatingButtonLayer: View {
    var body: some View {
        ReservedRegionAvoiding {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    FloatingTabButton()
                        .debugFloatingFrame("floating_button")
                        .padding(.trailing, FloatingSearchButtonMetrics.trailingPadding)
                        .padding(.bottom, FloatingSearchButtonMetrics.bottomPadding)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Secondary pane

/// What sits beside the map on wide layouts.
struct SecondaryPaneView: View {
    let pane: SecondaryPane
    @Binding var ui: MapUIState

    @Environment(AppState.self) private var appState

    var body: some View {
        switch pane {
        case .locations, .none:
            MapLocationsPane(selectedLocationId: ui.selectedLocationId)
        case .schedule:
            linkedSchedule(style: appState.display.scheduleStyle, title: "Schedule")
        case .nowNext:
            linkedSchedule(style: .nowNext, title: "Now & Next")
        }
    }

    /// Linked panes (batch 7): a set tapped here flies the map to its stage (the selected pin, so
    /// the walking route and card follow); a pin tapped on the map scrolls here to that place's
    /// next set; hearts are the same state on both sides.
    private func linkedSchedule(style: ScheduleStyle, title: String) -> some View {
        ScheduleView(
            style: style,
            title: title,
            onSelect: { item in
                ui.paneItemId = item.id
                if let locationId = item.locationId, appState.location(id: locationId)?.coordinate != nil {
                    appState.mapFocusLocationId = locationId
                }
            },
            highlightedItemId: ui.paneItemId,
            scrollToLocationId: ui.paneScrollLocationId
        )
    }
}

/// A compact location list; tapping a row focuses that pin on the map.
private struct MapLocationsPane: View {
    var selectedLocationId: Int?

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            List(appState.locations) { location in
                Button {
                    appState.mapFocusLocationId = location.id
                } label: {
                    LocationRow(location: location, showImage: appState.display.showLocationImages)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(location.coordinate == nil)
                .listRowBackground(location.id == selectedLocationId ? Color.accentColor.opacity(0.14) : nil)
                .draggable(DragPayload.place(location.id).string)
                .id(location.id)
            }
            // A pin tapped on the map brings its row into view.
            .onChange(of: selectedLocationId) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .listStyle(.plain)
        .usesUserLocation(heading: true)
        .navigationTitle(appState.title(of: .locations))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await appState.pullToRefresh() }
        .overlay {
            if appState.locations.isEmpty {
                ContentUnavailableView("No Locations", systemImage: "mappin.slash")
            }
        }
    }
}
