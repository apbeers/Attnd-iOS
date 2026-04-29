// ScheduleView.swift
// Attnd
//
// Full event schedule sorted by start_time.
// A location filter menu lets attendees narrow items to a single venue.

import SwiftUI

struct ScheduleView: View {
    let items: [ScheduledItem]
    let locations: [Location]
    let onRefresh: () async -> Void

    @State private var selectedLocationId: Int? = nil

    private var filteredItems: [ScheduledItem] {
        guard let id = selectedLocationId else { return items }
        return items.filter { $0.locationId == id }
    }

    private var filterLabel: String {
        guard let id = selectedLocationId,
              let loc = locations.first(where: { $0.id == id }) else { return "All Locations" }
        return loc.name
    }

    var body: some View {
        List {
            ForEach(filteredItems) { item in
                ScheduleRowView(item: item, showLocation: selectedLocationId == nil)
            }
        }
        .refreshable { await onRefresh() }
        .navigationTitle("Schedule")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectedLocationId = nil
                    } label: {
                        Label("All Locations", systemImage: selectedLocationId == nil ? "checkmark" : "")
                    }

                    if !locations.isEmpty {
                        Divider()
                        ForEach(locations) { location in
                            Button {
                                selectedLocationId = location.id
                            } label: {
                                Label(
                                    location.name,
                                    systemImage: selectedLocationId == location.id ? "checkmark" : ""
                                )
                            }
                        }
                    }
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                        .symbolVariant(selectedLocationId != nil ? .fill : .none)
                }
            }
        }
        .overlay {
            if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No Schedule",
                    systemImage: "calendar",
                    description: Text(
                        selectedLocationId == nil
                            ? "Schedule items will appear here once loaded."
                            : "No items scheduled at this location."
                    )
                )
            }
        }
    }
}

// MARK: - Row

private struct ScheduleRowView: View {
    let item: ScheduledItem
    let showLocation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(formattedTime(item.startTime))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if showLocation {
                    Text(item.locationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(item.name)
                .font(.headline)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Preview

#Preview {
    NavigationStack {
        ScheduleView(
            items: [
                ScheduledItem(id: 1, name: "Opening Act", description: "Kick off the fair with live music.",
                              startTime: "2026-07-04T18:00:00+00:00", locationId: 1, locationName: "Main Stage"),
                ScheduledItem(id: 2, name: "Food Contest", description: "Who can eat the most?",
                              startTime: "2026-07-04T19:00:00+00:00", locationId: 2, locationName: "Food Court"),
                ScheduledItem(id: 3, name: "Headliner", description: "Main performance of the evening.",
                              startTime: "2026-07-04T20:30:00+00:00", locationId: 1, locationName: "Main Stage"),
            ],
            locations: [
                Location(id: 1, name: "Main Stage", snippet: "", description: "",
                         website: nil, imageUrl: nil, latitude: 0, longitude: 0, address: "", scheduledItems: []),
                Location(id: 2, name: "Food Court", snippet: "", description: "",
                         website: nil, imageUrl: nil, latitude: 0, longitude: 0, address: "", scheduledItems: []),
            ],
            onRefresh: {}
        )
    }
}
