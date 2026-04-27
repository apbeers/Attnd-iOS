// NotificationsView.swift
// Attnd

import SwiftUI

struct NotificationsView: View {
    let notifications: [AppNotification]

    init(notifications: [AppNotification] = []) {
        self.notifications = notifications
    }

    var body: some View {
        List(notifications) { notification in
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

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return iso
    }
}

#Preview {
    NavigationStack {
        NotificationsView(notifications: [
            AppNotification(id: 1, title: "Gate B is now open",
                            body: "Head to Gate B for faster entry.",
                            sendTime: "2026-06-15T17:45:00+00:00", sent: true)
        ])
    }
}
