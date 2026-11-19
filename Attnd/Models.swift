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
    /// API-016: the event's website (Attnd Studio). Only absolute `https` URLs; nil when there is none.
    var websiteUrl: URL? = nil
    /// API-018: what an assistant needs to know offline (about, FAQ, amenities, policies…); nil when none.
    var context: EventContext? = nil

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
        case websiteUrl = "website_url"
        case context
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
        websiteUrl = c.httpsURL(.websiteUrl)
        context = c.lenient(EventContext.self, .context).flatMap { $0.isEmpty ? nil : $0 }
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
    /// Lower-case labels (API-010), e.g. ["live music", "free"]; capitalise only for display (`TagText`).
    var tags: [String] = []
    /// API-018: about, menu, hours, accessibility, age limit, links; nil when none.
    var context: LocationContext? = nil

    var coordinate: Coordinate? { Coordinate.valid(latitude: latitude, longitude: longitude) }
}

extension Location: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, snippet, description, category, website, address, latitude, longitude, tags, context
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
        tags = c.lenient([String].self, .tags) ?? []
        context = c.lenient(LocationContext.self, .context).flatMap { $0.isEmpty ? nil : $0 }
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
    /// API-018: about, performers (bios, genres), price, age limit, accessibility, links; nil when none.
    var context: ScheduleItemContext? = nil
}

extension ScheduleItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, description, tags, context
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
        context = c.lenient(ScheduleItemContext.self, .context).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Notification
// Named AppNotification to avoid a clash with Foundation.Notification.

/// API-011: `urgent` is an organizer announcement such as a cancellation or a safety notice.
enum NotificationPriority: String, Hashable, Sendable {
    case normal, urgent
}

struct AppNotification: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var body: String = ""
    var sendTime: Date? = nil
    /// Any other or missing value is `normal`.
    var priority: NotificationPriority = .normal

    var isUrgent: Bool { priority == .urgent }
}

extension AppNotification: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, body, priority
        case sendTime = "send_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = c.lenient(String.self, .title) ?? ""
        body = c.lenient(String.self, .body) ?? ""
        sendTime = c.date(.sendTime)
        priority = c.nonEmptyString(.priority).flatMap { NotificationPriority(rawValue: $0) } ?? .normal
    }
}

// MARK: - Display (server-driven layout)

/// A tab the server can show. These are the only tabs in the tab bar: Options and search
/// are sheets (ContentView), never tabs.
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
        // A list, not a pin: Map and Locations must not look alike in the tab bar
        // (Android uses a list icon for Locations too).
        case .locations:     return "list.bullet"
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

    /// The most tabs the tab bar shows. With more, iPhone tab bars add a "More" tab, which the
    /// app never shows; there are only five event tabs today, so this only guards the future.
    static let maxTabs = 5

    /// Visible tabs in order (at most `maxTabs`, the server's order kept).
    /// Default: map, locations, schedule, (flyer), notifications.
    func resolvedTabs(hasFlyer: Bool) -> [EventTab] {
        if let tabs, !tabs.isEmpty { return Array(tabs.prefix(Self.maxTabs)) }
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

// MARK: - Saved event (offline copy)

/// The joined event as saved on disk (`EventStore`): the raw bundle JSON exactly as the
/// server sent it, plus the ETag and the time of the last successful refresh. Keeping the
/// raw body means a newer build decodes fields an older build didn't know about.
/// One file, written atomically, so the ETag can never be newer than the content.
struct SavedEvent: Codable, Hashable, Sendable {
    static let currentFormat = 1

    var format: Int = SavedEvent.currentFormat
    var eventId: Int
    var eventCode: String
    var etag: String?
    var lastRefreshed: Date?
    /// The bundle response body (base64 in the file).
    var bundleJSON: Data

    /// Decodes the saved bundle with the normal lenient decoder. Fails when the file is
    /// from an unknown format or belongs to a different event than its metadata says.
    func decodedBundle() throws -> EventBundle {
        guard format == Self.currentFormat else { throw SavedEventError.unsupportedFormat }
        let bundle = try JSONDecoder().decode(EventBundle.self, from: bundleJSON)
        guard bundle.event.id == eventId else { throw SavedEventError.eventMismatch }
        return bundle
    }

    /// Whether this copy belongs to the event the app last joined (`pref.savedEventCode`).
    func belongs(toEventCode code: String?) -> Bool {
        guard let code, !code.isEmpty else { return false }
        return eventCode.caseInsensitiveCompare(code) == .orderedSame
    }

    static func encode(_ saved: SavedEvent) throws -> Data {
        try JSONEncoder().encode(saved)
    }

    static func decode(_ data: Data) throws -> SavedEvent {
        try JSONDecoder().decode(SavedEvent.self, from: data)
    }
}

enum SavedEventError: Error, Sendable {
    case unsupportedFormat
    case eventMismatch
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

/// What `POST devices/` says about the Live Activity push token (API-011).
enum LiveActivityTokenChange: Hashable, Sendable {
    /// The key is left out: the server keeps what it has.
    case unchanged
    /// `"live_activity_token": "<hex>"`.
    case set(String)
    /// `"live_activity_token": null`: the activity ended.
    case clear
}

struct DeviceRequest: Encodable, Sendable {
    var deviceId: String
    var platform = "ios"
    var pushToken: String?
    var appVersion: String?
    var subscribed: Bool?
    var liveActivityToken: LiveActivityTokenChange = .unchanged

    enum CodingKeys: String, CodingKey {
        case platform, subscribed
        case deviceId = "device_id"
        case pushToken = "push_token"
        case appVersion = "app_version"
        case liveActivityToken = "live_activity_token"
    }

    /// Missing values are left out (never `"push_token": ""`, API-007), except a cleared
    /// Live Activity token, which is an explicit `null`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(platform, forKey: .platform)
        try c.encodeIfPresent(pushToken, forKey: .pushToken)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(subscribed, forKey: .subscribed)
        switch liveActivityToken {
        case .unchanged:        break
        case .set(let token):   try c.encode(token, forKey: .liveActivityToken)
        case .clear:            try c.encodeNil(forKey: .liveActivityToken)
        }
    }
}

// MARK: - Usage counts (API-005)

/// Anonymous usage metrics for `POST events/<id>/usage/`. Raw values are the wire names.
enum UsageMetric: String, Hashable, Sendable, CaseIterable {
    case appOpen = "app_open"
    case tabView = "tab_view"
    case locationView = "location_view"
    case scheduleItemView = "schedule_item_view"
    case notificationOpen = "notification_open"
    case search
    case refresh
    // API-009: hearts (detail = the location or schedule item id). Until the server knows
    // these names it drops them harmlessly.
    case locationHeart = "location_heart"
    case locationUnheart = "location_unheart"
    case scheduleItemHeart = "schedule_item_heart"
    case scheduleItemUnheart = "schedule_item_unheart"
    // API-014: anonymous performance counts (detail = bucket, `PerfBucket`), recorded through
    // `PerfMetrics` and sent with the joined event's batch (or the next one).
    case perfLaunchCold = "perf_launch_cold"
    case perfLaunchWarm = "perf_launch_warm"
    case perfBundleFetch = "perf_bundle_fetch"
    case perfBundle304 = "perf_bundle_304"
    case perfApiError = "perf_api_error"
    case perfPushRefreshDelay = "perf_push_refresh_delay"
    case perfLiveStartFail = "perf_live_start_fail"
    case perfPlannerMs = "perf_planner_ms"
    case perfMapFirstRender = "perf_map_first_render"
}

/// One aggregated count. `detail` is omitted from the JSON when nil.
/// Never carries a device ID, search text or anything else identifying.
struct UsageEntry: Encodable, Hashable, Sendable {
    var name: String
    var detail: String?
    var count: Int
    /// ISO 8601 start of the UTC 5-minute window the count belongs to, e.g. "2026-11-14T16:05:00Z".
    var at: String
}

/// Body of `POST events/<id>/usage/`.
struct UsageRequest: Encodable, Sendable {
    var platform = "ios"
    var events: [UsageEntry]
}

/// Pure in-memory aggregation of usage counts by (event, name, detail, UTC 5-minute bucket).
/// Owned by `UsageReporter`; kept free of networking so it can be unit tested.
struct UsageAggregator: Sendable {

    struct Key: Hashable, Sendable {
        var eventId: Int
        var name: String
        var detail: String?
        /// Start of the UTC 5-minute bucket.
        var bucket: Date
    }

    /// The server accepts up to 200 entries per request.
    static let maxEntriesPerRequest = 200

    private(set) var counts: [Key: Int] = [:]

    var isEmpty: Bool { counts.isEmpty }

    /// Length of one usage bucket: 5 minutes.
    static let bucketSeconds: TimeInterval = 5 * 60

    /// The start of the UTC 5-minute window containing `date` (:00, :05, … :55).
    /// The epoch is aligned to UTC and 5 minutes divides an hour, so whole
    /// multiples of 300 s since the epoch are exactly those UTC boundaries.
    static func bucketStart(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / bucketSeconds).rounded(.down) * bucketSeconds)
    }

    mutating func record(_ metric: UsageMetric, detail: String? = nil, eventId: Int, at date: Date = .now, count: Int = 1) {
        guard count > 0 else { return }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Key(
            eventId: eventId,
            name: metric.rawValue,
            detail: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            bucket: Self.bucketStart(date)
        )
        counts[key, default: 0] += count
    }

    /// Removes and returns everything recorded, grouped by event id, as wire entries
    /// (sorted by bucket, name and detail so output is deterministic).
    mutating func drain() -> [Int: [UsageEntry]] {
        let drained = counts
        counts = [:]
        var result: [Int: [UsageEntry]] = [:]
        let sortedKeys = drained.keys.sorted { a, b in
            if a.bucket != b.bucket { return a.bucket < b.bucket }
            if a.name != b.name { return a.name < b.name }
            return (a.detail ?? "") < (b.detail ?? "")
        }
        for key in sortedKeys {
            let entry = UsageEntry(
                name: key.name,
                detail: key.detail,
                count: drained[key] ?? 0,
                at: ISODate.string(from: key.bucket)
            )
            result[key.eventId, default: []].append(entry)
        }
        return result
    }

    /// Splits entries into request-sized chunks.
    static func chunks(_ entries: [UsageEntry]) -> [[UsageEntry]] {
        stride(from: 0, to: entries.count, by: maxEntriesPerRequest).map {
            Array(entries[$0..<min($0 + maxEntriesPerRequest, entries.count)])
        }
    }
}

/// Response of join / leave / devices. Every field is optional.
/// GET /api/app-status/ (API-003): whether this build should update.
struct AppStatus: Hashable, Sendable {
    enum Update: String, Sendable { case upToDate = "none", available, required }
    var update: Update = .upToDate
    var minVersion: String? = nil
    var latestVersion: String? = nil
    var updateURL: URL? = nil
    var message: String? = nil
}

extension AppStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case update, message
        case minVersion = "min_version"
        case latestVersion = "latest_version"
        case updateURL = "update_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown values (a future state) are treated as up to date rather than failing.
        update = c.nonEmptyString(.update).flatMap(Update.init(rawValue:)) ?? .upToDate
        minVersion = c.nonEmptyString(.minVersion)
        latestVersion = c.nonEmptyString(.latestVersion)
        updateURL = c.url(.updateURL)
        message = c.nonEmptyString(.message)
    }
}

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

    /// The push's `type` for logs ("notification", "content_updated", …, "none").
    var kindName: String {
        switch kind {
        case .notification?:      return "notification"
        case .contentUpdated?:    return "content_updated"
        case .other(let name)?:   return String(name.prefix(32))
        case nil:                 return "none"
        }
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

// MARK: - Rich context (API-018)
//
// `event.context`, `location.context` and `schedule_item.context`: compact text the organizer's
// AI import extracts for the on-device assistant (offline, nothing leaves the phone) and that the
// detail screens show. Every key may be missing; strings are trimmed (missing → ""), list
// elements without their required text are dropped, links are absolute `https` only, an unknown
// amenity kind is `other`, and an object with nothing in it decodes as nil.

/// A link the organizer added ("Bag policy", "Artist site"); `https` with a host only.
struct ContextLink: Hashable, Sendable {
    var title: String
    var url: URL
}

extension ContextLink: Decodable {
    private enum CodingKeys: String, CodingKey { case title, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.httpsURL(.url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an https URL")
        }
        self.url = url
        title = c.nonEmptyString(.title) ?? url.host ?? url.absoluteString
    }
}

/// One FAQ entry ("Can I bring a bag?" · "Clear bags only.").
struct FAQEntry: Hashable, Sendable {
    var question: String
    var answer: String
}

extension FAQEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case q, a }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let q = c.nonEmptyString(.q), let a = c.nonEmptyString(.a) else {
            throw DecodingError.dataCorruptedError(forKey: .q, in: c, debugDescription: "empty FAQ entry")
        }
        question = q
        answer = a
    }
}

enum AmenityKind: String, CaseIterable, Hashable, Sendable {
    case restrooms, water, atm
    case firstAid = "first_aid"
    case charging, lockers, info
    case accessibleEntrance = "accessible_entrance"
    case food, merch, parking, shuttle, other

    /// "Restrooms", "First aid", …
    var label: String {
        switch self {
        case .restrooms: return "Restrooms"
        case .water: return "Water"
        case .atm: return "ATM"
        case .firstAid: return "First aid"
        case .charging: return "Phone charging"
        case .lockers: return "Lockers"
        case .info: return "Information"
        case .accessibleEntrance: return "Accessible entrance"
        case .food: return "Food"
        case .merch: return "Merch"
        case .parking: return "Parking"
        case .shuttle: return "Shuttle"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .restrooms: return "toilet"
        case .water: return "drop"
        case .atm: return "banknote"
        case .firstAid: return "cross.case"
        case .charging: return "battery.100.bolt"
        case .lockers: return "lock"
        case .info: return "info.circle"
        case .accessibleEntrance: return "figure.roll"
        case .food: return "fork.knife"
        case .merch: return "tshirt"
        case .parking: return "parkingsign"
        case .shuttle: return "bus"
        case .other: return "mappin"
        }
    }
}

/// Restrooms, water, first aid… optionally at one of the event's locations.
struct Amenity: Hashable, Sendable {
    var kind: AmenityKind
    var name: String
    var locationId: Int? = nil
    var note: String = ""
}

extension Amenity: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, name, note
        case locationId = "location_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = c.nonEmptyString(.kind)
        kind = rawKind.flatMap { AmenityKind(rawValue: $0.lowercased()) } ?? .other
        guard let name = c.nonEmptyString(.name) ?? (rawKind != nil ? kind.label : nil) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "amenity without a name or kind")
        }
        self.name = name
        locationId = c.lenient(Int.self, .locationId)
        note = c.nonEmptyString(.note) ?? ""
    }
}

struct EventContext: Hashable, Sendable {
    var about: String = ""
    var faq: [FAQEntry] = []
    var amenities: [Amenity] = []
    var accessibility: String = ""
    var policies: String = ""
    var gettingThere: String = ""
    var weatherPlan: String = ""
    var links: [ContextLink] = []

    var isEmpty: Bool { self == EventContext() }
}

extension EventContext: Decodable {
    private enum CodingKeys: String, CodingKey {
        case about, faq, amenities, accessibility, policies, links
        case gettingThere = "getting_there"
        case weatherPlan = "weather_plan"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        about = c.nonEmptyString(.about) ?? ""
        faq = c.lossyArray(FAQEntry.self, .faq)
        amenities = c.lossyArray(Amenity.self, .amenities)
        accessibility = c.nonEmptyString(.accessibility) ?? ""
        policies = c.nonEmptyString(.policies) ?? ""
        gettingThere = c.nonEmptyString(.gettingThere) ?? ""
        weatherPlan = c.nonEmptyString(.weatherPlan) ?? ""
        links = c.lossyArray(ContextLink.self, .links)
    }
}

/// One menu line ("Brisket plate" · "$14" · "Gluten-free").
struct MenuEntry: Hashable, Sendable {
    var name: String
    var price: String = ""
    var note: String = ""
}

extension MenuEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case name, price, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.nonEmptyString(.name) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "menu entry without a name")
        }
        self.name = name
        // A number price ("12.5") is shown as sent.
        price = c.nonEmptyString(.price) ?? c.lenient(Double.self, .price).map { String(describing: $0) } ?? ""
        note = c.nonEmptyString(.note) ?? ""
    }
}

struct LocationContext: Hashable, Sendable {
    var about: String = ""
    var menu: [MenuEntry] = []
    var hours: String = ""
    var accessibility: String = ""
    var ageLimit: String = ""
    var links: [ContextLink] = []

    var isEmpty: Bool { self == LocationContext() }
}

extension LocationContext: Decodable {
    private enum CodingKeys: String, CodingKey {
        case about, menu, hours, accessibility, links
        case ageLimit = "age_limit"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        about = c.nonEmptyString(.about) ?? ""
        menu = c.lossyArray(MenuEntry.self, .menu)
        hours = c.nonEmptyString(.hours) ?? ""
        accessibility = c.nonEmptyString(.accessibility) ?? ""
        ageLimit = c.nonEmptyString(.ageLimit) ?? ""
        links = c.lossyArray(ContextLink.self, .links)
    }
}

/// A performer, speaker or vendor of a schedule item.
struct Performer: Hashable, Sendable {
    var name: String
    var bio: String = ""
    /// As sent ("country", "Texas swing"), trimmed, empty ones dropped.
    var genres: [String] = []
}

extension Performer: Decodable {
    private enum CodingKeys: String, CodingKey { case name, bio, genres }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.nonEmptyString(.name) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "performer without a name")
        }
        self.name = name
        bio = c.nonEmptyString(.bio) ?? ""
        genres = c.lossyArray(String.self, .genres)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct ScheduleItemContext: Hashable, Sendable {
    var about: String = ""
    var performers: [Performer] = []
    var ageLimit: String = ""
    var price: String = ""
    var accessibility: String = ""
    var links: [ContextLink] = []

    var isEmpty: Bool { self == ScheduleItemContext() }

    /// Every performer's genres, distinct, in order.
    var genres: [String] {
        var seen = Set<String>()
        return performers.flatMap(\.genres).filter { seen.insert($0.lowercased()).inserted }
    }
}

extension ScheduleItemContext: Decodable {
    private enum CodingKeys: String, CodingKey {
        case about, performers, price, accessibility, links
        case ageLimit = "age_limit"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        about = c.nonEmptyString(.about) ?? ""
        performers = c.lossyArray(Performer.self, .performers)
        ageLimit = c.nonEmptyString(.ageLimit) ?? ""
        price = c.nonEmptyString(.price) ?? ""
        accessibility = c.nonEmptyString(.accessibility) ?? ""
        links = c.lossyArray(ContextLink.self, .links)
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

    /// An absolute `https` URL with a host, or nil (missing, null, blank, `http`, other schemes, relative).
    func httpsURL(_ key: Key) -> URL? {
        guard let url = url(key), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
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
