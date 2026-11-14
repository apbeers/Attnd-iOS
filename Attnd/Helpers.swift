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
