// Helpers.swift
// Attnd
//
// Data models matching the Attnd API v1 response shapes.
// All snake_case JSON keys are mapped to camelCase via CodingKeys.

import Foundation

// MARK: - API List Envelope

/// Generic paginated response wrapper used by all list endpoints.
struct APIList<T: Decodable>: Decodable {
    let count: Int
    let results: [T]
}

// MARK: - Event

struct Event: Decodable, Identifiable {
    let id: Int
    let name: String
    let eventCode: String
    let description: String
    let latitude: Double
    let longitude: Double
    let startTime: String
    let createdAt: String
    let paid: Bool
    let flyerUrl: String?
    let address: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, latitude, longitude, paid, address
        case eventCode  = "event_code"
        case startTime  = "start_time"
        case createdAt  = "created_at"
        case flyerUrl   = "flyer_url"
    }
}

// MARK: - Nearby Event Result

/// Wrapper returned by GET /api/v1/events/nearby_events/<lat>/<lng>/
struct NearbyEventResult: Decodable, Identifiable {
    // Stable identity from the wrapped event
    var id: Int { event.id }
    let event: Event
    let distanceMiles: Double
    let startsInHours: Double

    enum CodingKeys: String, CodingKey {
        case event
        case distanceMiles  = "distance_miles"
        case startsInHours  = "starts_in_hours"
    }
}

// MARK: - Scheduled Item

struct ScheduledItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let description: String
    let startTime: String
    let locationId: Int
    let locationName: String

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case startTime    = "start_time"
        case locationId   = "location_id"
        case locationName = "location_name"
    }
}

// MARK: - Location

struct Location: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let snippet: String
    let description: String
    let website: String?
    let imageUrl: String?
    let latitude: Double
    let longitude: Double
    let address: String
    let scheduledItems: [ScheduledItem]

    enum CodingKeys: String, CodingKey {
        case id, name, snippet, description, website, latitude, longitude, address
        case imageUrl      = "image_url"
        case scheduledItems = "scheduled_items"
    }
}

// MARK: - Scheduled Item Helpers

extension ScheduledItem {
    /// Returns a "Starts in Xh Ym" string if the item hasn't started yet, nil otherwise.
    /// Pass `now` from a TimelineView or timer so the label updates live.
    func startsInText(relativeTo now: Date = Date()) -> String? {
        let p1 = ISO8601DateFormatter()
        p1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let p2 = ISO8601DateFormatter()
        p2.formatOptions = [.withInternetDateTime]
        guard let date = p1.date(from: startTime) ?? p2.date(from: startTime) else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 1 { return "Starting now" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "Starts in \(minutes)m" }
        if minutes == 0 { return "Starts in \(hours)h" }
        return "Starts in \(hours)h \(minutes)m"
    }
}

// MARK: - App Notification
// Named AppNotification to avoid collision with Foundation.Notification.

struct AppNotification: Decodable, Identifiable {
    let id: Int
    let title: String
    let body: String
    let sendTime: String
    let sent: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, body, sent
        case sendTime = "send_time"
    }
}
