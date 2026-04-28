// ContentView.swift
// Attnd
//
// Main tab container shown after a user has joined an event.

import SwiftUI
import CoreLocation

struct ContentView: View {

    @Environment(AppState.self) private var appState
    @State private var selectedTab: Int = 0

    /// A binding that increments mapCenterToken whenever the Map tab (tag 0) is tapped,
    /// whether or not it was already selected — so re-tapping always re-centers.
    private var tabBinding: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                // Only re-center when the user taps the Map tab while already on it
                if newTab == 0 && selectedTab == 0 {
                    appState.mapCenterToken += 1
                }
                selectedTab = newTab
            }
        )
    }

    var body: some View {
        TabView(selection: tabBinding) {

            // MARK: Map
            NavigationStack {
                MapView(
                    locations: appState.locations,
                    centerCoordinate: appState.currentEvent.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                )
            }
            .tabItem { Label("Map", systemImage: "map") }
            .tag(0)

            // MARK: Locations
            NavigationStack {
                LocationsView(locations: appState.locations)
                    .navigationDestination(for: Location.self) { location in
                        LocationDetailView(location: location)
                    }
                    .overlay {
                        if appState.isLoadingLocations { ProgressView() }
                    }
            }
            .tabItem { Label("Locations", systemImage: "list.dash") }
            .tag(1)

            // MARK: Info / Flyer
            NavigationStack {
                FlyerView(flyerUrl: appState.currentEvent?.flyerUrl)
            }
            .tabItem { Label("Info", systemImage: "doc") }
            .tag(2)

            // MARK: Notifications
            NavigationStack {
                NotificationsView(
                    notifications: appState.notifications,
                    onRefresh: {
                        guard let event = appState.currentEvent else { return }
                        await appState.loadNotifications(eventId: event.id)
                    }
                )
                .overlay {
                    if appState.isLoadingNotifications { ProgressView() }
                }
            }
            .tabItem { Label("Notifications", systemImage: "bell") }
            .tag(3)

            // MARK: Options
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Options", systemImage: "gearshape") }
            .tag(4)
        }
        .task(id: appState.currentEvent?.id) {
            guard let event = appState.currentEvent else { return }
            await appState.loadEventData(event: event)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
