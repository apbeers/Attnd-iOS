// Models.swift
// Attnd
//
// Data models for the Attnd API v2 (see API_V2.md).
//
// Forward compatibility rules from the contract, applied to every model here:
//   - unknown keys are ignored (Decodable does this by default),
//   - missing keys — and keys with an unexpected type — fall back to defaults,
//   - coordinates may be null and are never replaced with 0,0,
//   - unknown enum values (tabs, styles, status) fall back to defaults.
//
// Decoders live in extensions so every struct keeps its memberwise initializer
// for previews and tests.

import Foundation

// MARK: - Event

enum EventStatus: String, Sendable, Hashable {
    case published
    case archived
}

struct Event: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var eventCode: String
    var description: String = ""
    var address: String = ""
    var latitude: Double? = nil
    var longitude: Double? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    /// IANA identifier, e.g. "America/Chicago". Use `timeZone` for display.
    var timeZoneIdentifier: String? = nil
    var status: EventStatus = .published
    var paid: Bool = false
    var isDemo: Bool = false
    var flyerUrl: URL? = nil
    var accentColor: String? = nil
    var logoUrl: URL? = nil
    var contentVersion: Int = 0
    var joinUrl: URL? = nil

    /// The event's own time zone. All event times are displayed in it.
    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    var coordinate: Coordinate? { Coordinate.valid(latitude: latitude, longitude: longitude) }
    var isArchived: Bool { status == .archived }
}

extension Event: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, address, latitude, longitude, timezone, status, paid
        case eventCode = "event_code"
        case startTime = "start_time"
        case endTime = "end_time"
        case isDemo = "is_demo"
        case flyerUrl = "flyer_url"
        case accentColor = "accent_color"
        case logoUrl = "logo_url"
        case contentVersion = "content_version"
        case joinUrl = "join_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        eventCode = c.lenient(String.self, .eventCode) ?? ""
        description = c.lenient(String.self, .description) ?? ""
        address = c.lenient(String.self, .address) ?? ""
        latitude = c.lenient(Double.self, .latitude)
        longitude = c.lenient(Double.self, .longitude)
        startTime = c.date(.startTime)
        endTime = c.date(.endTime)
        timeZoneIdentifier = c.lenient(String.self, .timezone)
        status = c.lenient(String.self, .status).flatMap(EventStatus.init(rawValue:)) ?? .published
        let paid = c.lenient(Bool.self, .paid)
        self.paid = paid ?? false
        // Older payloads only carried `paid`; an unpaid event is a demo.
        isDemo = c.lenient(Bool.self, .isDemo) ?? (paid.map { !$0 } ?? false)
        flyerUrl = c.url(.flyerUrl)
        accentColor = c.lenient(String.self, .accentColor)
        logoUrl = c.url(.logoUrl)
        contentVersion = c.lenient(Int.self, .contentVersion) ?? 0
        joinUrl = c.url(.joinUrl)
    }
}

// MARK: - Nearby / Lookup

struct NearbyEventResult: Identifiable, Hashable, Sendable {
    var id: Int { event.id }
    var event: Event
    var distanceMiles: Double?
    var startsInHours: Double?
}

extension NearbyEventResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event
        case distanceMiles = "distance_miles"
        case startsInHours = "starts_in_hours"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(Event.self, forKey: .event)
        distanceMiles = c.lenient(Double.self, .distanceMiles)
        startsInHours = c.lenient(Double.self, .startsInHours)
    }
}

/// `GET events/nearby/`
struct NearbyEventsResponse: Decodable, Sendable {
    var results: [NearbyEventResult]

    private enum CodingKeys: String, CodingKey { case results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(NearbyEventResult.self, .results)
    }
}

/// `GET events/lookup/`
struct LookupResponse: Decodable, Sendable {
    var event: Event
}

// MARK: - Location

struct Location: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var snippet: String = ""
    var description: String = ""
    var category: String? = nil
    var website: URL? = nil
    var imageUrl: URL? = nil
    var address: String = ""
    var latitude: Double? = nil
    var longitude: Double? = nil
    var sortOrder: Int = 0

    var coordinate: Coordinate? { Coordinate.valid(latitude: latitude, longitude: longitude) }
}

extension Location: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, snippet, description, category, website, address, latitude, longitude
        case imageUrl = "image_url"
        case sortOrder = "sort_order"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        snippet = c.lenient(String.self, .snippet) ?? ""
        description = c.lenient(String.self, .description) ?? ""
        category = c.nonEmptyString(.category)
        website = c.url(.website)
        imageUrl = c.url(.imageUrl)
        address = c.lenient(String.self, .address) ?? ""
        latitude = c.lenient(Double.self, .latitude)
        longitude = c.lenient(Double.self, .longitude)
        sortOrder = c.lenient(Int.self, .sortOrder) ?? 0
    }
}

// MARK: - Schedule Item

struct ScheduleItem: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var description: String = ""
    var startTime: Date? = nil
    var endTime: Date? = nil
    /// nil when the item has no location ("General").
    var locationId: Int? = nil
    var locationName: String? = nil
    var tags: [String] = []
}

extension ScheduleItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, tags
        case startTime = "start_time"
        case endTime = "end_time"
        case locationId = "location_id"
        case locationName = "location_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        description = c.lenient(String.self, .description) ?? ""
        startTime = c.date(.startTime)
        endTime = c.date(.endTime)
        locationId = c.lenient(Int.self, .locationId)
        locationName = c.nonEmptyString(.locationName)
        tags = c.lenient([String].self, .tags) ?? []
    }
}

// MARK: - Notification
// Named AppNotification to avoid a clash with Foundation.Notification.

struct AppNotification: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var body: String = ""
    var sendTime: Date? = nil
}

extension AppNotification: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, body
        case sendTime = "send_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = c.lenient(String.self, .title) ?? ""
        body = c.lenient(String.self, .body) ?? ""
        sendTime = c.date(.sendTime)
    }
}

// MARK: - Display (server-driven layout)

/// A tab the server can show. The app's own Options tab is not part of this.
enum EventTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case map, locations, schedule, flyer, notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map:           return "Map"
        case .locations:     return "Locations"
        case .schedule:      return "Schedule"
        case .flyer:         return "Flyer"
        case .notifications: return "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .map:           return "map"
        case .locations:     return "mappin.and.ellipse"
        case .schedule:      return "calendar"
        case .flyer:         return "doc.richtext"
        case .notifications: return "bell"
        }
    }
}

enum LocationsStyle: String, Hashable, Sendable {
    case cards, list, grouped
}

enum ScheduleStyle: String, Hashable, Sendable {
    case timeline
    case byDay = "by_day"
    case byLocation = "by_location"
    case nowNext = "now_next"
}

enum SecondaryPane: String, Hashable, Sendable {
    case locations, schedule
    case nowNext = "now_next"
    case none
}

/// The organizer's layout choices. Every key falls back to the client defaults
/// listed in API_V2.md when it is missing, null, of the wrong type, or unknown.
struct DisplayConfig: Hashable, Sendable {
    /// nil means "not sent" — resolve with `resolvedTabs(hasFlyer:)`.
    var tabs: [EventTab]? = nil
    var defaultTab: EventTab? = nil
    var locationsStyle: LocationsStyle = .list
    var scheduleStyle: ScheduleStyle = .byDay
    var mapClustering: Bool = false
    var mapFitAll: Bool = true
    var showLocationImages: Bool = true
    var enableSearch: Bool = true
    var groupByCategory: Bool = false
    var secondaryPane: SecondaryPane = .locations
    var accentColor: String? = nil
    var logoUrl: URL? = nil

    static let `default` = DisplayConfig()

    /// Visible tabs in order. Default: map, locations, schedule, (flyer), notifications.
    func resolvedTabs(hasFlyer: Bool) -> [EventTab] {
        if let tabs, !tabs.isEmpty { return tabs }
        var result: [EventTab] = [.map, .locations, .schedule]
        if hasFlyer { result.append(.flyer) }
        result.append(.notifications)
        return result
    }

    /// The tab selected after joining: `default_tab` if visible, else map, else the first tab.
    func resolvedDefaultTab(hasFlyer: Bool) -> EventTab {
        let tabs = resolvedTabs(hasFlyer: hasFlyer)
        if let defaultTab, tabs.contains(defaultTab) { return defaultTab }
        if tabs.contains(.map) { return .map }
        return tabs.first ?? .map
    }
}

extension DisplayConfig: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tabs
        case defaultTab = "default_tab"
        case locationsStyle = "locations_style"
        case scheduleStyle = "schedule_style"
        case mapClustering = "map_clustering"
        case mapFitAll = "map_fit_all"
        case showLocationImages = "show_location_images"
        case enableSearch = "enable_search"
        case groupByCategory = "group_by_category"
        case secondaryPane = "secondary_pane"
        case accentColor = "accent_color"
        case logoUrl = "logo_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayConfig.default
        if let raw = c.lenient([String].self, .tabs) {
            // Ignore unknown values and duplicates, keep the server's order.
            var seen = Set<EventTab>()
            tabs = raw.compactMap(EventTab.init(rawValue:)).filter { seen.insert($0).inserted }
        } else {
            tabs = nil
        }
        defaultTab = c.lenient(String.self, .defaultTab).flatMap(EventTab.init(rawValue:))
        locationsStyle = c.lenient(String.self, .locationsStyle).flatMap(LocationsStyle.init(rawValue:)) ?? d.locationsStyle
        scheduleStyle = c.lenient(String.self, .scheduleStyle).flatMap(ScheduleStyle.init(rawValue:)) ?? d.scheduleStyle
        mapClustering = c.lenient(Bool.self, .mapClustering) ?? d.mapClustering
        mapFitAll = c.lenient(Bool.self, .mapFitAll) ?? d.mapFitAll
        showLocationImages = c.lenient(Bool.self, .showLocationImages) ?? d.showLocationImages
        enableSearch = c.lenient(Bool.self, .enableSearch) ?? d.enableSearch
        groupByCategory = c.lenient(Bool.self, .groupByCategory) ?? d.groupByCategory
        secondaryPane = c.lenient(String.self, .secondaryPane).flatMap(SecondaryPane.init(rawValue:)) ?? d.secondaryPane
        accentColor = c.nonEmptyString(.accentColor)
        logoUrl = c.url(.logoUrl)
    }
}

// MARK: - Bundle

/// `GET events/<id>/bundle/` — everything the app shows, in one response.
struct EventBundle: Hashable, Sendable {
    var schemaVersion: Int = 2
    var contentVersion: Int = 0
    var updatedAt: Date? = nil
    var event: Event
    var display: DisplayConfig = .default
    var categories: [String] = []
    var locations: [Location] = []
    var schedule: [ScheduleItem] = []
    var notifications: [AppNotification] = []
}

extension EventBundle: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event, display, categories, locations, schedule, notifications
        case schemaVersion = "schema_version"
        case contentVersion = "content_version"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(Event.self, forKey: .event)
        schemaVersion = c.lenient(Int.self, .schemaVersion) ?? 2
        contentVersion = c.lenient(Int.self, .contentVersion) ?? event.contentVersion
        updatedAt = c.date(.updatedAt)
        display = c.lenient(DisplayConfig.self, .display) ?? .default
        categories = c.lenient([String].self, .categories) ?? []
        locations = c.lossyArray(Location.self, .locations)
        schedule = c.lossyArray(ScheduleItem.self, .schedule)
        notifications = c.lossyArray(AppNotification.self, .notifications)
    }
}

// MARK: - Write endpoints

struct JoinRequest: Encodable, Sendable {
    var deviceId: String
    var platform = "ios"
    var pushToken: String?
    var appVersion: String?

    enum CodingKeys: String, CodingKey {
        case platform
        case deviceId = "device_id"
        case pushToken = "push_token"
        case appVersion = "app_version"
    }
}

struct LeaveRequest: Encodable, Sendable {
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
    }
}

struct DeviceRequest: Encodable, Sendable {
    var deviceId: String
    var platform = "ios"
    var pushToken: String?
    var appVersion: String?
    var subscribed: Bool?

    enum CodingKeys: String, CodingKey {
        case platform, subscribed
        case deviceId = "device_id"
        case pushToken = "push_token"
        case appVersion = "app_version"
    }
}

/// Response of join / leave / devices. Every field is optional.
struct StatusResponse: Hashable, Sendable {
    var status: String? = nil
    var contentVersion: Int? = nil
    var subscribed: Bool? = nil
    var eventId: Int? = nil
}

extension StatusResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, subscribed
        case contentVersion = "content_version"
        case eventId = "event_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(String.self, .status)
        contentVersion = c.lenient(Int.self, .contentVersion)
        subscribed = c.lenient(Bool.self, .subscribed)
        eventId = c.lenient(Int.self, .eventId)
    }
}

// MARK: - Push payload

/// The custom keys of an Attnd push (top-level in the APNs payload, next to `aps`).
struct PushPayload: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case notification
        case contentUpdated
        case other(String)
    }

    var kind: Kind?
    var eventId: Int?
    var notificationId: Int?
    var contentVersion: Int?

    init(kind: Kind?, eventId: Int?, notificationId: Int? = nil, contentVersion: Int? = nil) {
        self.kind = kind
        self.eventId = eventId
        self.notificationId = notificationId
        self.contentVersion = contentVersion
    }

    init(userInfo: [AnyHashable: Any]) {
        switch userInfo["type"] as? String {
        case "notification"?:    kind = .notification
        case "content_updated"?: kind = .contentUpdated
        case let other?:         kind = .other(other)
        case nil:                kind = nil
        }
        eventId = Self.int(userInfo["event_id"])
        notificationId = Self.int(userInfo["notification_id"])
        contentVersion = Self.int(userInfo["content_version"])
    }

    /// APNs JSON numbers arrive as NSNumber; FCM-style payloads use strings.
    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int:    return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default:              return nil
        }
    }
}

// MARK: - Coordinate

/// A validated latitude/longitude pair. Kept free of CoreLocation so it is
/// trivially Sendable and usable from pure, testable logic.
struct Coordinate: Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Returns nil for missing, out-of-range or 0,0 coordinates (0,0 is never a real venue).
    static func valid(latitude: Double?, longitude: Double?) -> Coordinate? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0)
        else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Lenient decoding helpers

extension KeyedDecodingContainer {
    /// Decodes `type` for `key`, returning nil when the key is missing, null, or of the wrong type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        // `try?` flattens the optional, so a type mismatch and a missing key both give nil.
        try? decodeIfPresent(type, forKey: key)
    }

    /// A trimmed string, or nil when missing or empty.
    func nonEmptyString(_ key: Key) -> String? {
        guard let s = lenient(String.self, key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    func url(_ key: Key) -> URL? {
        nonEmptyString(key).flatMap { URL(string: $0) }
    }

    /// An ISO 8601 timestamp (with or without fractional seconds), or nil.
    func date(_ key: Key) -> Date? {
        lenient(String.self, key).flatMap(ISODate.parse)
    }

    /// An array that skips elements which fail to decode instead of failing as a whole.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        lenient(LossyArray<T>.self, key)?.elements ?? []
    }
}

private struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(SkippedValue.self)) == nil {
                break // cannot advance; bail out rather than loop forever
            }
        }
        self.elements = elements
    }

    /// Decodes (and discards) any JSON value so the container advances past a bad element.
    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
