// Helpers.swift
// Attnd
//
// Small shared utilities: ISO 8601 parsing, event-time-zone formatting,
// hex colours and deep-link parsing. Everything here is pure and testable.

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
    static func time(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "7:30 PM" today (in the event's zone), otherwise "Sat 7:30 PM".
    static func shortDayTime(_ date: Date, in timeZone: TimeZone, now: Date = .now) -> String {
        if calendar(in: timeZone).isDate(date, inSameDayAs: now) {
            return time(date, in: timeZone)
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = timeZone
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

    /// A scanned QR string: a join URL (any host) or a bare event code.
    static func eventCode(fromScanned raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let joinIndex = parts.firstIndex(of: "join"), parts.indices.contains(joinIndex + 1) {
                return parts[joinIndex + 1]
            }
            return nil
        }
        return trimmed
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
