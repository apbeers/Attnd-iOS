// LocationsView.swift
// Attnd

import SwiftUI

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let imageUrl = location.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Color(.systemGray5).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        default:
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(location.name).font(.title2.bold())
                    Text(location.address).font(.subheadline).foregroundStyle(.secondary)

                    Divider()

                    Text(location.description)
                        .font(.body)

                    if let website = location.website, let url = URL(string: website) {
                        Link("Visit Website", destination: url)
                            .font(.subheadline)
                    }

                    // Schedule at this location
                    if !location.scheduledItems.isEmpty {
                        Divider()

                        Text("Schedule")
                            .font(.title3.bold())

                        ForEach(location.scheduledItems) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(formattedTime(item.startTime))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(item.name)
                                    .font(.headline)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formattedTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parserNoFrac = ISO8601DateFormatter()
        parserNoFrac.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso) ?? parserNoFrac.date(from: iso) else { return iso }
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
