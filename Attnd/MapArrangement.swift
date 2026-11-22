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
        // The `map-pane` App Store screenshot (iPhone Duo) always shows the arrangement.
        let showsPane = (horizontalSizeClass == .regular || ScreenshotMode.current?.screen == .mapPane) && pane != .none
        // One map for every posture (batch 7 fix round: folding swapped the full-screen map for a
        // new one inside an ArrangementView, so a second MKMapView was made and the selection was
        // lost). The pane is an optional sibling before the map in an AnyLayout, so the map keeps
        // its identity when the pane comes and goes and when the layout turns from a row into a
        // column. Unfolded the pane leads and the map trails next to the tab rail, meeting on the
        // fold (the reported `.division`, else the middle) with no gutter.
        GeometryReader { proxy in
            let isWide = proxy.size.width >= proxy.size.height
            let fold = ReservedRegionReader.folds(in: proxy).first { $0.height > $0.width && $0.minX > 0 }
            let paneWidth = MapPaneLayout.paneWidth(container: proxy.size, foldMinX: fold?.minX)
            let layout = isWide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            ZStack {
                layout {
                    if showsPane {
                        NavigationStack {
                            SecondaryPaneView(pane: pane, ui: $ui)
                        }
                        .safeAreaPadding(.bottom, FloatingSearchButtonMetrics.reservedHeight)
                        .frame(width: isWide ? paneWidth : nil, height: isWide ? nil : proxy.size.height * 0.45)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    mapStack(showsFloatingButton: !showsPane)
                }
                // With the pane, the floating button sits bottom-trailing over the whole tab.
                if showsPane {
                    FloatingButtonLayer()
                }
            }
        }
        // The selected pin and pane carry across; the pane slides (Reduce Motion: no animation).
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsPane)
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

/// The pane's width beside the map: up to the fold when the system reports one (partly folded),
/// else half the width (the fold of a flat-open Duo is in the middle), never under 280 pt or over
/// 60 % of the width. Pure.
enum MapPaneLayout {
    static func paneWidth(container: CGSize, foldMinX: CGFloat?) -> CGFloat {
        let wanted = foldMinX ?? container.width / 2
        return min(max(wanted, min(280, container.width * 0.5)), container.width * 0.6)
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
                // The pane (primary) takes its share; the map fills the rest right to its edge.
                primary
                    .frame(
                        width: isWide ? min(400, proxy.size.width * 0.4) : nil,
                        height: isWide ? nil : proxy.size.height * 0.45
                    )
                secondary
            }
        }
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
