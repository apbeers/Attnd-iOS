// LaunchScreen.swift
// Attnd
//
// The first screen the user sees. Offers two paths:
//   1. Nearby events list (requires location permission)
//   2. Manual event code / name entry
//
// After tapping an event, the user is transitioned into ContentView via AppState.

import SwiftUI
import CoreLocation

struct LaunchScreen: View {

    @Environment(AppState.self) private var appState

    @State private var nearbyResults: [NearbyEventResult] = []
    @State private var isLoadingNearby = false
    @State private var nearbyError: String? = nil
    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var searchError: String? = nil
    @State private var isJoining = false
    @State private var joinError: String? = nil

    @StateObject private var locationManager = LocationPermissionManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Search Bar
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Event name or code", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await searchEvent() } }
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .padding()

                if let err = searchError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if let err = joinError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Divider()

                // MARK: - Nearby Events / Search Results
                if isSearching || isJoining || isLoadingNearby {
                    Spacer()
                    ProgressView(isSearching ? "Searching…" : isJoining ? "Joining…" : "Finding nearby events…")
                    Spacer()
                } else {
                    List {
                        if !nearbyResults.isEmpty {
                            Section("Nearby Events") {
                                ForEach(nearbyResults) { result in
                                    EventRow(
                                        event: result.event,
                                        subtitle: String(format: "%.1f mi away", result.distanceMiles)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { Task { await join(result.event) } }
                                }
                            }
                        } else if !isLoadingNearby {
                            Section {
                                if let err = nearbyError {
                                    Label(err, systemImage: "location.slash")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ContentUnavailableView(
                                        "No Nearby Events",
                                        systemImage: "map",
                                        description: Text("Enter an event code above to join manually.")
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Attnd")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await searchEvent() } } label: {
                        Text("Join")
                    }
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
            }
        }
        .task {
            await requestLocationAndLoadNearby()
        }
    }

    // MARK: - Helpers

    private func requestLocationAndLoadNearby() async {
        let coord = await locationManager.requestLocation()
        guard let coord else {
            nearbyError = "Location access is needed to find nearby events."
            return
        }
        isLoadingNearby = true
        nearbyError = nil
        do {
            let list = try await APIClient.shared.nearbyEvents(latitude: coord.latitude, longitude: coord.longitude)
            nearbyResults = list.results
        } catch {
            nearbyError = error.localizedDescription
        }
        isLoadingNearby = false
    }

    private func searchEvent() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        do {
            // Try exact lookup first; fall back to fuzzy search
            let event: Event
            do {
                event = try await APIClient.shared.lookupEvent(query: q)
            } catch APIError.notFound {
                event = try await APIClient.shared.searchEvent(query: q)
            }
            await join(event)
        } catch {
            searchError = "Event not found. Check the name or code and try again."
        }
        isSearching = false
    }

    private func join(_ event: Event) async {
        isJoining = true
        joinError = nil
        await appState.joinEvent(event)
        isJoining = false
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: Event
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.name).font(.headline)
            HStack {
                Text(subtitle)
                Spacer()
                Text(formattedDate(event.startTime))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !event.address.isEmpty {
                Text(event.address)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            return fmt.string(from: date)
        }
        return iso
    }
}

// MARK: - Location Permission Manager

/// Wraps CLLocationManager in a simple async/await interface for one-shot location request.
@MainActor
private final class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            continuation = cont
            let status = manager.authorizationStatus
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                cont.resume(returning: nil)
                continuation = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            } else if manager.authorizationStatus != .notDetermined {
                continuation?.resume(returning: nil)
                continuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            let coord = locations.first?.coordinate
            continuation?.resume(returning: coord)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}
