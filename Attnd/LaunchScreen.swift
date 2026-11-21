// LaunchScreen.swift
// Attnd
//
// The first screen the user sees. Three ways in:
//   1. Nearby events (requires location permission)
//   2. Searching by event code or exact name (system search field)
//   3. Scanning the event's QR code
//
// Joining hands off to AppState, which swaps this screen for ContentView.

import SwiftUI
import CoreLocation

struct LaunchScreen: View {

    @Environment(AppState.self) private var appState

    @State private var nearbyResults: [NearbyEventResult] = []
    @State private var isLoadingNearby = false
    @State private var nearbyError: String?
    /// True when the nearby error is about location permission (shown with a location icon).
    @State private var nearbyErrorIsLocation = false
    @State private var searchQuery = ""
    @State private var isJoining = false
    @State private var joinError: String?
    @State private var showScanner = false

    @StateObject private var locationManager = LocationPermissionManager()

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if let joinError {
                    Section {
                        Label(joinError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !nearbyResults.isEmpty {
                    Section("Nearby Events") {
                        ForEach(nearbyResults) { result in
                            Button {
                                Task { await join(result.event) }
                            } label: {
                                EventRow(result: result)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if !isLoadingNearby {
                    Section {
                        if let nearbyError {
                            Label(nearbyError, systemImage: nearbyErrorIsLocation ? "location.slash" : "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView(
                                "No Nearby Events",
                                systemImage: "map",
                                description: Text("Search for an event code or scan the event's QR code.")
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .disabled(isJoining)
            .overlay {
                if isJoining {
                    ProgressView("Joining…")
                        .padding()
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                } else if isLoadingNearby {
                    ProgressView("Finding nearby events…")
                }
            }
            .navigationTitle("Attnd")
            .searchable(text: $searchQuery, prompt: "Event code or name")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) {
                Task { await joinByCode(trimmedQuery) }
            }
            .refreshable { await loadNearby() }
            // Distance + compass arrow to each nearby event while the list shows any.
            .usesUserLocation(heading: true, active: !nearbyResults.isEmpty)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showScanner = true } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                }
                ToolbarItem(placement: .pinnedTrailing) {
                    Button { Task { await joinByCode(trimmedQuery) } } label: {
                        Label("Join", systemImage: "arrow.right.circle")
                    }
                    .disabled(trimmedQuery.isEmpty || isJoining)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { raw in
                    Task { await handleScannedCode(raw) }
                }
            }
        }
        .task {
            await loadNearby()
        }
    }

    // MARK: - Actions

    private func loadNearby() async {
        guard let coordinate = await locationManager.requestLocation() else {
            nearbyError = "Location access is needed to find nearby events."
            nearbyErrorIsLocation = true
            return
        }
        isLoadingNearby = true
        nearbyError = nil
        do {
            nearbyResults = try await APIClient.shared.nearbyEvents(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } catch {
            nearbyError = error.localizedDescription
            nearbyErrorIsLocation = false
        }
        isLoadingNearby = false
    }

    /// Exact event code or name via `events/lookup/`.
    private func joinByCode(_ code: String, via: String = "search") async {
        guard !code.isEmpty, !isJoining else { return }
        isJoining = true
        joinError = nil
        let joined = await appState.join(code: code, via: via)
        if !joined {
            joinError = "Event not found. Check the code or full event name and try again."
            AppLog.warning(.ui, "ui.error.shown", "Event not found", ["kind": .string(via == "qr" ? "scan" : "lookup")])
        }
        isJoining = false
    }

    /// A join URL (https://attnd.app/join/CODE/) or a bare event code.
    private func handleScannedCode(_ raw: String) async {
        guard let code = DeepLink.eventCode(fromScanned: raw) else {
            joinError = "QR code not recognised. Try entering the event code instead."
            AppLog.warning(.ui, "ui.error.shown", "QR code not recognised", ["kind": "scan"])
            return
        }
        searchQuery = code
        await joinByCode(code, via: "qr")
    }

    private func join(_ event: Event) async {
        isJoining = true
        joinError = nil
        await appState.joinEvent(event, via: "nearby")
        isJoining = false
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let result: NearbyEventResult

    @Environment(AppState.self) private var appState

    private var event: Event { result.event }

    var body: some View {
        // Re-evaluated every minute so "in 12 min" stays current.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.name).font(.headline)
            HStack {
                if appState.userLocation.direction(to: event.coordinate) != nil {
                    // "0.6 mi ↗" from the live position.
                    DistanceBadge(target: event.coordinate, font: .subheadline)
                } else if let miles = result.distanceMiles, miles.isFinite {
                    // The server's distance, in the phone's region units.
                    Text(DistanceText.text(meters: miles * DistanceText.metersPerMile, imperial: DistanceText.usesImperial()))
                }
                Spacer()
                // "in 3 days", "today 7:30 PM", "Now" — `starts_in_hours` is never printed as hours.
                if let relative = RelativeTimeText.event(event, startsInHours: result.startsInHours, now: now) {
                    Text(relative)
                        .foregroundStyle(.tint)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            let details = [
                event.startTime.map { EventTimeFormat.dateTime($0, in: event.timeZone) },
                event.address.isEmpty ? nil : event.address,
            ].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
