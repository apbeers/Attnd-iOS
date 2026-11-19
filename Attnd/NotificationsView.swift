// NotificationsView.swift
// Attnd
//
// Organizer notifications for the joined event, newest first, from the bundle.
// Times are shown in the event's time zone. A jump (search, a link, a notification) scrolls to
// one notification and highlights it briefly. While it is on screen everything listed counts
// as seen (`AppState.markUpdatesSeen`: the tab's unread badge and the update banner clear).

import SwiftUI

struct NotificationsView: View {
    /// Scroll to and briefly highlight this notification on appear (pushed from search when
    /// the Updates tab is hidden). The Updates tab itself follows `AppState.focusRequest`.
    var focusId: Int? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var highlightedId: Int?
    /// On screen: what it lists counts as seen (the tab's unread badge and the banner clear).
    @State private var isVisible = false

    /// How long a jumped-to notification stays highlighted.
    private static let highlightDuration: Duration = .seconds(2)

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(appState.notifications) { notification in
                    NotificationRow(notification: notification, timeZone: appState.timeZone)
                        .listRowBackground(rowBackground(notification))
                        // Assistant spec §8 ("Ask about this"; for now the search sheet with its title).
                        .contextMenu {
                            if appState.hasAssistant {
                                Button("Ask About This", systemImage: "sparkles") {
                                    appState.askAbout(.notification(notification.id))
                                }
                            }
                        }
                }
            }
            .onAppear {
                if let focusId { show(focusId, proxy: proxy) }
            }
            .onChange(of: appState.focusRequest, initial: true) {
                guard focusId == nil, case .notification(let id)? = appState.focusRequest else { return }
                appState.focusRequest = nil
                show(id, proxy: proxy)
            }
        }
        .navigationTitle("Updates")
        .onAppear {
            isVisible = true
            appState.markUpdatesSeen()
        }
        .onDisappear { isVisible = false }
        .onChange(of: appState.notifications) {
            if isVisible, scenePhase == .active { appState.markUpdatesSeen() }
        }
        .onChange(of: scenePhase) { _, phase in
            if isVisible, phase == .active { appState.markUpdatesSeen() }
        }
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

    /// The jump highlight, else a red tint for urgent updates (API-011), else the default.
    private func rowBackground(_ notification: AppNotification) -> AnyView? {
        if highlightedId == notification.id { return AnyView(Rectangle().fill(.tint.opacity(0.18))) }
        if notification.isUrgent { return AnyView(Rectangle().fill(Color.red.opacity(0.12))) }
        return nil
    }

    /// Scrolls `id` to the middle and highlights it for a moment.
    private func show(_ id: Int, proxy: ScrollViewProxy) {
        highlightedId = id
        Task { @MainActor in
            // Let the list lay out first (the tab may have just been created).
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            try? await Task.sleep(for: Self.highlightDuration)
            withAnimation {
                if highlightedId == id { highlightedId = nil }
            }
        }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if notification.isUrgent {
                // API-011: cancellations, safety notices.
                Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
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
