// ContentView.swift
// Attnd
//
// AppRootView switches between the launch flow and the joined event.
// ContentView is the tab container for a joined event: the tabs, their order and
// the initial tab come from the server's `display` config; Options is always last.
// It also drives bundle refreshes (foreground, every 5 minutes on event days)
// and applies the event's accent colour.

import SwiftUI

// MARK: - Root

/// Shared by the app and the App Clip. Silently rejoins the saved event on launch.
struct AppRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isLaunching = true

    var body: some View {
        Group {
            if isLaunching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.currentEvent != nil {
                ContentView()
                    .transition(.opacity)
            } else {
                LaunchScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: isLaunching)
        .animation(.easeInOut, value: appState.currentEvent?.id)
        .task {
            await appState.launch()
            isLaunching = false
        }
    }
}

// MARK: - Tabs

struct ContentView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    private static let refreshInterval: Duration = .seconds(5 * 60)

    /// Re-tapping the selected Map tab re-centres the map.
    /// (assumeIsolated: the closures always run on the main actor, whether or not
    /// the SDK declares Binding's closures @Sendable.)
    private var tabSelection: Binding<MainTab> {
        let state = self.appState
        return Binding(
            get: { MainActor.assumeIsolated { state.selectedTab } },
            set: { newTab in
                MainActor.assumeIsolated {
                    if newTab == .event(.map), state.selectedTab == .event(.map) {
                        state.mapCenterToken += 1
                    }
                    state.selectedTab = newTab
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(appState.tabs) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: MainTab.event(tab)) {
                    tabContent(tab)
                }
            }
            Tab("Options", systemImage: "gearshape", value: MainTab.options) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(accentColor)
        // Foreground: refetch (cheap — the ETag makes it a 304 when nothing changed).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await appState.refreshBundle() }
            }
        }
        // Every 5 minutes while in the foreground on event days.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { break }
                if appState.isEventDay() {
                    await appState.refreshBundle()
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: EventTab) -> some View {
        switch tab {
        case .map:
            MapTab()
        case .locations:
            LocationsTab()
        case .schedule:
            ScheduleTab()
        case .flyer:
            NavigationStack {
                FlyerView(flyerUrl: appState.currentEvent?.flyerUrl)
                    .eventStatusBanners()
            }
        case .notifications:
            NavigationStack {
                NotificationsView()
            }
        }
    }

    private var accentColor: Color? {
        HexColor.components(appState.accentHex).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

// MARK: - Event status banners

extension View {
    /// Pins the Demo Event / event-ended banners below the navigation bar.
    func eventStatusBanners() -> some View {
        modifier(EventStatusBannersModifier())
    }
}

private struct EventStatusBannersModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let event = appState.currentEvent, event.isDemo || event.isArchived {
                VStack(spacing: 0) {
                    if event.isDemo {
                        EventStatusBanner(
                            title: "Demo Event",
                            message: "This is a preview, not a live event.",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }
                    if event.isArchived {
                        EventStatusBanner(
                            title: "This event has ended",
                            message: "You can still browse everything.",
                            systemImage: "flag.checkered",
                            tint: .gray
                        )
                    }
                }
            }
        }
    }
}

private struct EventStatusBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(message).font(.caption)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(tint.gradient)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
