// ContentView.swift
// Attnd
//
// AppRootView switches between the launch flow and the joined event.
// ContentView is the tab container for a joined event (TabLayout.swift): the event's own tabs
// (`display.tabs`: Map, Places, Schedule, Flyer, Updates; at most five, so never a "More" tab).
// With the on-device model (app and App Clip) a floating Liquid Glass "My plan" button on every
// tab opens the plan page (AssistantView.swift: the plan, search, the assistant); without it and
// in screenshot mode the floating search button and its sheet instead (on the Map tab the button is the
// last of the map's own trailing column, MapView). Options is a toolbar item on the Updates tab's root
// screen (the first tab's when the event hides Updates, `TabLayout.optionsTab`).
// It also drives bundle refreshes (on becoming active, plus a slow poll while
// active: every 60 s without a push token; a 5-minute safety
// poll when silent `content_updated` pushes can arrive; 15 s after a failure) and
// applies the event's accent colour, falling back to the brand purple asset
// colour (AccentColor).

import SwiftUI
import UIKit

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
                    .onAppear { AppLog.debug(.ui, "ui.screen", "Update required", ["name": "update_required"]) }
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
        // Debug / Dev builds: the reserved-region audit (-AttndDebugRegions YES).
        .overlay { ReservedRegionDebugOverlay() }
        .animation(.easeInOut, value: isLaunching)
        .animation(.easeInOut, value: appState.currentEvent?.id)
        .animation(.easeInOut, value: appState.mustUpdate)
        .animation(.easeInOut, value: appState.showUpdateBanner)
        .onAppear { LaunchTiming.firstFrame() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            AppLog.warning(.lifecycle, "lifecycle.memory_warning", "Memory warning")
        }
        .task {
            await appState.launch()
            isLaunching = false
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            AppLog.setForeground(phase != .background)
            LaunchTiming.scenePhaseChanged(background: phase == .background, active: phase == .active)
            // Location and compass only run while the scene is active (and a screen needs them).
            appState.userLocation.setSceneActive(phase == .active)
            if phase == .active, !isLaunching {
                Task { await appState.checkForUpdate() }
            }
            // Usage counts (API-005) go out before the app may be suspended.
            if phase == .background {
                appState.flushUsage()
                appState.flushPersonalState()
                AppLog.flush()
                // App Clip → full app: settings changed since the last save go into the handover too.
                AppHandover.exportFromClip()
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
        // Batch 7 redesign: a hero in the brand colours, what the update brings, one App Store button.
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.263, green: 0.122, blue: 0.525),
                                                      Color(red: 0.482, green: 0.310, blue: 0.839)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 120, height: 120)
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, options: .nonRepeating)
                }
                .accessibilityHidden(true)
                .padding(.top, 48)

                VStack(spacing: 8) {
                    Text("Time to update Attnd")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(appState.appStatus.message
                         ?? "This version of Attnd is no longer supported. Update to keep following your events.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("What you get")
                        .font(.headline)
                    UpdateFeatureRow(systemImage: "sparkles", text: "The latest features for your events")
                    UpdateFeatureRow(systemImage: "bolt.fill", text: "Live updates from organizers")
                    UpdateFeatureRow(systemImage: "heart.fill", text: "Your schedule and everything you saved, kept")
                }
                .padding(20)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.thinMaterial, in: .rect(cornerRadius: 22))

                Link(destination: appState.appStatus.updateURL ?? appStoreURL) {
                    Label("Update on the App Store", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                if !currentVersion.isEmpty {
                    Text("You have version \(currentVersion).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct UpdateFeatureRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
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

    /// Re-tapping the selected Map tab re-centres the map. The plan page keeps its state
    /// across tabs (its state is the assistant's).
    /// (assumeIsolated: the closures always run on the main actor, whether or not
    /// the SDK declares Binding's closures @Sendable.)
    private var tabSelection: Binding<EventTab> {
        let state = self.appState
        return Binding(
            get: { MainActor.assumeIsolated { state.selectedTab } },
            set: { newTab in
                MainActor.assumeIsolated {
                    if newTab == state.selectedTab, newTab == .map {
                        state.mapCenterToken += 1
                    }
                    state.selectedTab = newTab
                }
            }
        )
    }

    var body: some View {
        @Bindable var state = appState
        // TabLayout: the event's own tabs, at most five, so never a "More" tab. The floating
        // button (My plan with the on-device model, else search) is on every tab (the Map tab
        // places it in its own trailing column, MapTab) and Options a toolbar item on the
        // Updates tab's root screen (else the first tab's).
        TabView(selection: tabSelection) {
            ForEach(appState.tabs) { tab in
                Tab(appState.title(of: tab), systemImage: tab.systemImage, value: tab) {
                    EventTabContent(tab: tab)
                        // Not where the organizer placed the banner as a section (API-027).
                        .latestUpdateBanner(enabled: tab != .notifications && !(tab == .home && appState.placesUpdateBanner(on: .home)))
                        .floatingActionButton(enabled: tab != .map)
                }
                // Updates sent since the tab was last seen (0 hides the badge).
                .badge(tab == .notifications ? appState.unreadUpdatesCount : 0)
            }
        }
        // Rebuilt when the tab set changes (the Home tab arriving with a bundle), so each tab
        // keeps its own icon (TestFlight 161 showed the Map tab with the Places list icon).
        .id(appState.tabs.map(\.rawValue).joined(separator: ","))
        // Organizer updates that arrive while the app is open (AppDelegate.willPresent).
        .overlay(alignment: .top) { InAppBannerOverlay() }
        // The tab bar stays visible (no minimize on scroll).
        .eventTheme(appState)
        .overlay { UndoToastOverlay() }
        .sheet(item: $state.presentedSheet) { sheet in
            Group {
                switch sheet {
                case .search:
                    // Focus the field unless a link or notification opened the sheet on an item. With
                    // the on-device model (outside screenshot mode) this sheet only shows items of
                    // hidden tabs; search is the plan page's text box.
                    EventSearchSheet(focusesSearchField: appState.searchPath.isEmpty)
                case .options:
                    OptionsSheet()
                case .tour:
                    OnboardingView()
                }
            }
            .environment(appState)
            .eventTheme(appState)
        }
        // Foreground: refetch (cheap — the ETag makes it a 304 when nothing changed).
        .onChange(of: scenePhase) { _, phase in
            // API-026: the preview phone's long-poll only while on screen.
            appState.setForeground(phase == .active)
            if phase == .active {
                appState.track(.appOpen)
                // The Live Activity can only start while the app is in the foreground.
                appState.sceneDidBecomeActive()
                Task { await appState.refreshBundle() }
            }
        }
        // Walk minutes in the Live Activity follow the user's position.
        .onChange(of: appState.userLocation.location) {
            appState.userLocationDidChange()
        }
        // The plan page (AssistantView.swift): a full-screen cover over the tabs.
        .fullScreenCover(isPresented: planPageBinding) {
            PlanPageHost()
                .environment(appState)
                .eventTheme(appState)
        }
        // A shared plan link (API-015), once its event's content is shown: a proposal on the
        // plan page ("Use This Plan" / "Merge with Mine").
        .task(id: [appState.pendingSharedPlan?.payload, appState.currentEvent.map { String($0.id) }]) {
            guard let shared = appState.pendingSharedPlan, appState.currentBundle != nil else { return }
            appState.pendingSharedPlan = nil
            appState.assistant.openShared(shared)
        }
        // The onboarding cards after the first join, once the tabs are on screen.
        .task(id: appState.pendingTour) {
            guard appState.pendingTour else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, appState.pendingTour, appState.presentedSheet == nil else { return }
            guard !appState.assistant.pageOpen else { return }
            appState.showTour()
        }
        // Fallback poll while the scene is active and an event is joined (ContentView
        // only exists then); silent `content_updated` pushes do the real work (API-007).
        // The interval (`LiveRefreshPolicy`) restarts the loop when it changes: 60 s
        // without a push token, 5 min with one, 15 s while
        // the last refresh failed. Silent: no spinners.
        .task(id: LivePollKey(phase: scenePhase, eventId: appState.currentEvent?.id, interval: appState.liveRefreshInterval)) {
            guard scenePhase == .active, appState.currentEvent != nil else { return }
            let interval = appState.liveRefreshInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, scenePhase == .active, appState.currentEvent != nil else { break }
                await appState.refreshBundle(silent: true, source: .poll)
            }
        }
    }

    private var planPageBinding: Binding<Bool> {
        let state = self.appState
        return Binding(
            get: { MainActor.assumeIsolated { state.assistant.pageOpen } },
            set: { open in MainActor.assumeIsolated { state.assistant.setPageOpen(open) } }
        )
    }

    private struct LivePollKey: Equatable {
        let phase: ScenePhase
        let eventId: Int?
        let interval: Duration
    }
}

/// One of the event's own tabs.
private struct EventTabContent: View {
    let tab: EventTab

    @Environment(AppState.self) private var appState

    var body: some View {
        switch tab {
        case .home:
            // API-024: the event's `home` layout (ScreenLayoutViews.swift).
            HomeTab()
        case .map:
            MapTab()
        case .locations:
            LocationsTab()
        case .schedule:
            ScheduleTab()
        case .flyer:
            // Unfolded: the flyer and the map side by side (DuoViews.swift).
            FlyerTab()
        case .notifications:
            NavigationStack {
                NotificationsView()
                    // The large title on the bar's own row, beside Options: no empty band above it.
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .optionsToolbarItem(for: .notifications)
            }
        }
    }
}

// MARK: - Newest update banner

extension View {
    /// The newest unread organizer update (sent within 24 h, not dismissed) as a Liquid Glass
    /// card above the tab's content, on every tab except Updates. Tapping it opens the update;
    /// the cross dismisses it (remembered per event). Never in screenshot mode.
    func latestUpdateBanner(enabled: Bool) -> some View {
        modifier(LatestUpdateBannerModifier(enabled: enabled))
    }
}

private struct LatestUpdateBannerModifier: ViewModifier {
    let enabled: Bool

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        // An urgent announcement (API-011, ≤ 12 h, not dismissed) takes the banner's place,
        // prominently; otherwise the newest unread update.
        let urgent = enabled ? appState.urgentBanner() : nil
        let notification = enabled && urgent == nil ? appState.latestUpdateBanner() : nil
        // The banner keeps to one side of a vertical fold (iPhone Duo unfolded): the tab's own
        // container decides which side (ReservedRegionLayout), the banner takes its width.
        GeometryReader { proxy in
            let insets = ReservedRegionLayout.insets(container: proxy.size, avoiding: ReservedRegionReader.rects(in: proxy))
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    Group {
                        if let urgent {
                            UrgentUpdateBanner(notification: urgent)
                                .swipeUpToDismiss { appState.dismissUrgent(urgent.id) }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if let notification {
                            LatestUpdateBanner(notification: notification)
                                .swipeUpToDismiss { appState.dismissLatestUpdate(notification.id) }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .debugFloatingFrame("banner")
                }
                .animation(.easeInOut, value: urgent?.id)
                .animation(.easeInOut, value: notification?.id)
        }
    }
}

// MARK: - Floating search button

extension View {
    /// The floating button of a tab: "My plan" and its page with the on-device model, else search.
    /// `enabled: false` where the screen places `FloatingTabButton` itself (the Map tab's column).
    func floatingActionButton(enabled: Bool = true) -> some View {
        modifier(FloatingActionButtonModifier(enabled: enabled))
    }

    /// The floating Liquid Glass search button in the bottom-trailing corner of a tab, above
    /// its content and the tab bar; it opens the search sheet. The tab's content gets that
    /// much more bottom safe area, so lists scroll clear of it and the map's own floating
    /// column (buttons, selected-location card) sits directly above it. On iPhone Duo it
    /// stays clear of the fold and camera housings (ReservedRegionAvoiding).
    func floatingSearchButton(enabled: Bool = true) -> some View {
        modifier(FloatingSearchButtonModifier(enabled: enabled))
    }
}

enum FloatingSearchButtonMetrics {
    /// The button's diameter.
    static let size: CGFloat = 48
    /// Gap between the button and the bottom of the safe area (the tab bar).
    static let bottomPadding: CGFloat = 8
    /// Centres the button under the map's 44 pt buttons (16 pt from the edge), one column.
    static let trailingPadding: CGFloat = 14
    /// Extra bottom safe area for the tab's content.
    static var reservedHeight: CGFloat { size + bottomPadding }
}

/// The floating button itself (My plan with the on-device model, else search), for screens that
/// lay it out in their own column: the Map tab puts it under the map's buttons, so the two never
/// overlap (the map's overlay doesn't see the extra bottom safe area the modifier adds).
struct FloatingTabButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.hasAssistant {
            FloatingPlanButton(peek: appState.planButtonPeek) {
                appState.openPlanPage()
            }
        } else {
            FloatingSearchButton {
                appState.openSearch()
            }
        }
    }
}

private struct FloatingActionButtonModifier: ViewModifier {
    let enabled: Bool

    @Environment(AppState.self) private var appState

    @ViewBuilder
    func body(content: Content) -> some View {
        // My plan only with the on-device model (planner_view_spec §1); else search.
        if !enabled {
            content
        } else if appState.hasAssistant {
            content.planButton()
        } else {
            content.floatingSearchButton()
        }
    }
}

private struct FloatingSearchButtonModifier: ViewModifier {
    let enabled: Bool

    @Environment(AppState.self) private var appState

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            withButton(content)
        } else {
            content
        }
    }

    private func withButton(_ content: Content) -> some View {
        // Siblings in a ZStack, not an overlay: the extra safe area applies to the content
        // only, so the button itself sits right above the tab bar.
        ZStack {
            content
                .safeAreaPadding(.bottom, FloatingSearchButtonMetrics.reservedHeight)
            ReservedRegionAvoiding {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        FloatingSearchButton {
                            appState.openSearch()
                        }
                        .debugFloatingFrame("search_button")
                        .padding(.trailing, FloatingSearchButtonMetrics.trailingPadding)
                        .padding(.bottom, FloatingSearchButtonMetrics.bottomPadding)
                    }
                }
            }
            // Stays put (under the keyboard) while a tab's own search field is typing.
            .ignoresSafeArea(.keyboard)
        }
    }
}

/// A Liquid Glass circle with a magnifying glass ("Search" for VoiceOver).
struct FloatingSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Search", systemImage: "magnifyingglass")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: FloatingSearchButtonMetrics.size, height: FloatingSearchButtonMetrics.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        // Interactive glass like the map's own buttons (it reacts to touch).
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Search")
        .accessibilityHint("Searches the schedule, places and updates.")
        .keyboardShortcut("f", modifiers: .command)
    }
}

// MARK: - Options toolbar item

extension View {
    /// "Options" (gear) in the navigation bar of `tab`'s root screen, pinned trailing (iPhone
    /// Duo: never moved to the overflow menu), only when `tab` is the Options tab (Updates, else
    /// the first tab: `TabLayout.optionsTab`); it opens Options as a sheet. `separated` adds a
    /// fixed spacer when the screen already has a trailing item (Schedule's filter menu), so
    /// the two unrelated controls get their own glass groups.
    func optionsToolbarItem(for tab: EventTab, separated: Bool = false) -> some View {
        modifier(OptionsToolbarItem(tab: tab, separated: separated))
    }
}

private struct OptionsToolbarItem: ViewModifier {
    let tab: EventTab
    let separated: Bool

    @Environment(AppState.self) private var appState

    @ViewBuilder
    func body(content: Content) -> some View {
        if appState.optionsTab == tab {
            withItem(content)
        } else {
            content
        }
    }

    private func withItem(_ content: Content) -> some View {
        content.toolbar {
            if separated {
                ToolbarSpacer(.fixed, placement: .pinnedTrailing)
            }
            ToolbarItem(placement: .pinnedTrailing) {
                Button {
                    appState.presentedSheet = .options
                } label: {
                    // Icon and title: bars show the icon, vertical bars and accessibility use the title.
                    Label("Options", systemImage: "gearshape")
                }
            }
        }
    }
}

// MARK: - Event status badge

extension View {
    /// Small Liquid Glass capsules at the top of the content (below the navigation bar, so clear
    /// of the status bar and Dynamic Island): "Demo event" / "Event ended", and "Offline ·
    /// Updated 3:41 PM" while refreshes fail (saved content stays on screen). They pass touches
    /// through and never cover content: on list screens (`reservesSpace`, the default) they sit
    /// in a top safe-area inset, so the list (chips first) starts below them and scrolls under
    /// them; over the map (`reservesSpace: false`) they float and the map's chips move down by
    /// `EventStatusBadgeKind.reservedTopHeight`. On iPhone Duo they stay clear of the fold and
    /// camera housings via ReservedRegionAvoiding.
    func eventStatusBanners(reservesSpace: Bool = true) -> some View {
        modifier(EventStatusBadgeModifier(reservesSpace: reservesSpace))
    }
}

/// The top banner for an organizer update received while the app is open: tap opens it in
/// Updates, a swipe up dismisses it (it stays in Updates); gone by itself after a few seconds.
private struct InAppBannerOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ReservedRegionAvoiding {
            VStack {
                if let banner = appState.inAppBanner {
                    Button {
                        appState.dismissInAppBanner()
                        appState.navigate(to: .notification(banner.notificationId))
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: banner.urgent ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                                .font(.title3)
                                .foregroundStyle(banner.urgent ? Color.red : Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                if !banner.title.isEmpty {
                                    Text(banner.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                }
                                if !banner.body.isEmpty {
                                    Text(banner.body).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: 520)
                        .contentShape(.rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .glassEffect(banner.urgent ? Glass.regular.tint(.red.opacity(0.25)).interactive() : Glass.regular.interactive(),
                                 in: .rect(cornerRadius: 22))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .debugFloatingFrame("in_app_banner")
                    .swipeUpToDismiss { appState.dismissInAppBanner() }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: appState.inAppBanner)
        }
    }
}

/// What a floating status badge says.
struct EventStatusBadgeKind: Equatable {
    /// "ended", "refresh", "instant": what a swipe up dismisses (`AppState.dismissedStatusBadges`).
    var id: String = ""
    let title: String
    let systemImage: String
    let accessibilityText: String
    var tint: Color? = nil

    /// Height of one capsule plus its top padding; overlays that also sit at the
    /// top of the content (map category chips) move down by this much per badge.
    static let reservedHeight: CGFloat = 36

    /// Every badge to show, top to bottom (empty in screenshot mode).
    @MainActor
    static func all(_ appState: AppState) -> [EventStatusBadgeKind] {
        [current(appState), refresh(appState), instant(appState)].compactMap { $0 }
            .filter { !appState.dismissedStatusBadges.contains($0.id) }
    }

    /// API-026 preview phone: changes arrive as the organizer makes them (green).
    @MainActor
    static func instant(_ appState: AppState) -> EventStatusBadgeKind? {
        guard !ScreenshotMode.isActive, appState.currentEvent != nil, appState.instantUpdates else { return nil }
        return EventStatusBadgeKind(
            id: "instant",
            title: "Instant updates on",
            systemImage: "bolt.fill",
            accessibilityText: "Instant updates are on: this phone shows the organizer's changes as they make them.",
            tint: .green
        )
    }

    /// Space the badges take at the top of the content.
    @MainActor
    static func reservedTopHeight(_ appState: AppState) -> CGFloat {
        CGFloat(all(appState).count) * Self.reservedHeight
    }

    /// The event's ended state. No demo badge (owner, Nov 21, 2026: the free limit of unpaid
    /// events is the server's, API-025; iOS diverges from API_V2.md's Demo Event banner).
    @MainActor
    static func current(_ appState: AppState) -> EventStatusBadgeKind? {
        guard !ScreenshotMode.isActive, let event = appState.currentEvent, event.isArchived else { return nil }
        return EventStatusBadgeKind(
            id: "ended",
            title: "Event ended",
            systemImage: "flag.checkered",
            accessibilityText: "This event has ended. You can still browse everything."
        )
    }

    /// "Offline · Updated 3:41 PM" (device time zone) while the last refresh failed.
    @MainActor
    static func refresh(_ appState: AppState) -> EventStatusBadgeKind? {
        guard !ScreenshotMode.isActive, appState.currentEvent != nil, let problem = appState.refreshProblem else { return nil }
        return EventStatusBadgeKind(
            id: "refresh",
            title: LastUpdatedText.badgeTitle(problem, lastRefreshed: appState.lastRefreshed),
            systemImage: problem == .offline ? "wifi.slash" : "exclamationmark.icloud",
            accessibilityText: LastUpdatedText.accessibilityText(problem, lastRefreshed: appState.lastRefreshed)
        )
    }
}

private struct EventStatusBadgeModifier: ViewModifier {
    let reservesSpace: Bool

    @Environment(AppState.self) private var appState

    @ViewBuilder
    func body(content: Content) -> some View {
        let kinds = EventStatusBadgeKind.all(appState)
        if reservesSpace {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !kinds.isEmpty {
                        // Clear of the fold on an unfolded iPhone Duo (a full-width list).
                        ReservedRegionAvoiding {
                            badges(kinds)
                        }
                        // Exactly the reserved height per badge (capsule + its top padding),
                        // plus a small gap above the content.
                        .frame(height: EventStatusBadgeKind.reservedTopHeight(appState))
                        .padding(.bottom, 4)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut, value: kinds.map(\.title))
        } else {
            content.overlay(alignment: .top) {
                if !kinds.isEmpty {
                    ReservedRegionAvoiding {
                        VStack(spacing: 0) {
                            badges(kinds)
                            Spacer(minLength: 0)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    /// The capsules, top to bottom, centred; `reservedHeight` (36) each.
    private func badges(_ kinds: [EventStatusBadgeKind]) -> some View {
        // One container so stacked capsules share their glass and blend.
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 0) {
                ForEach(kinds, id: \.title) { kind in
                    EventStatusBadge(kind: kind)
                        // Follows the finger up and slides off (batch 7); Options → Status keeps the info.
                        .swipeUpToDismiss { _ = appState.dismissedStatusBadges.insert(kind.id) }
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
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
            // Liquid Glass capsule; only the capsule takes touches (a swipe up dismisses it).
            .foregroundStyle(kind.tint ?? Color.primary)
            .glassEffect(kind.tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? Glass.regular, in: .capsule)
            .contentShape(.capsule)
            .debugFloatingFrame("status_\(kind.id)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityText)
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
