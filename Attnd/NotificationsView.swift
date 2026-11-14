// NotificationsView.swift
// Attnd
//
// Organizer notifications for the joined event, newest first, from the bundle.
// Times are shown in the event's time zone.

import SwiftUI

struct NotificationsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            ForEach(appState.notifications) { notification in
                NotificationRow(notification: notification, timeZone: appState.timeZone)
            }
        }
        .navigationTitle("Updates")
        .refreshable { await appState.pullToRefresh() }
        .eventStatusBanners()
        .overlay {
            if appState.notifications.isEmpty {
                if appState.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Updates Yet",
                        systemImage: "bell.slash",
                        description: Text("Announcements from the organizer will appear here.")
                    )
                }
            }
        }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(notification.title)
                .font(.headline)
            if !notification.body.isEmpty {
                Text(notification.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let sent = notification.sendTime {
                Text(EventTimeFormat.shortDayTime(sent, in: timeZone))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        NotificationsView()
    }
    .environment(AppState())
}
