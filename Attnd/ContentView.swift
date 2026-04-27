// ContentView.swift
// Attnd
//
// Main tab container shown after a user has joined an event.

import SwiftUI
import CoreLocation

struct ContentView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {

            // MARK: Map
            NavigationStack {
                MapView(
                    locations: appState.locations,
                    centerCoordinate: appState.currentEvent.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    },
                    showUserLocation: appState.showUserLocation
                )
            }
            .tabItem { Label("Map", systemImage: "map") }

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

            // MARK: Info / Flyer
            NavigationStack {
                FlyerView(flyerUrl: appState.currentEvent?.flyerUrl)
            }
            .tabItem { Label("Info", systemImage: "doc") }

            // MARK: Notifications
            NavigationStack {
                NotificationsView(notifications: appState.notifications)
                    .overlay {
                        if appState.isLoadingNotifications { ProgressView() }
                    }
            }
            .tabItem { Label("Notifications", systemImage: "bell") }

            // MARK: Options
            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Options", systemImage: "gearshape") }
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
