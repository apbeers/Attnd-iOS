// LocationsView.swift
// Attnd

import SwiftUI
import MapKit

struct LocationsView: View {
    let locations: [Location]

    init(locations: [Location] = []) {
        self.locations = locations
    }

    var body: some View {
        List(locations) { location in
            NavigationLink(value: location) {
                HStack(spacing: 12) {
                    if let imageUrl = location.imageUrl, let url = URL(string: imageUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            default:
                                ProgressView()
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 72, height: 72)
                            .overlay(Image(systemName: "mappin").foregroundStyle(.secondary))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name)
                            .font(.headline)
                        Text(location.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Locations")
        .overlay {
            if locations.isEmpty {
                ContentUnavailableView(
                    "No Locations",
                    systemImage: "mappin.slash",
                    description: Text("Locations will appear here once loaded.")
                )
            }
        }
    }
}

// MARK: - Location Detail

struct LocationDetailView: View {
    let location: Location

    var body: some View {
        // TimelineView drives live countdown labels every 30 s across the whole detail page.
        // Content is extracted into a helper to avoid generic-inference failures in Xcode 26.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            detailContent(now: context.date)
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detailContent(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero image
                if let imageUrl = location.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else if case .failure = phase {
                            Color(.systemGray5)
                                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(location.name).font(.title2.bold())

                    if !location.address.isEmpty {
                        Text(location.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Walking directions
                    if location.latitude != 0 || location.longitude != 0 {
                        Button {
                            let coordinate = CLLocationCoordinate2D(
                                latitude: location.latitude,
                                longitude: location.longitude
                            )
                            let mapItem = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                            mapItem.name = location.name
                            mapItem.openInMaps(launchOptions: [
                                MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
                            ])
                        } label: {
                            Label("Get Walking Directions", systemImage: "figure.walk")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Divider()

                    Text(location.description).font(.body)

                    if let website = location.website, let url = URL(string: website) {
                        Link("Visit Website", destination: url)
                            .font(.subheadline)
                    }

                    // Schedule at this location
                    if !location.scheduledItems.isEmpty {
                        Divider()
                        Text("At This Location")
                            .font(.title3.bold())
                            .padding(.top, 4)

                        ForEach(location.scheduledItems) { item in
                            LocationScheduleRow(item: item, now: now)
                            if item.id != location.scheduledItems.last?.id {
                                Divider().padding(.vertical, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Schedule row inside Location Detail

private struct LocationScheduleRow: View {
    let item: ScheduledItem
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Time + countdown on the same line
            HStack(alignment: .firstTextBaseline) {
                Text(formattedTime(item.startTime))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let countdown = item.startsInText(relativeTo: now) {
                    Text(countdown)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.tint)
                }
            }
            Text(item.name).font(.headline)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func formattedTime(_ iso: String) -> String {
        let p1 = ISO8601DateFormatter()
        p1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let p2 = ISO8601DateFormatter()
        p2.formatOptions = [.withInternetDateTime]
        guard let date = p1.date(from: iso) ?? p2.date(from: iso) else { return iso }
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeZone = .current
        fmt.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return fmt.string(from: date)
    }
}

#Preview {
    NavigationStack {
        LocationsView(locations: [
            Location(id: 1, name: "Main Stage", snippet: "Live music all day",
                     description: "Full description here", website: nil, imageUrl: nil,
                     latitude: 32.754695, longitude: -97.331605, address: "420 Main St",
                     scheduledItems: [
                        ScheduledItem(id: 1, name: "Opening Act", description: "Kick off the fair.",
                                      startTime: "2026-07-04T18:00:00+00:00", locationId: 1, locationName: "Main Stage"),
                     ])
        ])
    }
}
