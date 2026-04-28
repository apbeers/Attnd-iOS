// NotificationsView.swift
// Attnd

import SwiftUI

struct NotificationsView: View {
    let notifications: [AppNotification]
    let onRefresh: () async -> Void

    @State private var lastRefreshed: Date = .now
    private let staleThreshold: TimeInterval = 5 * 60  // 5 minutes

    private var isStale: Bool {
        Date.now.timeIntervalSince(lastRefreshed) > staleThreshold
    }

    init(
        notifications: [AppNotification] = [],
        onRefresh: @escaping () async -> Void = {}
    ) {
        self.notifications = notifications
        self.onRefresh = onRefresh
    }

    var body: some View {
        List {
            // Stale banner — shown when data is more than 5 minutes old
            if isStale {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                    Text("Last refreshed over 5 minutes ago — pull down to refresh")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.vertical, 4)
            }

            ForEach(notifications) { notification in
                VStack(alignment: .leading, spacing: 6) {
                    Text(notification.title)
                        .font(.headline)
                    Text(notification.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(formattedDate(notification.sendTime))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
        .refreshable {
            await onRefresh()
            lastRefreshed = .now
        }
        .navigationTitle("Notifications")
        .overlay {
            if notifications.isEmpty {
                ContentUnavailableView(
                    "No Notifications",
                    systemImage: "bell.slash",
                    description: Text("Notifications will appear here once sent.")
                )
            }
        }
    }

    /// Returns a string like "Monday, 3:45 PM" in the device's local timezone.
    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Also try without fractional seconds for flexibility
        let parserNoFrac = ISO8601DateFormatter()
        parserNoFrac.formatOptions = [.withInternetDateTime]

        guard let date = parser.date(from: iso) ?? parserNoFrac.date(from: iso) else {
            return iso
        }

        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.timeZone = .current
        fmt.dateFormat = "EEEE, h:mm a"   // e.g. "Monday, 3:45 PM"
        return fmt.string(from: date)
    }
}

#Preview {
    NavigationStack {
        NotificationsView(
            notifications: [
                AppNotification(id: 1, title: "Gate B is now open",
                                body: "Head to Gate B for faster entry.",
                                sendTime: "2026-06-15T17:45:00+00:00", sent: true),
                AppNotification(id: 2, title: "Main stage starting soon",
                                body: "The headliner takes the stage in 15 minutes.",
                                sendTime: "2026-06-15T21:00:00+00:00", sent: true),
            ]
        )
    }
}
