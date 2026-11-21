// LiveActivityModel.swift
// Attnd, AttndAppClip + AttndWidgets, AttndClipWidgets (widget extensions)
//
// The Live Activity's data ("Follow on Lock Screen", shared spec §8) and its internal links.
// Compiled into the app and the App Clip (which start and update the activity,
// LiveFollowController) and their widget extensions (which draw it,
// AttndWidgets/EventLiveActivity.swift): an App Clip may offer Live Activities only through a
// widget extension of its own, so the clip embeds AttndClipWidgets (the same sources).
//
// ContentState: EVERY field is optional (API-011). An urgent announcement's ActivityKit push
// replaces the whole content state with `{"urgent": {...}}` only, decoded with a default
// JSONDecoder, so a push carrying just `urgent` must decode; `urgent.sent_at` is ISO 8601
// text (a `Date` would be read as seconds since 2001). The app refills the other fields on
// its next local update and keeps `urgent` until it is dismissed or 12 h old.
//
// No Models.swift types here: the widget extension only has this file and
// LiveActivityIntents.swift.

import ActivityKit
import Foundation

struct EventActivityAttributes: ActivityAttributes {
    /// The joined event.
    var eventId: Int
    var eventName: String
    /// `display.accent_color` or the event's (`#RRGGBB`); nil → the brand purple.
    var accentHex: String?
    /// The event's IANA time zone (times are shown in it).
    var timeZoneIdentifier: String
    /// Start of the followed day in the event's time zone: one activity per event day.
    var dayStart: Date
    /// The event's full colour theme (API-023), nil without one (or with the apps switch off):
    /// `accentHex` then. Optional, so activities started by older builds still decode.
    var theme: ActivityTheme? = nil

    /// API-023 for the activity: light / dark × primary (progress, buttons, island tint),
    /// secondary (soft backgrounds), tertiary (highlights: "Now", the countdown). `#RRGGBB`.
    struct ActivityTheme: Codable, Hashable, Sendable {
        var light: Roles?
        var dark: Roles?

        struct Roles: Codable, Hashable, Sendable {
            var primary: String?
            var secondary: String?
            var tertiary: String?

            init(primary: String? = nil, secondary: String? = nil, tertiary: String? = nil) {
                self.primary = primary
                self.secondary = secondary
                self.tertiary = tertiary
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                primary = try? c.decodeIfPresent(String.self, forKey: .primary)
                secondary = try? c.decodeIfPresent(String.self, forKey: .secondary)
                tertiary = try? c.decodeIfPresent(String.self, forKey: .tertiary)
            }

            var isEmpty: Bool { primary == nil && secondary == nil && tertiary == nil }
        }

        init(light: Roles? = nil, dark: Roles? = nil) {
            self.light = light
            self.dark = dark
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            light = (try? c.decodeIfPresent(Roles.self, forKey: .light)).flatMap { $0.isEmpty ? nil : $0 }
            dark = (try? c.decodeIfPresent(Roles.self, forKey: .dark)).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// One role for an appearance; a missing mode uses the other one.
        func hex(_ role: KeyPath<Roles, String?>, dark isDark: Bool) -> String? {
            let first = isDark ? dark : light
            let other = isDark ? light : dark
            return first?[keyPath: role] ?? other?[keyPath: role]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventId, eventName, accentHex, timeZoneIdentifier, dayStart, theme
    }

    init(eventId: Int, eventName: String, accentHex: String?, timeZoneIdentifier: String, dayStart: Date,
         theme: ActivityTheme? = nil) {
        self.eventId = eventId
        self.eventName = eventName
        self.accentHex = accentHex
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dayStart = dayStart
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(Int.self, forKey: .eventId)
        eventName = (try? c.decodeIfPresent(String.self, forKey: .eventName)) ?? ""
        accentHex = try? c.decodeIfPresent(String.self, forKey: .accentHex)
        timeZoneIdentifier = (try? c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)) ?? TimeZone.current.identifier
        dayStart = try c.decode(Date.self, forKey: .dayStart)
        theme = try? c.decodeIfPresent(ActivityTheme.self, forKey: .theme)
    }

    struct ContentState: Codable, Hashable, Sendable {
        /// The item in progress.
        var current: Slot?
        /// The next item (counted down to).
        var next: Slot?
        /// The one after.
        var after: Slot?
        /// Estimated walk to the next item's location (minutes), when the user is at the event.
        var walkMinutesToNext: Int?
        /// An organizer's urgent announcement (API-011), shown front and centre.
        var urgent: Urgent?
        /// Before the event starts today: "Gates open in …".
        var opensAt: Date?
        /// True when it follows the user's hearts (false: the event's own now / next).
        var followsHearts: Bool?
        /// True when it follows the user's plan (spec §6; plan > hearts > the event's own day).
        var followsPlan: Bool?
        /// Nothing more today: the end-of-day summary.
        var dayComplete: Bool?
        /// How many followed items took place today (end-of-day summary).
        var completedCount: Int?
        /// Running late for the next planned item (assistant spec §6): when to have left.
        var leaveBy: Date?
        /// "leave_now" (still makes it when leaving now) or "cant_make_it".
        var lateState: String?
        /// Where Now comes from: "schedule" (My schedule) or "event" ("At the event").
        var nowSource: String?
        /// Where Next comes from: "schedule" or "event".
        var nextSource: String?
        /// My schedule has a gap until Next: "Free until 3:00 · Next: X at Y".
        var freeUntil: Date?
        /// The 8-point compass direction to Next from the user's last position (0 = north,
        /// clockwise in 45° steps), relative to north: the arrow can't follow the phone.
        var nextPoint: Int?
        /// "0.4 mi" to Next.
        var nextDistance: String?
        /// VoiceOver: "Northeast, 0.4 miles".
        var nextDirectionLabel: String?
        /// API-027 `live_activity.buttons` this app draws ("skip", "map"), nil = both.
        var buttons: [String]?
        /// API-027 `live_activity.stale_text`, nil = "Open Attnd to update".
        var staleText: String?

        func showsButton(_ name: String) -> Bool { buttons?.contains(name) ?? true }

        /// The next item's "Leave now" / "Running late" line, nil when on time.
        var lateText: String? {
            guard leaveBy != nil else { return nil }
            return lateState == "cant_make_it" ? "Running late" : "Leave now"
        }

        init(
            current: Slot? = nil,
            next: Slot? = nil,
            after: Slot? = nil,
            walkMinutesToNext: Int? = nil,
            urgent: Urgent? = nil,
            opensAt: Date? = nil,
            followsHearts: Bool? = nil,
            followsPlan: Bool? = nil,
            dayComplete: Bool? = nil,
            completedCount: Int? = nil,
            leaveBy: Date? = nil,
            lateState: String? = nil,
            nowSource: String? = nil,
            nextSource: String? = nil,
            freeUntil: Date? = nil,
            nextPoint: Int? = nil,
            nextDistance: String? = nil,
            nextDirectionLabel: String? = nil,
            buttons: [String]? = nil,
            staleText: String? = nil
        ) {
            self.current = current
            self.next = next
            self.after = after
            self.walkMinutesToNext = walkMinutesToNext
            self.urgent = urgent
            self.opensAt = opensAt
            self.followsHearts = followsHearts
            self.followsPlan = followsPlan
            self.dayComplete = dayComplete
            self.completedCount = completedCount
            self.leaveBy = leaveBy
            self.lateState = lateState
            self.nowSource = nowSource
            self.nextSource = nextSource
            self.freeUntil = freeUntil
            self.nextPoint = nextPoint
            self.nextDistance = nextDistance
            self.nextDirectionLabel = nextDirectionLabel
            self.buttons = buttons
            self.staleText = staleText
        }

        private enum CodingKeys: String, CodingKey {
            case current, next, after, urgent
            case walkMinutesToNext = "walk_minutes_to_next"
            case opensAt = "opens_at"
            case followsHearts = "follows_hearts"
            case followsPlan = "follows_plan"
            case dayComplete = "day_complete"
            case completedCount = "completed_count"
            case leaveBy = "leave_by"
            case lateState = "late_state"
            case nowSource = "now_source"
            case nextSource = "next_source"
            case freeUntil = "free_until"
            case nextPoint = "next_point"
            case nextDistance = "next_distance"
            case nextDirectionLabel = "next_direction_label"
            case buttons
            case staleText = "stale_text"
        }

        /// Lenient: a missing, null or mistyped field is nil, never a decoding failure.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            current = try? c.decodeIfPresent(Slot.self, forKey: .current)
            next = try? c.decodeIfPresent(Slot.self, forKey: .next)
            after = try? c.decodeIfPresent(Slot.self, forKey: .after)
            walkMinutesToNext = try? c.decodeIfPresent(Int.self, forKey: .walkMinutesToNext)
            urgent = try? c.decodeIfPresent(Urgent.self, forKey: .urgent)
            opensAt = try? c.decodeIfPresent(Date.self, forKey: .opensAt)
            followsHearts = try? c.decodeIfPresent(Bool.self, forKey: .followsHearts)
            followsPlan = try? c.decodeIfPresent(Bool.self, forKey: .followsPlan)
            dayComplete = try? c.decodeIfPresent(Bool.self, forKey: .dayComplete)
            completedCount = try? c.decodeIfPresent(Int.self, forKey: .completedCount)
            leaveBy = try? c.decodeIfPresent(Date.self, forKey: .leaveBy)
            lateState = try? c.decodeIfPresent(String.self, forKey: .lateState)
            nowSource = try? c.decodeIfPresent(String.self, forKey: .nowSource)
            nextSource = try? c.decodeIfPresent(String.self, forKey: .nextSource)
            freeUntil = try? c.decodeIfPresent(Date.self, forKey: .freeUntil)
            nextPoint = (try? c.decodeIfPresent(Int.self, forKey: .nextPoint)).flatMap { (0..<8).contains($0) ? $0 : nil }
            nextDistance = try? c.decodeIfPresent(String.self, forKey: .nextDistance)
            nextDirectionLabel = try? c.decodeIfPresent(String.self, forKey: .nextDirectionLabel)
            buttons = try? c.decodeIfPresent([String].self, forKey: .buttons)
            staleText = try? c.decodeIfPresent(String.self, forKey: .staleText)
        }

        /// Now isn't from My schedule: label it "At the event".
        var nowIsFromEvent: Bool { nowSource == "event" }

        /// The arrow for `nextPoint` (north-relative): "↑", "↗", "→", …
        var nextArrow: String? {
            nextPoint.map { ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"][$0] }
        }

        /// "↗ 0.4 mi · 8 min walk", "8 min walk", nil without either.
        var nextDirectionLine: String? {
            var parts: [String] = []
            if let arrow = nextArrow, let distance = nextDistance { parts.append("\(arrow) \(distance)") }
            if let walk = walkMinutesToNext { parts.append("\(walk) min walk") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The symbol for what it follows: the plan, hearts, or the event's own day.
        var followSymbol: String {
            if followsPlan == true { return "list.bullet.clipboard" }
            return "calendar"
        }
    }

    /// One schedule item in the activity.
    struct Slot: Codable, Hashable, Sendable {
        var id: Int?
        var name: String?
        /// Location name ("General" without one).
        var location: String?
        /// For "Show on map" (map with the walking route).
        var locationId: Int?
        var start: Date?
        var end: Date?
        var hearted: Bool?
        /// "place" for a timed place of My schedule (then `id` is nil), nil for a schedule item.
        var kind: String?

        init(id: Int? = nil, name: String? = nil, location: String? = nil, locationId: Int? = nil,
             start: Date? = nil, end: Date? = nil, hearted: Bool? = nil, kind: String? = nil) {
            self.kind = kind
            self.id = id
            self.name = name
            self.location = location
            self.locationId = locationId
            self.start = start
            self.end = end
            self.hearted = hearted
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, location, start, end, hearted, kind
            case locationId = "location_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(Int.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            location = try? c.decodeIfPresent(String.self, forKey: .location)
            locationId = try? c.decodeIfPresent(Int.self, forKey: .locationId)
            start = try? c.decodeIfPresent(Date.self, forKey: .start)
            end = try? c.decodeIfPresent(Date.self, forKey: .end)
            hearted = try? c.decodeIfPresent(Bool.self, forKey: .hearted)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        }

        var isPlace: Bool { kind == "place" }

        /// Where a tap on this row goes: the item's detail, a place's detail.
        var link: LiveActivityLink? {
            if let id, !isPlace { return .item(id) }
            return locationId.map { .place($0) }
        }

        /// The end used for progress: the end, or start + 1 h.
        var effectiveEnd: Date? {
            guard let start else { return nil }
            if let end, end > start { return end }
            return start.addingTimeInterval(60 * 60)
        }
    }

    /// API-011's `urgent` block, exactly as the server's ActivityKit push sends it:
    /// `{"id": 9, "title": "…", "body": "…", "sent_at": "2026-11-15T16:40:00+00:00"}`.
    struct Urgent: Codable, Hashable, Sendable {
        var id: Int?
        var title: String?
        var body: String?
        /// ISO 8601 text (not a Date: ActivityKit's default decoder would misread it).
        var sentAt: String?

        init(id: Int? = nil, title: String? = nil, body: String? = nil, sentAt: String? = nil) {
            self.id = id
            self.title = title
            self.body = body
            self.sentAt = sentAt
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, body
            case sentAt = "sent_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The server sends a number; accept a numeric string too.
            id = (try? c.decodeIfPresent(Int.self, forKey: .id))
                ?? (try? c.decodeIfPresent(String.self, forKey: .id)).flatMap { Int($0) }
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            body = try? c.decodeIfPresent(String.self, forKey: .body)
            sentAt = try? c.decodeIfPresent(String.self, forKey: .sentAt)
        }
    }
}

// MARK: - Internal links

/// Links from the Live Activity (`widgetURL` / `Link`) and the app's own local notifications
/// into the app: `attnd-live://event/<event id>/<route>`. AttndApp's `onOpenURL` routes them
/// through `AppState.navigate(to:)` / `showOnMap(locationId:)`; a link for an event other than
/// the joined one is ignored.
enum LiveActivityLink: Hashable, Sendable {
    /// A schedule item's detail.
    case item(Int)
    /// The Map tab focused on a location (the selected card draws the walking route).
    case map(locationId: Int)
    /// Updates, scrolled to one notification (nil: the list).
    case updates(notificationId: Int?)
    /// Open the app and start following on the Lock Screen (the "tap to follow" notification).
    case follow
    /// The plan page (spec §6), when the activity follows the plan.
    case plan
    /// A place's detail (a timed place of My schedule).
    case place(Int)

    static let scheme = "attnd-live"

    func url(eventId: Int) -> URL {
        var path: String
        switch self {
        case .item(let id):                 path = "item/\(id)"
        case .map(let id):                  path = "map/\(id)"
        case .updates(let id?):             path = "updates/\(id)"
        case .updates(nil):                 path = "updates"
        case .follow:                       path = "follow"
        case .plan:                         path = "plan"
        case .place(let id):                path = "place/\(id)"
        }
        path = "\(Self.scheme)://event/\(eventId)/\(path)"
        // Only digits and fixed words: always a valid URL.
        return URL(string: path)!
    }

    /// Parses a link; nil for anything else (other schemes, unknown routes, bad ids).
    static func parse(_ url: URL) -> (eventId: Int, link: LiveActivityLink)? {
        guard url.scheme?.lowercased() == scheme, url.host()?.lowercased() == "event" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, let eventId = Int(parts[0]) else { return nil }
        let id = parts.count >= 3 ? Int(parts[2]) : nil
        switch parts[1].lowercased() {
        case "item":
            guard let id, parts.count == 3 else { return nil }
            return (eventId, .item(id))
        case "map":
            guard let id, parts.count == 3 else { return nil }
            return (eventId, .map(locationId: id))
        case "updates":
            if parts.count == 2 { return (eventId, .updates(notificationId: nil)) }
            guard let id, parts.count == 3 else { return nil }
            return (eventId, .updates(notificationId: id))
        case "follow":
            guard parts.count == 2 else { return nil }
            return (eventId, .follow)
        case "plan":
            guard parts.count == 2 else { return nil }
            return (eventId, .plan)
        case "place":
            guard let id, parts.count == 3 else { return nil }
            return (eventId, .place(id))
        default:
            return nil
        }
    }
}
