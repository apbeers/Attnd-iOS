// EventEntities.swift
// Attnd (app target only — not in the App Clip)
//
// App Intents entities for the joined event, so Siri, Shortcuts, Spotlight and Apple
// Intelligence can find and open them: schedule items, locations, organizer updates and the
// event itself. Everything comes from the bundle already on the device (no server calls).
//
//   - Queries resolve ids from the current bundle and string queries with the app's own local
//     search (EventSearch), so "when is the mariachi" matches the same way the search sheet does.
//   - IndexedEntity: `EventEntityIndex` re-indexes Core Spotlight after every applied bundle
//     and removes everything when the event is left (AppState.apply / resetContent).
//   - Views annotate what they show with `.onScreenEntity(_:)` (EventSearchView.swift) so Siri
//     understands "this" (on-screen awareness).
//
// Intents run in the app process. `IntentBridge` reaches the app's AppState (set by
// AppDelegate) and restores the saved event from disk first when Siri launched the app in
// the background.

import AppIntents
import CoreSpotlight
import Foundation

// MARK: - Bridge to the app's state

@MainActor
enum IntentBridge {
    /// Set by AppDelegate at launch.
    static weak var appState: AppState?

    /// The joined event's content, restoring the offline copy first if needed. nil outside an event.
    static func bundle() async -> EventBundle? {
        guard let appState else { return nil }
        await appState.restoreSavedEventIfNeeded()
        return appState.currentBundle
    }

    /// Opens an item in the app (its tab, or the search sheet when that tab is hidden).
    static func navigate(to target: SearchTarget) async {
        guard let appState else { return }
        await appState.restoreSavedEventIfNeeded()
        appState.navigate(to: target)
    }

    static func showSearch(_ query: String) async {
        guard let appState else { return }
        await appState.restoreSavedEventIfNeeded()
        appState.showSearch(query)
    }
}

/// String queries for entities: the local search, retried with the question's keywords
/// ("when is the mariachi" → "mariachi") when the words as given match nothing.
enum EntityLookup {
    static func targets(_ string: String, bundle: EventBundle, now: Date = .now) -> [SearchTarget] {
        let index = EventSearchIndex(bundle)
        var results = index.search(string, now: now)
        if results.isEmpty {
            let keywords = EventSearch.keywords(fromQuestion: string)
            if !keywords.isEmpty { results = index.search(keywords, now: now) }
        }
        return results.map(\.target)
    }
}

// MARK: - Entity identifiers (on-screen awareness)

extension SearchTarget {
    var entityIdentifier: EntityIdentifier {
        switch self {
        case .scheduleItem(let id): return EntityIdentifier(for: ScheduleItemEntity.self, identifier: id)
        case .location(let id):     return EntityIdentifier(for: LocationEntity.self, identifier: id)
        case .notification(let id): return EntityIdentifier(for: NotificationEntity.self, identifier: id)
        case .event(let id):        return EntityIdentifier(for: EventEntity.self, identifier: id)
        }
    }
}

// MARK: - Schedule item

struct ScheduleItemEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Schedule Item")
    }

    static var defaultQuery: ScheduleItemQuery { ScheduleItemQuery() }

    let id: Int
    var name: String
    /// "Sat 7:30 – 8:30 PM" in the event's time zone.
    var timeText: String
    var locationName: String
    var details: String
    var tags: [String]
    var startTime: Date?
    var endTime: Date?
    var locationId: Int?

    init(_ item: ScheduleItem, bundle: EventBundle) {
        id = item.id
        name = item.name
        timeText = EventSearch.dayTimeRange(start: item.startTime, end: item.endTime, timeZone: bundle.event.timeZone)
        locationName = item.locationName
            ?? item.locationId.flatMap { id in bundle.locations.first { $0.id == id }?.name }
            ?? EventSearch.generalLocation
        details = item.description
        tags = item.tags
        startTime = item.startTime
        endTime = item.endTime
        locationId = item.locationId
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(timeText) · \(locationName)",
            image: DisplayRepresentation.Image(systemName: "calendar")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = [timeText, locationName, details].filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.keywords = tags + [locationName]
        attributes.startDate = startTime
        attributes.endDate = endTime
        attributes.namedLocation = locationName
        return attributes
    }
}

struct ScheduleItemQuery: EntityStringQuery {
    func entities(for identifiers: [ScheduleItemEntity.ID]) async throws -> [ScheduleItemEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        return identifiers.compactMap { id in
            bundle.schedule.first { $0.id == id }.map { ScheduleItemEntity($0, bundle: bundle) }
        }
    }

    func entities(matching string: String) async throws -> [ScheduleItemEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        let ids = EntityLookup.targets(string, bundle: bundle).compactMap { target -> Int? in
            if case .scheduleItem(let id) = target { return id }
            return nil
        }
        return try await entities(for: Array(ids.prefix(20)))
    }

    /// What's on now and next, then later items; ended items are left out.
    func suggestedEntities() async throws -> [ScheduleItemEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        let now = Date.now
        let upcoming = bundle.schedule.filter { !ScheduleTiming.hasEnded($0, at: now) }
        return upcoming.prefix(30).map { ScheduleItemEntity($0, bundle: bundle) }
    }
}

// MARK: - Location

struct LocationEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Location")
    }

    static var defaultQuery: LocationQuery { LocationQuery() }

    let id: Int
    var name: String
    var category: String?
    var snippet: String
    var details: String
    var address: String
    var latitude: Double?
    var longitude: Double?

    init(_ location: Location) {
        id = location.id
        name = location.name
        category = location.category
        snippet = location.snippet
        details = location.description
        address = location.address
        latitude = location.coordinate?.latitude
        longitude = location.coordinate?.longitude
    }

    var displayRepresentation: DisplayRepresentation {
        let info = [category ?? "", snippet].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: info.isEmpty ? nil : "\(info)",
            image: DisplayRepresentation.Image(systemName: "mappin.and.ellipse")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = [snippet, address, details].filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.keywords = [category].compactMap { $0 }
        attributes.namedLocation = name
        if let latitude, let longitude {
            attributes.latitude = NSNumber(value: latitude)
            attributes.longitude = NSNumber(value: longitude)
        }
        return attributes
    }
}

struct LocationQuery: EntityStringQuery {
    func entities(for identifiers: [LocationEntity.ID]) async throws -> [LocationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        return identifiers.compactMap { id in
            bundle.locations.first { $0.id == id }.map(LocationEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [LocationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        let ids = EntityLookup.targets(string, bundle: bundle).compactMap { target -> Int? in
            if case .location(let id) = target { return id }
            return nil
        }
        return try await entities(for: Array(ids.prefix(20)))
    }

    func suggestedEntities() async throws -> [LocationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        return bundle.locations.prefix(30).map(LocationEntity.init)
    }
}

// MARK: - Organizer update (notification)

struct NotificationEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Event Update")
    }

    static var defaultQuery: NotificationQuery { NotificationQuery() }

    let id: Int
    var title: String
    var body: String
    var sentText: String
    var sendTime: Date?

    init(_ notification: AppNotification, bundle: EventBundle) {
        id = notification.id
        title = notification.title
        body = notification.body
        sendTime = notification.sendTime
        sentText = notification.sendTime.map { EventTimeFormat.shortDayTime($0, in: bundle.event.timeZone) } ?? ""
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(EventSearch.excerpt(body, limit: 100))",
            image: DisplayRepresentation.Image(systemName: "bell")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = body
        attributes.contentCreationDate = sendTime
        return attributes
    }
}

struct NotificationQuery: EntityStringQuery {
    func entities(for identifiers: [NotificationEntity.ID]) async throws -> [NotificationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        return identifiers.compactMap { id in
            bundle.notifications.first { $0.id == id }.map { NotificationEntity($0, bundle: bundle) }
        }
    }

    func entities(matching string: String) async throws -> [NotificationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        let ids = EntityLookup.targets(string, bundle: bundle).compactMap { target -> Int? in
            if case .notification(let id) = target { return id }
            return nil
        }
        return try await entities(for: Array(ids.prefix(20)))
    }

    /// Newest first (the bundle's order).
    func suggestedEntities() async throws -> [NotificationEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        return bundle.notifications.prefix(10).map { NotificationEntity($0, bundle: bundle) }
    }
}

// MARK: - Event

struct EventEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Event")
    }

    static var defaultQuery: EventQuery { EventQuery() }

    let id: Int
    var name: String
    var code: String
    var dates: String
    var address: String
    var details: String
    var startTime: Date?
    var endTime: Date?

    init(_ event: Event) {
        id = event.id
        name = event.name
        code = event.eventCode
        dates = EventSearch.dateRange(start: event.startTime, end: event.endTime, timeZone: event.timeZone) ?? ""
        address = event.address
        details = event.description
        startTime = event.startTime
        endTime = event.endTime
    }

    var displayRepresentation: DisplayRepresentation {
        let info = [dates, address].filter { !$0.isEmpty }.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: info.isEmpty ? nil : "\(info)",
            image: DisplayRepresentation.Image(systemName: "ticket")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = [dates, address, details].filter { !$0.isEmpty }.joined(separator: " · ")
        attributes.keywords = [code]
        attributes.startDate = startTime
        attributes.endDate = endTime
        attributes.namedLocation = address.isEmpty ? nil : address
        return attributes
    }
}

struct EventQuery: EntityStringQuery {
    func entities(for identifiers: [EventEntity.ID]) async throws -> [EventEntity] {
        guard let event = await IntentBridge.bundle()?.event, identifiers.contains(event.id) else { return [] }
        return [EventEntity(event)]
    }

    func entities(matching string: String) async throws -> [EventEntity] {
        guard let bundle = await IntentBridge.bundle() else { return [] }
        let matches = EntityLookup.targets(string, bundle: bundle).contains(.event(bundle.event.id))
        return matches ? [EventEntity(bundle.event)] : []
    }

    func suggestedEntities() async throws -> [EventEntity] {
        guard let event = await IntentBridge.bundle()?.event else { return [] }
        return [EventEntity(event)]
    }
}

// MARK: - Spotlight index

/// Keeps Core Spotlight in step with the shown content: after every applied bundle the old
/// entities are removed and the current ones indexed; leaving the event removes them all.
/// Updates run one after another; a newer update makes an older, still waiting one a no-op.
@MainActor
final class EventEntityIndex {
    static let shared = EventEntityIndex()

    private var chain: Task<Void, Never>?
    private var generation = 0

    func update(with bundle: EventBundle?) {
        // Screenshot runs leave the attendee's Spotlight alone.
        guard !ScreenshotMode.isActive else { return }
        generation += 1
        let mine = generation
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            guard mine == self.generation else { return }
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: ScheduleItemEntity.self)
            try? await index.deleteAppEntities(ofType: LocationEntity.self)
            try? await index.deleteAppEntities(ofType: NotificationEntity.self)
            try? await index.deleteAppEntities(ofType: EventEntity.self)
            if let bundle {
                try? await index.indexAppEntities(bundle.schedule.map { ScheduleItemEntity($0, bundle: bundle) })
                try? await index.indexAppEntities(bundle.locations.map(LocationEntity.init))
                try? await index.indexAppEntities(bundle.notifications.map { NotificationEntity($0, bundle: bundle) })
                try? await index.indexAppEntities([EventEntity(bundle.event)], priority: 1)
            }
            // Parameterised App Shortcut phrases ("When is <item> in Attnd") use the new names.
            AttndShortcuts.updateAppShortcutParameters()
        }
    }
}
