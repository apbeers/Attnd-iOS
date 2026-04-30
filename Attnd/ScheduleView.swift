// ScheduleView.swift
// Attnd
//
// Full event schedule sorted by start_time.
// Filter menu: hide past items (default on) + filter by location.
// Tapping a row navigates to that location's detail page.
// Countdown labels update live via TimelineView (no manual refresh needed).

import SwiftUI

struct ScheduleView: View {
    let items: [ScheduledItem]
    let locations: [Location]
    let onRefresh: () async -> Void

    @State private var selectedLocationId: Int? = nil
    @State private var hideEnded: Bool = true

    private static let endedGrace: TimeInterval = 3600

    private func filteredItems(now: Date) -> [ScheduledItem] {
        var result = items
        if hideEnded {
            let cutoff = now.addingTimeInterval(-Self.endedGrace)
            result = result.filter { parsedDate($0.startTime) >= cutoff }
        }
        if let id = selectedLocationId {
            result = result.filter { $0.locationId == id }
        }
        return result
    }

    private var filterLabel: String {
        guard let id = selectedLocationId,
              let loc = locations.first(where: { $0.id == id }) else { return "All Locations" }
        return loc.name
    }

    var body: some View {
        // TimelineView fires every 30 s — all countdown labels update automatically.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let visible = filteredItems(now: now)

            List {
                ForEach(visible) { item in
                    let matchedLocation = locations.first(where: { $0.id == item.locationId })
                    Group {
                        if let loc = matchedLocation {
                            NavigationLink(value: loc) {
                                ScheduleRowView(item: item, showLocation: selectedLocationId == nil, now: now)
                            }
                        } else {
                            ScheduleRowView(item: item, showLocation: selectedLocationId == nil, now: now)
                        }
                    }
                }
            }
            .refreshable { await onRefresh() }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            hideEnded.toggle()
                        } label: {
                            Label(
                                hideEnded ? "Show All Items" : "Hide Ended Items",
                                systemImage: hideEnded ? "eye" : "eye.slash"
                            )
                        }

                        Divider()

                        Button { selectedLocationId = nil } label: {
                            Label("All Locations", systemImage: selectedLocationId == nil ? "checkmark" : "")
                        }

                        if !locations.isEmpty {
                            Divider()
                            ForEach(locations) { location in
                                Button { selectedLocationId = location.id } label: {
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
                            .symbolVariant(selectedLocationId != nil || !hideEnded ? .fill : .none)
                    }
                }
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(
                        hideEnded ? "All Done!" : "No Schedule",
                        systemImage: hideEnded ? "checkmark.circle" : "calendar",
                        description: Text(emptyMessage)
                    )
                }
            }
        }
    }

    private var emptyMessage: String {
        if hideEnded && selectedLocationId != nil {
            return "No upcoming items at this location. Tap the filter to show all."
        } else if hideEnded {
            return "No upcoming items. Tap the filter to see past items."
        } else if selectedLocationId != nil {
            return "No items scheduled at this location."
        } else {
            return "Schedule items will appear here once loaded."
        }
    }

    private func parsedDate(_ iso: String) -> Date {
        let p1 = ISO8601DateFormatter()
        p1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let p2 = ISO8601DateFormatter()
        p2.formatOptions = [.withInternetDateTime]
        return p1.date(from: iso) ?? p2.date(from: iso) ?? .distantPast
    }
}

// MARK: - Row

private struct ScheduleRowView: View {
    let item: ScheduledItem
    let showLocation: Bool
    let now: Date

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
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.headline)
                if let countdown = item.startsInText(relativeTo: now) {
                    Spacer()
                    Text(countdown)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.tint)
                }
            }
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
