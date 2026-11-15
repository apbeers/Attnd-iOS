// PlanWidgetModel.swift
// Attnd (app) + AttndWidgets (widget extension)
//
// The "Now / Next in my plan" widget's data (assistant spec §6): a small JSON file in the App
// Group container (`group.com.arcu.Attnd`) that the app writes on every bundle, plan or like
// change (PlanWidgetSync.swift, app only) and the widget reads (AttndWidgets/PlanWidget.swift).
// The widget never touches the network or the bundle: it shows what is in this file, with a
// timeline entry at every item start and end, so now / next move on by themselves.
//
// What it lists: the plan's items (spec §6), else the user's liked items, else the event's own
// upcoming schedule (as the Live Activity: plan > likes > the event), at most `maxItems`, not
// yet ended when written, by start. Walk texts are from the previous listed item's place
// (the plan's walk legs, or the straight-line estimate between liked items).
//
// No Models.swift types here (the widget extension only has this file and the Live Activity
// files). Decoding is lenient: a file from a newer build still loads; an unreadable one is nil.

import Foundation

struct PlanWidgetSnapshot: Codable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        case plan, likes, event
    }

    struct Item: Codable, Hashable, Sendable, Identifiable {
        var id: Int
        var name: String
        /// Location name ("General" without one).
        var location: String?
        var start: Date
        /// The end, or start + 1 h.
        var end: Date
        /// "4 min walk" from the previous listed item's place; nil when there's no walk.
        var walkText: String?
        var liked: Bool

        init(id: Int, name: String, location: String?, start: Date, end: Date, walkText: String?, liked: Bool) {
            self.id = id
            self.name = name
            self.location = location
            self.start = start
            self.end = end
            self.walkText = walkText
            self.liked = liked
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            location = try? c.decodeIfPresent(String.self, forKey: .location)
            start = try c.decode(Date.self, forKey: .start)
            end = (try? c.decode(Date.self, forKey: .end)) ?? start.addingTimeInterval(3600)
            walkText = try? c.decodeIfPresent(String.self, forKey: .walkText)
            liked = (try? c.decode(Bool.self, forKey: .liked)) ?? false
        }
    }

    /// At most this many items are written.
    static let maxItems = 30

    var eventId: Int
    var eventName: String
    /// `display.accent_color` or the event's (`#RRGGBB`); nil → the brand purple.
    var accentHex: String?
    /// The event's IANA time zone (times are shown in it).
    var timeZoneIdentifier: String
    var source: Source
    /// By start, then id.
    var items: [Item]

    init(eventId: Int, eventName: String, accentHex: String?, timeZoneIdentifier: String, source: Source, items: [Item]) {
        self.eventId = eventId
        self.eventName = eventName
        self.accentHex = accentHex
        self.timeZoneIdentifier = timeZoneIdentifier
        self.source = source
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(Int.self, forKey: .eventId)
        eventName = (try? c.decode(String.self, forKey: .eventName)) ?? ""
        accentHex = try? c.decodeIfPresent(String.self, forKey: .accentHex)
        timeZoneIdentifier = (try? c.decode(String.self, forKey: .timeZoneIdentifier)) ?? TimeZone.current.identifier
        source = (try? c.decode(Source.self, forKey: .source)) ?? .event
        // Items that don't decode are dropped, not the whole file.
        let lossy = (try? c.decode([LossyItem].self, forKey: .items)) ?? []
        items = lossy.compactMap(\.item)
    }

    private struct LossyItem: Decodable {
        var item: Item?
        init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// The item in progress at `date` that started last (ties: lowest id).
    func current(at date: Date) -> Item? {
        items
            .filter { $0.start <= date && date < $0.end }
            .max { ($0.start, -$0.id) < ($1.start, -$1.id) }
    }

    /// The first item starting after `date`.
    func next(after date: Date) -> Item? {
        items.filter { $0.start > date }.min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// Every item start and end after `date`, sorted, at most `limit`: the widget's timeline entries.
    func boundaries(after date: Date, limit: Int = 40) -> [Date] {
        let all = Set(items.flatMap { [$0.start, $0.end] }).filter { $0 > date }
        return Array(all.sorted().prefix(limit))
    }

    /// The widget gallery's sample.
    static let placeholder: PlanWidgetSnapshot = {
        let now = Date.now
        return PlanWidgetSnapshot(
            eventId: 0,
            eventName: "Your event",
            accentHex: nil,
            timeZoneIdentifier: TimeZone.current.identifier,
            source: .plan,
            items: [
                Item(id: 1, name: "The Prairie Lights", location: "Main Stage", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60), walkText: nil, liked: true),
                Item(id: 2, name: "Neon Armadillo", location: "Trinity Stage", start: now.addingTimeInterval(55 * 60), end: now.addingTimeInterval(115 * 60), walkText: "4 min walk", liked: true),
            ]
        )
    }()
}

/// The App Group file both sides use.
enum PlanWidgetStore {
    /// App Group of the app and the widget extension (both entitlements files).
    static let appGroup = "group.com.arcu.Attnd"
    /// The widget's kind (`WidgetCenter.reloadTimelines(ofKind:)`).
    static let kind = "com.arcu.Attnd.plan-now-next"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget", directoryHint: .isDirectory)
            .appending(path: "plan-now-next.json", directoryHint: .notDirectory)
    }

    static func encode(_ snapshot: PlanWidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data) -> PlanWidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(PlanWidgetSnapshot.self, from: data)
    }

    /// The written snapshot; nil without one (no event, nothing written yet, or no App Group).
    static func read() -> PlanWidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
