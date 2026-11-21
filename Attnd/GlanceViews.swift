// GlanceViews.swift
// Attnd
//
// The runtime side of the glance features (the rules are in Glance.swift):
//   - UserLocationTracker: the user's position and compass heading, only while a screen that
//     shows distances / arrows is visible (`usesUserLocation(heading:)`) and the scene is
//     active. It never asks for permission itself: distances appear once the user has allowed
//     location (Launch screen, the map's location button).
//   - WalkingRouteProvider: walking routes for the map card (MKDirections, .walking), cached
//     per location until the user moves more than 50 m.
//   - DistanceBadge ("0.6 mi" + compass arrow), HeartButton / HeartToolbarItem, the newest-update
//     banner, the map's "now playing" strip, the in-progress bar and the long-press peek cards.

import CoreLocation
import MapKit
import SwiftUI
import UIKit

// MARK: - Location + heading

@MainActor
@Observable
final class UserLocationTracker {
    /// The latest fix while tracking (kept after tracking stops, cleared when access is revoked).
    private(set) var location: Coordinate?
    /// Horizontal accuracy of `location` in metres.
    private(set) var accuracy: Double?
    /// When `location` was measured (the Live Activity uses positions ≤ 30 min old).
    @ObservationIgnored private(set) var locationAt: Date?
    /// Heading of the top of the UI, degrees from true north (magnetic when true north is
    /// unavailable); nil without a compass reading.
    private(set) var heading: Double?
    private(set) var isAuthorized = false
    /// False with "Approximate Location": no arrows (they'd point at a fuzzy position).
    private(set) var isPrecise = true

    /// Arrows only with a heading and a precise enough fix.
    var showsArrows: Bool {
        heading != nil && isPrecise && (accuracy ?? .infinity) <= Self.maxArrowAccuracy
    }

    static let maxArrowAccuracy = 100.0
    /// At most ~5 heading updates a second reach the UI.
    static let headingInterval: TimeInterval = 0.2

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var delegate: TrackerDelegate?
    /// Visible screens using the location, and whether each wants the heading too.
    @ObservationIgnored private var users: [UUID: Bool] = [:]
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var updatingLocation = false
    @ObservationIgnored private var updatingHeading = false
    /// iOS 27: heading is relative to our window (`headingBody`), already matching the UI.
    @ObservationIgnored private var headingFollowsWindow = false
    @ObservationIgnored private var lastHeadingAt = Date.distantPast

    /// Where `target` is from the user, or nil (no permission, no fix, no coordinate).
    func direction(to target: Coordinate?) -> TargetDirection? {
        guard isAuthorized, let user = location, let target else { return nil }
        return TargetDirection(from: user, to: target)
    }

    func begin(_ id: UUID, heading: Bool) {
        users[id] = heading
        update()
    }

    func end(_ id: UUID) {
        users[id] = nil
        update()
    }

    /// AppRootView: stop everything while the scene isn't active.
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        update()
    }

    private func update() {
        // Screenshot mode never shows the user's position.
        let wanted = sceneActive && !users.isEmpty && !ScreenshotMode.isActive
        if wanted, manager == nil { makeManager() }
        guard let manager else { return }
        let runLocation = wanted && isAuthorized
        if runLocation != updatingLocation {
            updatingLocation = runLocation
            if runLocation { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
            AppLog.debug(.location, "location.updates", runLocation ? "Location updates on" : "Location updates off", [
                "on": .bool(runLocation), "heading": .bool(runLocation && users.values.contains(true)), "consumers": .int(users.count),
            ])
        }
        let runHeading = runLocation && users.values.contains(true) && CLLocationManager.headingAvailable()
        if runHeading != updatingHeading {
            updatingHeading = runHeading
            if runHeading {
                AppLog.debug(.location, "location.heading.source", "Compass: CLHeading", ["source": "clheading"])
                attachHeadingToWindow(manager)
                manager.startUpdatingHeading()
            } else {
                manager.stopUpdatingHeading()
                heading = nil
            }
        }
    }

    private func makeManager() {
        let manager = CLLocationManager()
        let delegate = TrackerDelegate(owner: self)
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.activityType = .fitness
        manager.headingFilter = 2
        self.manager = manager
        self.delegate = delegate
        applyAuthorization(status: manager.authorizationStatus, precise: manager.accuracyAuthorization == .fullAccuracy)
    }

    private func attachHeadingToWindow(_ manager: CLLocationManager) {
        #if IOS27_SDK
        if #available(iOS 27.0, *), let window = Self.activeWindowScene()?.keyWindow {
            manager.headingBody = window
            headingFollowsWindow = true
            return
        }
        #endif
        headingFollowsWindow = false
    }

    // MARK: Delegate events (main actor)

    fileprivate func applyAuthorization(status: CLAuthorizationStatus, precise: Bool) {
        let authorized = status == .authorizedWhenInUse || status == .authorizedAlways
        if isAuthorized != authorized || isPrecise != precise {
            AppLog.notice(.location, "location.permission", "Location permission: \(status.logName)",
                          locationPermissionFields(status, precise: precise, asked: false))
        }
        if isAuthorized != authorized { isAuthorized = authorized }
        if isPrecise != precise { isPrecise = precise }
        if !authorized {
            location = nil
            accuracy = nil
            locationAt = nil
            heading = nil
        }
        update()
    }

    fileprivate func applyLocation(latitude: Double, longitude: Double, accuracy: Double, at timestamp: Date) {
        guard updatingLocation, accuracy >= 0, let coordinate = Coordinate.valid(latitude: latitude, longitude: longitude) else { return }
        location = coordinate
        self.accuracy = accuracy
        locationAt = timestamp
    }

    fileprivate func applyHeading(trueHeading: Double, magneticHeading: Double, headingAccuracy: Double) {
        guard updatingHeading else { return }
        guard headingAccuracy >= 0 else {
            heading = nil
            return
        }
        let now = Date.now
        guard now.timeIntervalSince(lastHeadingAt) >= Self.headingInterval else { return }
        lastHeadingAt = now
        let raw = trueHeading >= 0 ? trueHeading : magneticHeading
        let rotation = headingFollowsWindow ? 0 : Self.interfaceRotation()
        heading = Compass.interfaceHeading(deviceHeading: raw, interfaceRotation: rotation)
    }

    // MARK: Interface orientation (iOS 26: Core Location reports the device's portrait top)

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Degrees the interface is rotated clockwise from portrait: landscape-right UI = device's
    /// right edge up (+90), upside down (+180), landscape-left UI = left edge up (+270).
    /// Not used for layout.
    private static func interfaceRotation() -> Double {
        switch activeWindowScene()?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight?:     return 90
        case .portraitUpsideDown?: return 180
        case .landscapeLeft?:      return 270
        default:                   return 0
        }
    }
}

/// Core Location's delegate. Callbacks are nonisolated; only Sendable values cross to the main actor.
@MainActor
private final class TrackerDelegate: NSObject, CLLocationManagerDelegate {
    weak var owner: UserLocationTracker?

    init(owner: UserLocationTracker) {
        self.owner = owner
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let precise = manager.accuracyAuthorization == .fullAccuracy
        Task { @MainActor in self.owner?.applyAuthorization(status: status, precise: precise) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let latitude = last.coordinate.latitude
        let longitude = last.coordinate.longitude
        let accuracy = last.horizontalAccuracy
        let timestamp = last.timestamp
        Task { @MainActor in self.owner?.applyLocation(latitude: latitude, longitude: longitude, accuracy: accuracy, at: timestamp) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let trueHeading = newHeading.trueHeading
        let magneticHeading = newHeading.magneticHeading
        let headingAccuracy = newHeading.headingAccuracy
        Task { @MainActor in
            self.owner?.applyHeading(trueHeading: trueHeading, magneticHeading: magneticHeading, headingAccuracy: headingAccuracy)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (no fix yet) or denied; authorization changes arrive separately.
        let ns = error as NSError
        // kCLErrorLocationUnknown (0) is "no fix yet": not worth a warning.
        AppLog.log(ns.code == 0 ? .debug : .warning, .location, "location.error", "Location updates failed", [
            "error": .string(ns.localizedDescription), "domain": .string(ns.domain), "code": .int(ns.code),
        ])
    }
}

extension View {
    /// Tracks the user's position (and the compass heading when `heading`) while this view is
    /// visible and `active`. Nothing runs without location permission or in the background.
    func usesUserLocation(heading: Bool, active: Bool = true) -> some View {
        modifier(UserLocationUsage(heading: heading, active: active))
    }
}

private struct UserLocationUsage: ViewModifier {
    let heading: Bool
    let active: Bool

    @Environment(AppState.self) private var appState
    @State private var id = UUID()
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                apply()
            }
            .onDisappear {
                isVisible = false
                appState.userLocation.end(id)
            }
            .onChange(of: active) { apply() }
            .onChange(of: heading) { apply() }
    }

    private func apply() {
        if isVisible, active {
            appState.userLocation.begin(id, heading: heading)
        } else {
            appState.userLocation.end(id)
        }
    }
}

// MARK: - Walking routes (map card)

@MainActor
@Observable
final class WalkingRouteProvider {
    private(set) var cache = RouteCache()
    @ObservationIgnored private var inflight: MKDirections?

    private struct RouteResult: Sendable {
        var points: [Coordinate]
        var seconds: TimeInterval
        var meters: Double
    }

    func route(for locationId: Int, from user: Coordinate) -> WalkRoute? {
        cache.route(for: locationId, from: user)
    }

    /// Computes the walking route unless one from within 50 m is cached. Never starts navigation.
    func load(locationId: Int, from user: Coordinate, to destination: Coordinate) async {
        guard cache.needsRoute(for: locationId, from: user) else { return }
        inflight?.cancel()
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: user.latitude, longitude: user.longitude), address: nil)
        request.destination = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude),
            address: nil
        )
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        inflight = directions
        let result: RouteResult? = await withCheckedContinuation { continuation in
            // The handler runs on the main thread; only plain values leave it.
            directions.calculate { response, _ in
                guard let route = response?.routes.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let polyline = route.polyline
                let count = polyline.pointCount
                var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
                if count > 0 {
                    polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
                }
                let points = coordinates.compactMap { Coordinate.valid(latitude: $0.latitude, longitude: $0.longitude) }
                continuation.resume(returning: RouteResult(points: points, seconds: route.expectedTravelTime, meters: route.distance))
            }
        }
        // A newer request (another pin) replaced this one: keep nothing.
        guard inflight === directions else { return }
        inflight = nil
        guard !Task.isCancelled else { return }
        cache.store(WalkRoute.make(
            locationId: locationId,
            origin: user,
            destination: destination,
            routePoints: result?.points,
            routeSeconds: result?.seconds,
            routeMeters: result?.meters
        ))
    }

    func clear() {
        inflight?.cancel()
        inflight = nil
        cache.removeAll()
    }
}

// MARK: - Distance + compass arrow

/// "0.6 mi ↗" from the user to `target` (the arrow turns with the phone), "Here" within ~20 m;
/// nothing without location permission or a coordinate. VoiceOver: "Northeast, 0.6 miles".
struct DistanceBadge: View {
    let target: Coordinate?
    var font: Font = .caption

    @Environment(AppState.self) private var appState

    var body: some View {
        let tracker = appState.userLocation
        if let direction = tracker.direction(to: target) {
            let imperial = DistanceText.usesImperial()
            HStack(spacing: 3) {
                Text(direction.text(imperial: imperial))
                    .monospacedDigit()
                if tracker.showsArrows, let rotation = direction.arrowRotation(heading: tracker.heading) {
                    CompassArrow(rotation: rotation)
                }
            }
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(direction.accessibilityText(imperial: imperial))
        }
    }
}

/// An arrow rotated `rotation` degrees clockwise from straight up; turns the short way round.
struct CompassArrow: View {
    let rotation: Double
    @State private var angle: Double?

    var body: some View {
        Image(systemName: "location.north.fill")
            .imageScale(.small)
            .foregroundStyle(.tint)
            .rotationEffect(.degrees(angle ?? rotation))
            .accessibilityHidden(true)
            .onAppear { if angle == nil { angle = rotation } }
            .onChange(of: rotation) { _, new in
                let current = angle ?? new
                var delta = Compass.normalized(new - Compass.normalized(current))
                if delta > 180 { delta -= 360 }
                withAnimation(.easeOut(duration: 0.2)) { angle = current + delta }
            }
    }
}

// MARK: - My schedule button (the heart)

/// The heart for a location or schedule item (rows, cards, peeks, search, map card, Home, chat
/// cards; owner, Nov 21, 2026: the heart icon again): outline = not in My schedule, filled = in
/// it. Tapping the outline adds it at once (places as a saved place without a time; no "When?"),
/// with a haptic and an Undo toast; the filled heart opens the entry's menu (Set a time… for
/// places, the reminder, Remove). Borderless, so it works inside list rows without opening them.
/// Icon-only by default (rows); `titled` shows the words (details, cards).
struct HeartButton: View {
    let target: SearchTarget
    var font: Font = .body
    var titled = false

    @Environment(AppState.self) private var appState
    @State private var asksTime = false

    var body: some View {
        let added = appState.isInSchedule(target)
        Group {
            if added {
                Menu {
                    ScheduleEntryMenuItems(target: target, asksTime: $asksTime)
                } label: {
                    label(added: true)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
            } else {
                Button {
                    appState.addToScheduleWithUndo(target)
                } label: {
                    label(added: false)
                }
                .buttonStyle(.borderless)
            }
        }
        .sensoryFeedback(.selection, trigger: added)
        .scheduleTimeDialog(target: target, isPresented: $asksTime)
    }

    @ViewBuilder
    private func label(added: Bool) -> some View {
        let title = added ? MyScheduleText.inSchedule : MyScheduleText.add
        let image = added ? "heart.fill" : "heart"
        if titled {
            Label(title, systemImage: image)
                .font(font)
                .foregroundStyle(added ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
                .accessibilityLabel(added ? MyScheduleText.inSchedule : MyScheduleText.addLong)
        } else {
            Label(title, systemImage: image)
                .labelStyle(.iconOnly)
                .font(font)
                .foregroundStyle(added ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
                .accessibilityLabel(added ? MyScheduleText.inSchedule : MyScheduleText.addLong)
        }
    }
}

/// The words of My schedule (no "like" anywhere in the UI).
enum MyScheduleText {
    static let title = MyScheduleTitle.title
    static let add = "Add"
    static let addLong = "Add to my schedule"
    static let inSchedule = "In my schedule"
    static let remove = "Remove from My Schedule"
    static let savedPlaces = "Saved Places"
    static let empty = "Add things to your schedule to see them here"

    static func reminder(_ minutes: Int) -> String {
        minutes == 0 ? "Off" : minutes == 60 ? "1 hour before" : "\(minutes) min before"
    }
}

/// An entry's menu: Change time (places), the reminder, Remove.
struct ScheduleEntryMenuItems: View {
    let target: SearchTarget
    @Binding var asksTime: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        if case .location = target {
            let hasTime = appState.mySchedule.entry(for: target)?.at != nil
            Button(hasTime ? "Change Time…" : "Set a Time…", systemImage: "clock") { asksTime = true }
        }
        let current = appState.mySchedule.entry(for: target)?.reminderMinutes ?? MySchedule.defaultReminder
        Picker(selection: Binding(get: { current }, set: { appState.setReminder(target, minutes: $0) })) {
            ForEach(MySchedule.reminderChoices, id: \.self) { minutes in
                Text(MyScheduleText.reminder(minutes)).tag(minutes)
            }
        } label: {
            Label("Remind Me", systemImage: current == 0 ? "bell.slash" : "bell")
        }
        .pickerStyle(.menu)
        Button(MyScheduleText.remove, systemImage: "minus.circle", role: .destructive) {
            appState.removeFromSchedule(target)
        }
    }
}

extension View {
    /// "When?" for a place, only when asked (the filled heart's Set a Time…, the place detail):
    /// today's times (the first free one after the walk suggested) or "Just save it".
    func scheduleTimeDialog(target: SearchTarget, isPresented: Binding<Bool>) -> some View {
        modifier(ScheduleTimeDialog(target: target, isPresented: isPresented))
    }
}

private struct ScheduleTimeDialog: ViewModifier {
    let target: SearchTarget
    @Binding var isPresented: Bool

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.confirmationDialog("When?", isPresented: $isPresented, titleVisibility: .visible) {
            if case .location(let id) = target, let bundle = appState.currentBundle {
                let choice = options(id, bundle)
                ForEach(choice.times, id: \.self) { time in
                    Button(label(time, suggested: choice.suggested)) {
                        appState.addToSchedule(target, at: time)
                    }
                }
                Button(saveTitle) {
                    if appState.isInSchedule(target) {
                        appState.moveEntry(target, to: nil)
                    } else {
                        appState.addToSchedule(target)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pick a time for it in your schedule, or keep it saved without one.")
        }
    }

    private func label(_ time: Date, suggested: Date?) -> String {
        let text = EventTimeFormat.time(time, in: appState.timeZone)
        return time == suggested ? "\(text) (Suggested)" : text
    }

    /// "Just Save It", or "No Time, Just Save It" when the place already has a time.
    private var saveTitle: String {
        appState.mySchedule.entry(for: target)?.at == nil ? "Just Save It" : "No Time, Just Save It"
    }


    private func options(_ id: Int, _ bundle: EventBundle) -> (times: [Date], suggested: Date?) {
        let walk = appState.userLocation.direction(to: bundle.location(id)?.coordinate).flatMap { direction -> Int? in
            WalkTime.isWithinWalkingRange(direction.meters) ? WalkTime.minutes(WalkTime.estimatedSeconds(straightMeters: direction.meters)) : nil
        }
        return appState.mySchedule.suggestedTimes(for: id, bundle, now: .now, walkMinutes: walk)
    }
}

/// The add button in a detail screen's toolbar (icon + title for vertical bars).
struct HeartToolbarItem: ToolbarContent {
    let target: SearchTarget
    let appState: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HeartButton(target: target, titled: true)
                .environment(appState)
        }
    }
}

// MARK: - Newest update banner

/// The newest unread organizer update (sent within 24 h) above the other tabs; tap opens it
/// in Updates, the cross dismisses it.
struct LatestUpdateBanner: View {
    let notification: AppNotification

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Button {
                appState.navigate(to: .notification(notification.id))
            } label: {
                HStack(spacing: 12) {
                    // Urgent updates (API-011) in red with a warning sign.
                    Image(systemName: notification.isUrgent ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                        .foregroundStyle(notification.isUrgent ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
                        .accessibilityLabel(notification.isUrgent ? "Urgent" : "Update")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notification.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the update.")
            Button {
                appState.dismissLatestUpdate(notification.id)
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Liquid Glass card floating above the tab, like the app-update banner.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .frame(maxWidth: 560)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// MARK: - Urgent announcement banner (API-011)

/// An organizer's urgent announcement (a cancellation, a weather hold) above every tab except
/// Updates for 12 h or until dismissed: red-tinted glass, the whole text. Tap opens it in Updates.
struct UrgentUpdateBanner: View {
    let notification: AppNotification

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                appState.navigate(to: .notification(notification.id))
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Urgent")
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.red)
                        Text(notification.title)
                            .font(.headline)
                            .lineLimit(2)
                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Urgent: \(notification.title). \(notification.body)")
            .accessibilityHint("Opens the update.")
            Button {
                appState.dismissUrgent(notification.id)
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 32, minHeight: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Liquid Glass, tinted red so it stands apart from the ordinary update banner.
        .glassEffect(.regular.tint(.red.opacity(0.25)).interactive(), in: .rect(cornerRadius: 22))
        .frame(maxWidth: 560)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

// MARK: - My schedule filter, empty

/// The My schedule chip's empty state (Places, Map): until something is in My schedule; with
/// entries that the current filter hides, a shorter note.
struct NothingLikedView: View {
    /// Something of this kind is in My schedule already (the filter just shows none of it here).
    var hasLikes = false

    var body: some View {
        if hasLikes {
            ContentUnavailableView(
                "Nothing Here",
                systemImage: "calendar.badge.plus",
                description: Text("Nothing in your schedule matches this view.")
            )
        } else {
            ContentUnavailableView {
                Label("Nothing in Your Schedule Yet", systemImage: "calendar.badge.plus")
            } description: {
                Text("Tap \(Image(systemName: "plus.circle")) on places and events to add them to your schedule.")
            }
        }
    }
}

// MARK: - Now playing (map)

/// Chips for what is on right now ("Main Stage · Prairie Lights"); tap selects the pin.
struct NowPlayingStrip: View {
    let items: [NowPlayingItem]
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.locationId)
                        } label: {
                            Label {
                                Text(item.title).lineLimit(1)
                            } icon: {
                                Circle().fill(.red).frame(width: 8, height: 8)
                            }
                            .font(.subheadline)
                            // Readable over the map in light and dark mode (not the tint).
                            .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Now: \(item.title)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
        .scrollClipDisabled()
        .accessibilityLabel("Happening now")
    }
}

/// The small marker over a pin: a live dot and/or "Next 7:30". Never takes touches.
struct PinGlanceBadge: View {
    let isLive: Bool
    let subtitle: String?

    var body: some View {
        HStack(spacing: 4) {
            if isLive {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, subtitle == nil ? 2 : 6)
        .padding(.vertical, 2)
        .background {
            if subtitle != nil { Capsule().fill(.background.opacity(0.9)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - In progress

/// A thin bar showing how far through an item in progress is.
struct ItemProgressBar: View {
    let progress: Double

    @Environment(\.themeHighlight) private var highlight

    var body: some View {
        let bar = ProgressView(value: progress)
            .progressViewStyle(.linear)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        // API-023: the theme's highlight colour; otherwise the tint as before.
        if let highlight {
            bar.tint(highlight)
        } else {
            bar
        }
    }
}

// MARK: - Peek (long press)

/// The preview card shown by a long press on a location row.
struct LocationPeek: View {
    let location: Location
    let glanceLine: String?
    let distance: String?
    let hearted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = location.imageUrl {
                LocationImage(url: url)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(location.name).font(.headline)
                    Spacer()
                    if hearted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                }
                if let category = location.category {
                    Text(category).font(.subheadline.weight(.medium)).foregroundStyle(.tint)
                }
                if !location.snippet.isEmpty {
                    Text(location.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                }
                if let glanceLine {
                    Text(glanceLine).font(.subheadline).lineLimit(2)
                }
                if let distance {
                    Label(distance, systemImage: "location").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom])
            .padding(.top, location.imageUrl == nil ? 16 : 0)
        }
        .frame(width: 320, alignment: .leading)
    }
}

/// The preview card shown by a long press on a schedule row.
struct ScheduleItemPeek: View {
    let item: ScheduleItem
    let timeText: String
    let relativeText: String?
    let locationName: String
    let hearted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline)
                Spacer()
                if hearted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
            }
            Text(timeText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            if let relativeText {
                Text(relativeText).font(.subheadline.bold()).foregroundStyle(.tint)
            }
            Label(locationName, systemImage: "mappin.and.ellipse").font(.subheadline)
            if !item.description.isEmpty {
                Text(item.description).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
            if !item.tags.isEmpty {
                Text(TagText.line(item.tags)).font(.caption).foregroundStyle(.tint)
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}

// MARK: - Hearted list (search)

/// Pushed on the search sheet's stack by the "My Schedule" suggestion.
struct HeartedListRoute: Hashable {
    /// Only the places saved without a time (Home's "3 saved places" row).
    var savedPlacesOnly = false
}

struct HeartedListView: View {
    var savedPlacesOnly = false

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let all = appState.currentBundle.map { appState.personal.heartedTargets(in: $0) } ?? []
            let saved = Set(appState.mySchedule.savedPlaceIds)
            let targets = savedPlacesOnly
                ? all.filter { if case .location(let id) = $0 { return saved.contains(id) } else { return false } }
                : all
            let rows = targets.compactMap { appState.searchIndex?.result(for: $0, now: context.date) }
            List {
                ForEach(rows) { result in
                    NavigationLink(value: result.target) {
                        HeartableResultRow(result: result)
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing in Your Schedule",
                        systemImage: "calendar.badge.plus",
                        description: Text("Tap \(Image(systemName: "heart")) on a schedule item or place to add it here.")
                    )
                }
            }
        }
        .navigationTitle(savedPlacesOnly ? MyScheduleText.savedPlaces : MyScheduleText.title)
        .navigationBarTitleDisplayMode(.inline)
        .usesUserLocation(heading: true)
    }
}
