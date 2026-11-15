// ContentView.swift
// Attnd
//
// AppRootView switches between the launch flow and the joined event.
// ContentView is the tab container for a joined event: the tabs, their order and
// the initial tab come from the server's `display` config; Options is always last.
// It also drives bundle refreshes (on becoming active, plus a slow poll while
// active: every 60 s without a push token, e.g. the App Clip; a 5-minute safety
// poll when silent `content_updated` pushes can arrive; 15 s after a failure) and
// applies the event's accent colour, falling back to the brand purple asset
// colour (AccentColor).

import SwiftUI

// MARK: - Root

/// Shared by the app and the App Clip. Silently rejoins the saved event on launch.
struct AppRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLaunching = true

    var body: some View {
        Group {
            if ScreenshotMode.current?.screen == .orientationProbe {
                ScreenshotOrientationProbe()
            } else if appState.mustUpdate {
                UpdateRequiredView()
                    .transition(.opacity)
            } else if isLaunching {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.showUpdateBanner && !appState.mustUpdate {
                UpdateAvailableBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: isLaunching)
        .animation(.easeInOut, value: appState.currentEvent?.id)
        .animation(.easeInOut, value: appState.mustUpdate)
        .animation(.easeInOut, value: appState.showUpdateBanner)
        .task {
            await appState.launch()
            isLaunching = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isLaunching {
                Task { await appState.checkForUpdate() }
            }
            // Usage counts (API-005) go out before the app may be suspended.
            if phase == .background {
                appState.flushUsage()
            }
        }
    }
}

/// Screenshot mode's `orientation-probe` screen: red top half, blue bottom half, edge to edge.
/// `compose_screenshots.py` uses its capture to rotate a display's captures upright.
private struct ScreenshotOrientationProbe: View {
    var body: some View {
        VStack(spacing: 0) {
            Color(red: 1, green: 0, blue: 0)
            Color(red: 0, green: 0, blue: 1)
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }
}

// MARK: - Updates (API-003)

/// Fallback when the server doesn't send an `update_url`.
private let appStoreURL = URL(string: "https://apps.apple.com/app/id1470627406")!

/// Shown instead of everything else when the server says this build must update.
struct UpdateRequiredView: View {
    @Environment(AppState.self) private var appState

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        ContentUnavailableView {
            Label("Update Attnd", systemImage: "arrow.down.app")
        } description: {
            Text(appState.appStatus.message
                 ?? "This version of Attnd is no longer supported. Update to the latest version to keep following your events.")
            if !currentVersion.isEmpty {
                Text("You have version \(currentVersion).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Link(destination: appState.appStatus.updateURL ?? appStoreURL) {
                Label("Update", systemImage: "arrow.up.forward.app")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
    }
}

/// A dismissible banner when a newer version exists but this one still works.
struct UpdateAvailableBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
                .foregroundStyle(.tint)
            Text(appState.appStatus.message ?? "A new version of Attnd is available.")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Link("Update", destination: appState.appStatus.updateURL ?? appStoreURL)
                .font(.subheadline.weight(.semibold))
            Button {
                appState.dismissUpdateBanner()
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Liquid Glass: a floating card above the content instead of an opaque custom bar.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// MARK: - Tabs

struct ContentView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

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
            // The system search tab: set apart at the trailing end of the tab bar and
            // expanding into the search field (Liquid Glass). Searches the whole event,
            // including tabs the organizer hid.
            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search, role: .search) {
                EventSearchTab()
            }
        }
        // The tab bar shrinks while lists scroll down and comes back on scroll up.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(accentColor ?? Color.accentColor)
        // Foreground: refetch (cheap — the ETag makes it a 304 when nothing changed).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appState.track(.appOpen)
                Task { await appState.refreshBundle() }
            }
        }
        // Fallback poll while the scene is active and an event is joined (ContentView
        // only exists then); silent `content_updated` pushes do the real work (API-007).
        // The interval (`LiveRefreshPolicy`) restarts the loop when it changes: 60 s
        // without a push token (always in the App Clip), 5 min with one, 15 s while
        // the last refresh failed. Silent: no spinners.
        .task(id: LivePollKey(phase: scenePhase, eventId: appState.currentEvent?.id, interval: appState.liveRefreshInterval)) {
            guard scenePhase == .active, appState.currentEvent != nil else { return }
            let interval = appState.liveRefreshInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, scenePhase == .active, appState.currentEvent != nil else { break }
                await appState.refreshBundle(silent: true)
            }
        }
    }

    private struct LivePollKey: Equatable {
        let phase: ScenePhase
        let eventId: Int?
        let interval: Duration
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

    /// The event's own accent; nil → the asset AccentColor (brand purple #431F86).
    private var accentColor: Color? {
        HexColor.components(appState.accentHex).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

// MARK: - Event status badge

extension View {
    /// Floats small Liquid Glass capsules at the top of the content (below the navigation bar,
    /// so clear of the status bar and Dynamic Island): "Demo event" / "Event ended",
    /// and "Offline · Updated 3:41 PM" while refreshes fail (saved content stays on
    /// screen). Content scrolls underneath; they never take layout space and pass
    /// touches through. On iPhone Duo they stay clear of the fold and camera housings
    /// via ReservedRegionAvoiding.
    func eventStatusBanners() -> some View {
        modifier(EventStatusBadgeModifier())
    }
}

/// What a floating status badge says.
struct EventStatusBadgeKind: Equatable {
    let title: String
    let systemImage: String
    let accessibilityText: String

    /// Height of one capsule plus its top padding; overlays that also sit at the
    /// top of the content (map category chips) move down by this much per badge.
    static let reservedHeight: CGFloat = 36

    /// Every badge to show, top to bottom (empty in screenshot mode).
    @MainActor
    static func all(_ appState: AppState) -> [EventStatusBadgeKind] {
        [current(appState), refresh(appState)].compactMap { $0 }
    }

    /// Space the badges take at the top of the content.
    @MainActor
    static func reservedTopHeight(_ appState: AppState) -> CGFloat {
        CGFloat(all(appState).count) * Self.reservedHeight
    }

    /// The event's demo / ended state.
    @MainActor
    static func current(_ appState: AppState) -> EventStatusBadgeKind? {
        // App Store screenshots show the demo event's content without the badge.
        guard !ScreenshotMode.isActive, let event = appState.currentEvent else { return nil }
        switch (event.isDemo, event.isArchived) {
        case (true, true):
            return EventStatusBadgeKind(
                title: "Demo event · Ended",
                systemImage: "exclamationmark.triangle.fill",
                accessibilityText: "Demo event. This is a preview, not a live event. The event has ended."
            )
        case (true, false):
            return EventStatusBadgeKind(
                title: "Demo event",
                systemImage: "exclamationmark.triangle.fill",
                accessibilityText: "Demo event. This is a preview, not a live event."
            )
        case (false, true):
            return EventStatusBadgeKind(
                title: "Event ended",
                systemImage: "flag.checkered",
                accessibilityText: "This event has ended. You can still browse everything."
            )
        case (false, false):
            return nil
        }
    }

    /// "Offline · Updated 3:41 PM" (device time zone) while the last refresh failed.
    @MainActor
    static func refresh(_ appState: AppState) -> EventStatusBadgeKind? {
        guard !ScreenshotMode.isActive, appState.currentEvent != nil, let problem = appState.refreshProblem else { return nil }
        return EventStatusBadgeKind(
            title: LastUpdatedText.badgeTitle(problem, lastRefreshed: appState.lastRefreshed),
            systemImage: problem == .offline ? "wifi.slash" : "exclamationmark.icloud",
            accessibilityText: LastUpdatedText.accessibilityText(problem, lastRefreshed: appState.lastRefreshed)
        )
    }
}

private struct EventStatusBadgeModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            let kinds = EventStatusBadgeKind.all(appState)
            if !kinds.isEmpty {
                ReservedRegionAvoiding {
                    // One container so stacked capsules share their glass and blend.
                    GlassEffectContainer(spacing: 6) {
                        VStack(spacing: 0) {
                            ForEach(kinds, id: \.title) { kind in
                                EventStatusBadge(kind: kind)
                                    .padding(.top, 6)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

private struct EventStatusBadge: View {
    let kind: EventStatusBadgeKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            // Liquid Glass capsule (not interactive: touches pass through the badges).
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityText)
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
