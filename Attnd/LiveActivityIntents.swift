// LiveActivityIntents.swift
// Attnd, AttndAppClip + AttndWidgets, AttndClipWidgets (widget extensions)
//
// The Live Activity's buttons (Lock Screen and the expanded Dynamic Island): Heart the
// current item, Skip the next one, Dismiss an urgent announcement. "Show on map" is a `Link`
// (it opens the app), not an intent.
//
// These are `LiveActivityIntent`s compiled into both targets: the widget extension needs
// the types for `Button(intent:)`, and the system runs `perform()` in the APP's process
// (launching it in the background if needed), where AppDelegate has installed
// `LiveActivityActionRelay.handler` (LiveFollowController). In the extension the handler is
// never set, so nothing runs there.

import AppIntents
import Foundation

/// What a Live Activity button asks the app to do.
enum LiveActivityAction: Hashable, Sendable {
    case heart(eventId: Int, itemId: Int)
    case skip(eventId: Int, itemId: Int)
    case dismissUrgent(eventId: Int, notificationId: Int)
}

/// Hands Live Activity button taps to the app (set by AppDelegate; nil in the widget extension).
@MainActor
enum LiveActivityActionRelay {
    static var handler: (@MainActor (LiveActivityAction) async -> Void)?

    static func perform(_ action: LiveActivityAction) async {
        await handler?(action)
    }
}

/// "Like" (heart) on the item in progress (or the next one before anything has started).
struct HeartActivityItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add to My Schedule"
    static let description = IntentDescription("Adds the schedule item shown in your Live Activity to your schedule.")
    static let isDiscoverable = false

    @Parameter(title: "Event")
    var eventId: Int

    @Parameter(title: "Item")
    var itemId: Int

    init() {}

    init(eventId: Int, itemId: Int) {
        self.eventId = eventId
        self.itemId = itemId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActionRelay.perform(.heart(eventId: eventId, itemId: itemId))
        return .result()
    }
}

/// "Skip": the activity moves on to the item after the next one.
struct SkipActivityItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Item"
    static let description = IntentDescription("Skips the next item in your Live Activity.")
    static let isDiscoverable = false

    @Parameter(title: "Event")
    var eventId: Int

    @Parameter(title: "Item")
    var itemId: Int

    init() {}

    init(eventId: Int, itemId: Int) {
        self.eventId = eventId
        self.itemId = itemId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActionRelay.perform(.skip(eventId: eventId, itemId: itemId))
        return .result()
    }
}

/// Hides an urgent announcement from the Live Activity (and the in-app banner).
struct DismissUrgentActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Dismiss Announcement"
    static let description = IntentDescription("Hides the urgent announcement in your Live Activity.")
    static let isDiscoverable = false

    @Parameter(title: "Event")
    var eventId: Int

    @Parameter(title: "Notification")
    var notificationId: Int

    init() {}

    init(eventId: Int, notificationId: Int) {
        self.eventId = eventId
        self.notificationId = notificationId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActionRelay.perform(.dismissUrgent(eventId: eventId, notificationId: notificationId))
        return .result()
    }
}
