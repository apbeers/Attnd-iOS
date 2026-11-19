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
            lateState: String? = nil
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
        }

        /// The symbol for what it follows: the plan, hearts, or the event's own day.
        var followSymbol: String {
            if followsPlan == true { return "list.bullet.clipboard" }
            return followsHearts == true ? "heart.fill" : "calendar"
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

        init(id: Int? = nil, name: String? = nil, location: String? = nil, locationId: Int? = nil,
             start: Date? = nil, end: Date? = nil, hearted: Bool? = nil) {
            self.id = id
            self.name = name
            self.location = location
            self.locationId = locationId
            self.start = start
            self.end = end
            self.hearted = hearted
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, location, start, end, hearted
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

        /// `sent_at` as a date (with or without fractional seconds); nil when missing or unreadable.
        var sentDate: Date? {
            guard let sentAt else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: sentAt) { return date }
            return ISO8601DateFormatter().date(from: sentAt)
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
    /// The plan panel (spec §6), when the activity follows the plan.
    case plan

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
        default:
            return nil
        }
    }
}
