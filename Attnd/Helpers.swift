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
    let paid: Bool
    let flyerUrl: String?
    let address: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, latitude, longitude, paid, address
        case eventCode  = "event_code"
        case startTime  = "start_time"
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

// MARK: - Location

struct Location: Decodable, Identifiable {
    let id: Int
    let name: String
    let snippet: String
    let description: String
    let website: String?
    let imageUrl: String?
    let latitude: Double
    let longitude: Double
    let address: String

    enum CodingKeys: String, CodingKey {
        case id, name, snippet, description, website, latitude, longitude, address
        case imageUrl = "image_url"
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
