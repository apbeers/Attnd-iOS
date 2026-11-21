// Helpers.swift
// Attnd
//
// Small shared utilities: ISO 8601 parsing, event-time-zone formatting,
// hex colours, deep-link parsing, live-update rules (API-007: polling intervals,
// content_updated handling, "last updated" text) and the offline media cache's
// naming / pruning rules. Everything here is pure and testable.

import CryptoKit
import Foundation

// MARK: - ISO 8601 parsing

enum ISODate {
    // ISO8601DateFormatter is documented as thread-safe for parsing.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses "2026-11-14T13:29:44+00:00", "…44Z", "…44.5Z" and Python's
    /// microsecond form "…44.123456+00:00". Returns nil for anything else.
    static func parse(_ string: String) -> Date? {
        if let date = plain.date(from: string) ?? fractional.date(from: string) {
            return date
        }
        // Normalise the fraction to exactly three digits and retry.
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        let normalised = String(string[..<dot]) + "." + millis + String(afterDot.dropFirst(digits.count))
        return fractional.date(from: normalised)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}

// MARK: - Event-time-zone formatting

/// Formats event times in the event's own time zone, never the device's.
enum EventTimeFormat {

    static func calendar(in timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = .current
        return cal
    }

    /// "7:30 PM"
    static func time(_ date: Date, in timeZone: TimeZone, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }

    /// "7:30" (no AM/PM; "19:30" in 24-hour locales): pin subtitles and "Next 8:30 …" lines.
    static func clock(_ date: Date, in timeZone: TimeZone, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }

    /// "Sun 10:00" (weekday + clock without AM/PM).
    static func weekdayClock(_ date: Date, in timeZone: TimeZone, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }

    /// "7:30 PM" today (in the event's zone), otherwise "Sat 7:30 PM".
    static func shortDayTime(_ date: Date, in timeZone: TimeZone, now: Date = .now, locale: Locale = .current) -> String {
        if calendar(in: timeZone).isDate(date, inSameDayAs: now) {
            return time(date, in: timeZone, locale: locale)
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }

    /// "Saturday, Nov 14"
    static func dayTitle(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "Nov 14, 7:30 PM"
    static func dateTime(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "7:30 – 9:00 PM"-style range; just the start when there is no end.
    static func range(start: Date?, end: Date?, in timeZone: TimeZone, now: Date = .now) -> String {
        guard let start else { return "Time TBA" }
        let startText = shortDayTime(start, in: timeZone, now: now)
        guard let end, end > start else { return startText }
        return "\(startText) – \(time(end, in: timeZone))"
    }

    /// "Times shown in CST" when the event's zone differs from the device's, else nil.
    static func zoneNote(for timeZone: TimeZone, deviceZone: TimeZone = .current, at date: Date = .now) -> String? {
        guard timeZone.secondsFromGMT(for: date) != deviceZone.secondsFromGMT(for: date) else { return nil }
        let name = timeZone.abbreviation(for: date) ?? timeZone.identifier
        return "Times shown in \(name) (event time)"
    }
}

// MARK: - Hex colours

enum HexColor {
    /// Parses "#RRGGBB" / "RRGGBB" into 0…1 components. Returns nil for anything else.
    static func components(_ hex: String?) -> (red: Double, green: Double, blue: Double)? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Deep links / QR codes

enum DeepLink {
    /// `https://attnd.app/join/<event_code>/` → "<event_code>". Only the path is checked.
    static func eventCode(from url: URL) -> String? {
        // pathComponents for /join/FWFM2026/ → ["/", "join", "FWFM2026"]
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "join", !parts[2].isEmpty else { return nil }
        return parts[2]
    }

    /// A scanned QR string: a join URL or a shared plan link (any host), or a bare event code.
    static func eventCode(fromScanned raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let joinIndex = parts.firstIndex(of: "join"), parts.indices.contains(joinIndex + 1) {
                return parts[joinIndex + 1]
            }
            // A shared plan's QR code (`/p/<code>/<payload>`, API-015) joins its event.
            if let shared = SharedPlanLink.parse(url) {
                return shared.eventCode
            }
            return nil
        }
        return trimmed
    }

    /// The website's "Open in Attnd" button on iPhone (attnd-web `live_on_phone`): Safari doesn't open a Universal
    /// Link to the domain it is showing, so the button uses the app's own scheme. `attnd://join/<code>` and
    /// `attnd://p/<code>/<payload>` become the equivalent `https://attnd.app/…` link, which `AppState.handleDeepLink`
    /// reads by its path. nil for anything else (the App Clip doesn't register the scheme).
    static func httpsURL(fromAppScheme url: URL) -> URL? {
        guard url.scheme?.lowercased() == "attnd", let host = url.host?.lowercased(),
              host == "join" || host == "p" else { return nil }
        let rest = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let code = rest.first,
              code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        if host == "p", rest.count >= 2,
           rest[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            return URL(string: "https://attnd.app/p/\(code)/\(rest[1])")
        }
        // API-026: a "Preview on my phone" link keeps its `?preview=` token.
        if let token = previewToken(from: url) {
            return URL(string: "https://attnd.app/join/\(code)/?preview=\(token)")
        }
        return URL(string: "https://attnd.app/join/\(code)/")
    }

    /// API-026: the organizer's preview token of a join link (`?preview=<token>`), only plain
    /// token characters (letters, digits, `-_.:`), ≤ 512; nil otherwise.
    static func previewToken(from url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "preview" })?.value?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, raw.count <= 512,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }) else { return nil }
        return raw
    }

    /// A scanned QR string's preview token (a join link with `?preview=`), nil otherwise.
    static func previewToken(fromScanned raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return previewToken(from: url)
    }
}

// MARK: - Live updates (API-007)

/// How often an open app re-checks the bundle while the scene is active. A silent
/// `content_updated` push does the real work; the timer is only a fallback.
enum LiveRefreshPolicy {
    /// Whether this bundle's Info.plist declares the `remote-notification` background mode.
    static func declaresSilentPush(_ info: [String: Any]?) -> Bool {
        (info?["UIBackgroundModes"] as? [String])?.contains("remote-notification") ?? false
    }

    /// No push token (not registered, or registration failed).
    static let withoutPush: Duration = .seconds(60)
    /// Push works: a slow safety poll in case a silent push is dropped or throttled.
    static let withPush: Duration = .seconds(5 * 60)
    /// The last refresh failed (offline): try again sooner, so the offline badge clears quickly.
    static let afterFailure: Duration = .seconds(15)

    static func interval(canReceivePush: Bool, lastRefreshFailed: Bool = false) -> Duration {
        if lastRefreshFailed { return afterFailure }
        return canReceivePush ? withPush : withoutPush
    }

    /// Silent pushes can reach this install only with a token, a working registration and the
    /// `remote-notification` background mode (the App Clip may not declare background modes, so it
    /// keeps the 60 s poll even with a token: its pushes still alert, but silent ones never arrive).
    static func canReceivePush(pushToken: String?, registrationFailed: Bool, silentPushAllowed: Bool = true) -> Bool {
        guard silentPushAllowed, !registrationFailed, let pushToken else { return false }
        return !pushToken.isEmpty
    }
}

/// What to do with a `content_updated` silent push.
enum ContentUpdatePolicy {
    /// Refreshes are spread over a random 0–10 s so an event's open apps don't all hit the server at once.
    static let maxJitterMilliseconds = 10_000

    /// Refetch only when the push announces a newer `content_version` than the one shown.
    /// A push without a version, or no content loaded yet, always refetches (a 304 is cheap).
    static func shouldRefresh(pushedVersion: Int?, currentVersion: Int?) -> Bool {
        guard let pushedVersion, let currentVersion else { return true }
        return pushedVersion > currentVersion
    }

    /// 0…`jitter_ms` when the push says (API-026: smaller events wait less, a preview phone 0),
    /// else 0–10 s.
    static func jitter(maxMilliseconds: Int? = nil) -> Duration {
        let limit = maxMilliseconds.map { min(max($0, 0), 60_000) } ?? maxJitterMilliseconds
        return .milliseconds(limit == 0 ? 0 : Int.random(in: 0...limit))
    }
}

/// Why the last bundle refresh failed. Saved content stays on screen either way.
enum RefreshProblem: Hashable, Sendable {
    /// No connection (or it timed out).
    case offline
    /// The server answered with an error.
    case serverError

    init(_ error: Error) {
        if let apiError = error as? APIError, case .networkError = apiError {
            self = .offline
        } else {
            self = .serverError
        }
    }
}

/// "Offline · Updated 3:41 PM" for the floating status badge. "Last updated" is a moment
/// on this device, so it uses the device's time zone (event times use the event's).
enum LastUpdatedText {
    /// "3:41 PM" when `date` is today, otherwise "Nov 13, 3:41 PM".
    static func time(_ date: Date, now: Date = .now, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = calendar.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle.dateTime.hour().minute()
            : Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }

    static func badgeTitle(
        _ problem: RefreshProblem,
        lastRefreshed: Date?,
        now: Date = .now,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let state = problem == .offline ? "Offline" : "Can't update"
        guard let lastRefreshed else { return state }
        // Reassuring (batch 7): the saved copy keeps everything working.
        let still = problem == .offline ? " · everything still works" : ""
        return "\(state) · Updated \(time(lastRefreshed, now: now, timeZone: timeZone, locale: locale))\(still)"
    }

    static func accessibilityText(
        _ problem: RefreshProblem,
        lastRefreshed: Date?,
        now: Date = .now,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        let state = problem == .offline ? "You're offline." : "Attnd can't reach the server right now."
        guard let lastRefreshed else { return state + " Everything still works." }
        return "\(state) Showing content last updated \(time(lastRefreshed, now: now, timeZone: timeZone, locale: locale)). Everything still works."
    }
}

// MARK: - Offline media cache rules

/// Naming, selection and pruning rules for `ImageStore` (location images, logos and the flyer,
/// kept on disk so the event works offline). Pure; the actor does the I/O.
enum MediaCache {
    /// Larger files are never cached (they're shown from the network as before).
    static let maxFileBytes = 15 * 1024 * 1024
    /// Total budget for the cache directory.
    static let maxTotalBytes = 300 * 1024 * 1024
    static let maxConcurrentDownloads = 4
    /// A cached file older than this is downloaded again on the next prefetch (kept if that fails).
    static let revalidateAfter: TimeInterval = 24 * 60 * 60

    /// A file in the cache directory.
    struct CachedFile: Hashable, Sendable {
        var name: String
        var bytes: Int
        var modified: Date
    }

    /// "<sha256 of the URL>.<ext>": stable per URL, safe as a file name. The extension comes
    /// from the URL path when it looks like one, else "bin" (the content is sniffed when needed).
    static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        let isSane = (1...5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return "\(hex).\(isSane ? ext : "bin")"
    }

    /// Every http(s) media URL the bundle shows, deduplicated, most visible first:
    /// logo(s), location images in organizer order, then the flyer (image or PDF).
    static func referencedURLs(for bundle: EventBundle) -> [URL] {
        referencedURLs(event: bundle.event, display: bundle.display, locations: bundle.locations)
    }

    static func referencedURLs(event: Event?, display: DisplayConfig, locations: [Location]) -> [URL] {
        var candidates: [URL?] = [display.logoUrl, event?.logoUrl]
        candidates += locations.map(\.imageUrl)
        candidates.append(event?.flyerUrl)
        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
            return seen.insert(url.absoluteString).inserted
        }
    }

    /// Whether a URL must be downloaded: never cached, or cached long enough ago to re-check.
    static func needsDownload(existing: CachedFile?, now: Date = .now) -> Bool {
        guard let existing else { return true }
        return now.timeIntervalSince(existing.modified) > revalidateAfter
    }

    /// Files to delete after a prefetch: everything the current bundle no longer references,
    /// then, if the referenced files alone exceed `maxTotalBytes`, the largest of them until
    /// the rest fits. Returned in deletion order.
    static func filesToDelete(_ files: [CachedFile], referenced: Set<String>, maxTotalBytes: Int = maxTotalBytes) -> [String] {
        var doomed = files.filter { !referenced.contains($0.name) }.map(\.name)
        let kept = files.filter { referenced.contains($0.name) }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for file in kept.sorted(by: { $0.bytes > $1.bytes || ($0.bytes == $1.bytes && $0.name < $1.name) }) {
            guard total > maxTotalBytes else { break }
            doomed.append(file.name)
            total -= file.bytes
        }
        return doomed
    }

    /// The MIME type of a cached file from its first bytes (PDF, PNG, JPEG, GIF, WebP, HEIC), or nil.
    static func sniffMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts(Array("%PDF".utf8)) { return "application/pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF8".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("ftyp".utf8), at: 4) {
            for brand in ["heic", "heix", "mif1", "msf1", "hevc"] where starts(Array(brand.utf8), at: 8) {
                return "image/heic"
            }
        }
        return nil
    }
}

// MARK: - Support info (API-004)

/// Build, device and event details shown in Options → About & support and copied
/// as plain text for support requests. Pure: the caller gathers the values.
struct SupportInfo: Hashable, Sendable {
    var appVersion: String
    var buildNumber: String
    var serverHost: String
    var apiVersion: Int
    var osVersion: String
    var deviceModel: String
    var isAppClip: Bool
    var deviceId: String
    var eventName: String? = nil
    var eventCode: String? = nil
    var eventId: Int? = nil
    var contentVersion: Int? = nil
    var lastRefreshed: Date? = nil

    static let productionHost = "attnd.app"

    var isProductionServer: Bool { serverHost == Self.productionHost }

    var supportCode: String { Self.supportCode(deviceId: deviceId) }

    /// First 8 characters of the device ID without dashes, upper case
    /// ("3f2a9c1e-…" → "3F2A9C1E"). The admin console looks devices up by it.
    static func supportCode(deviceId: String) -> String {
        String(deviceId.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

    /// Plain-text block for the pasteboard: everything above plus the full device ID.
    var plainText: String {
        var lines = [
            "Attnd support info",
            "Support code: \(supportCode)",
            "Device ID: \(deviceId)",
            "App version: \(appVersion) (\(buildNumber))\(isAppClip ? " App Clip" : "")",
            "Server: \(serverHost)\(isProductionServer ? "" : " (internal test build)")",
            "API version: \(apiVersion)",
            "Platform: iOS \(osVersion)",
            "Device model: \(deviceModel)",
        ]
        if let eventId {
            lines.append("Event: \(eventName ?? "") (code \(eventCode ?? ""), id \(eventId))")
            if let contentVersion { lines.append("Content version: \(contentVersion)") }
        } else {
            lines.append("Event: none")
        }
        lines.append("Last refresh: \(lastRefreshed.map(ISODate.string(from:)) ?? "never")")
        return lines.joined(separator: "\n")
    }

    /// The hardware model identifier, e.g. "iPhone17,2" (the simulated model on a simulator).
    static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}

// MARK: - Screenshot mode (App Store screenshots)

/// App Store screenshot mode, driven by launch arguments from `scripts/ci/screenshots.sh`:
///
///     -AttndScreenshotMode YES -AttndScreen <map|map-pane|locations|location|schedule|updates|orientation-probe>
///     [-AttndEventCode DEMO] [-AttndLocation "Main Stage"] [-AttndScheduleStyle now_next]
///     [-AttndPane now_next] [-AttndSettleSeconds 4]
///
/// (or the environment: ATTND_SCREENSHOT_MODE=1, ATTND_SCREEN=map — `simctl launch` passes
/// SIMCTL_CHILD_-prefixed variables). Launch arguments land in UserDefaults' volatile argument
/// domain, so nothing is persisted and normal launches never enter this mode.
///
/// In this mode the app joins `eventCode` through the normal lookup → join → bundle path at
/// launch (skipping the launch screen and any saved event), opens the requested screen, and
/// skips the update check, device registration, usage counts, the demo badge, the blue dot
/// and push registration. The map shows every pin (fit all, no clustering). When the content
/// has loaded and settled it writes `Documents/attnd-screenshot-ready` ("ready <screen> <W>x<H>",
/// the key window's size in points, or "failed <reason>"), which the script waits for before
/// capturing (and uses to check that the iPhone Duo really shows its unfolded inner display).
struct ScreenshotMode: Sendable, Equatable {

    enum Screen: String, Sendable, CaseIterable {
        case map
        /// The map beside the secondary pane (iPhone Duo, unfolded).
        case mapPane = "map-pane"
        case locations
        /// The detail page of `locationName` (list + detail side by side on wide layouts).
        case location
        case schedule
        case updates
        /// Not a store screenshot: a red top half over a blue bottom half, shown without joining
        /// an event, so the capture script can tell which way a display's capture is rotated.
        case orientationProbe = "orientation-probe"

        var tab: EventTab {
            switch self {
            case .map, .mapPane, .orientationProbe: return .map
            case .locations, .location: return .locations
            case .schedule:             return .schedule
            case .updates:              return .notifications
            }
        }
    }

    var screen: Screen = .map
    var eventCode: String = "DEMO"
    var locationName: String = "Main Stage"
    var scheduleStyle: ScheduleStyle = .nowNext
    var pane: SecondaryPane = .nowNext
    var settleSeconds: Double = 4

    /// Read once per launch.
    static let current: ScreenshotMode? = ScreenshotMode(
        arguments: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
        environment: ProcessInfo.processInfo.environment
    )

    static var isActive: Bool { current != nil }

    /// nil unless `AttndScreenshotMode` (argument) or `ATTND_SCREENSHOT_MODE` (environment) is truthy.
    init?(arguments: [String: Any], environment: [String: String]) {
        func value(_ argument: String, _ variable: String) -> String? {
            let raw = (arguments[argument] as? String) ?? environment[variable]
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let flag = value("AttndScreenshotMode", "ATTND_SCREENSHOT_MODE"),
              ["yes", "true", "1"].contains(flag.lowercased()) else { return nil }
        if let raw = value("AttndScreen", "ATTND_SCREEN"), let screen = Screen(rawValue: raw.lowercased()) {
            self.screen = screen
        }
        if let code = value("AttndEventCode", "ATTND_EVENT_CODE") { eventCode = code }
        if let name = value("AttndLocation", "ATTND_LOCATION") { locationName = name }
        if let raw = value("AttndScheduleStyle", "ATTND_SCHEDULE_STYLE"), let style = ScheduleStyle(rawValue: raw) {
            scheduleStyle = style
        }
        if let raw = value("AttndPane", "ATTND_PANE"), let pane = SecondaryPane(rawValue: raw), pane != .none {
            self.pane = pane
        }
        if let raw = value("AttndSettleSeconds", "ATTND_SETTLE_SECONDS"), let seconds = Double(raw), seconds >= 0 {
            settleSeconds = seconds
        }
    }

    /// The server's display config with what makes screenshots complete and deterministic:
    /// every pin framed, the chosen schedule style and pane, and the requested tab first.
    func adjusted(_ display: DisplayConfig) -> DisplayConfig {
        var display = display
        display.mapFitAll = true
        display.mapClustering = false
        display.scheduleStyle = scheduleStyle
        display.secondaryPane = pane
        display.defaultTab = screen.tab
        return display
    }

    /// The location shown by the `location` screen: by name, else the first with an image.
    func screenshotLocation(in locations: [Location]) -> Location? {
        locations.first { $0.name.caseInsensitiveCompare(locationName) == .orderedSame }
            ?? locations.first { $0.imageUrl != nil }
            ?? locations.first
    }

    // MARK: Ready marker

    private static var markerURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-screenshot-ready")
    }

    static func clearMarker() {
        guard let url = markerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// "ready <screen> <W>x<H>" or "failed <reason>" for the capture script.
    static func writeMarker(_ text: String) {
        guard let url = markerURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((text + "\n").utf8).write(to: url, options: .atomic)
    }
}
