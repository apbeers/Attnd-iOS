// APIClient.swift
// Attnd
//
// Native URLSession API client for the Attnd API v1.
// Uses async/await throughout. No external dependencies.
//
// Authentication: every request includes
//   Authorization: Bearer <API_KEY>
// where API_KEY is read from the app's Info.plist at key "ATTND_API_KEY".

import Foundation

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case notFound
    case badRequest(String)
    case serverError(Int)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:         return "Invalid URL."
        case .unauthorized:       return "Invalid or missing API key."
        case .notFound:           return "Resource not found."
        case .badRequest(let m):  return "Bad request: \(m)"
        case .serverError(let c): return "Server error (\(c))."
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        case .networkError(let e):  return "Network error: \(e.localizedDescription)"
        }
    }
}

// MARK: - APIClient

final class APIClient {

    static let shared = APIClient()

    private let baseURL = "https://attnd.app/api/v1/events"
    private let session: URLSession
    private let apiKey: String

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        // Read key from Info.plist. Set ATTND_API_KEY in build settings (injected from .xcconfig / CI secret).
        self.apiKey = Bundle.main.object(forInfoDictionaryKey: "ATTND_API_KEY") as? String ?? ""
    }

    // MARK: - Core Request

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        guard let url = URL(string: path) else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }

        switch http.statusCode {
        case 200...299: break
        case 400:
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Bad request"
            throw APIError.badRequest(msg)
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default:  throw APIError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    // Convenience for POST with no return body (expects { "status": "ok" })
    private func post(_ path: String, body: [String: String]? = nil) async throws {
        let _: [String: String] = try await request(path, method: "POST", body: body)
    }

    // MARK: - Events

    /// GET /api/v1/events/nearby_events/<lat>/<lng>/
    func nearbyEvents(latitude: Double, longitude: Double) async throws -> APIList<NearbyEventResult> {
        let path = "\(baseURL)/nearby_events/\(latitude)/\(longitude)/"
        return try await request(path)
    }

    /// GET /api/v1/events/lookup/?q=<query>  — exact match, ignores public flag
    func lookupEvent(query: String) async throws -> Event {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = "\(baseURL)/lookup/?q=\(encoded)"
        return try await request(path)
    }

    /// GET /api/v1/events/event_by_code_or_name/?data=<query>  — fuzzy match, public only
    func searchEvent(query: String) async throws -> Event {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = "\(baseURL)/event_by_code_or_name/?data=\(encoded)"
        return try await request(path)
    }

    /// GET /api/v1/events/<id>/
    func event(id: Int) async throws -> Event {
        return try await request("\(baseURL)/\(id)/")
    }

    // MARK: - Locations

    /// GET /api/v1/events/<eventId>/locations/
    func locations(eventId: Int) async throws -> APIList<Location> {
        return try await request("\(baseURL)/\(eventId)/locations/")
    }

    /// GET /api/v1/events/<eventId>/locations/<id>/
    func location(eventId: Int, locationId: Int) async throws -> Location {
        return try await request("\(baseURL)/\(eventId)/locations/\(locationId)/")
    }

    // MARK: - Schedule

    /// GET /api/v1/events/<eventId>/schedule/
    func schedule(eventId: Int) async throws -> APIList<ScheduledItem> {
        return try await request("\(baseURL)/\(eventId)/schedule/")
    }

    /// GET /api/v1/events/<eventId>/schedule/<id>/
    func scheduledItem(eventId: Int, itemId: Int) async throws -> ScheduledItem {
        return try await request("\(baseURL)/\(eventId)/schedule/\(itemId)/")
    }

    // MARK: - Notifications

    /// GET /api/v1/events/<eventId>/notifications/
    func notifications(eventId: Int) async throws -> APIList<AppNotification> {
        return try await request("\(baseURL)/\(eventId)/notifications/")
    }

    /// GET /api/v1/events/<eventId>/notifications/<id>/
    func notification(eventId: Int, notificationId: Int) async throws -> AppNotification {
        return try await request("\(baseURL)/\(eventId)/notifications/\(notificationId)/")
    }

    // MARK: - Device Registration

    /// POST /api/v1/events/<eventId>/join/<deviceId>/
    func joinEvent(eventId: Int, deviceId: String) async throws {
        try await post("\(baseURL)/\(eventId)/join/\(deviceId)/", body: ["platform": "ios"])
    }

    /// POST /api/v1/events/<eventId>/leave/<deviceId>/
    func leaveEvent(eventId: Int, deviceId: String) async throws {
        try await post("\(baseURL)/\(eventId)/leave/\(deviceId)/")
    }

    // MARK: - Push Notification Subscription

    /// POST /api/v1/events/pushnotifications/subscribe/<deviceId>/
    func subscribePush(deviceId: String) async throws {
        try await post("\(baseURL)/pushnotifications/subscribe/\(deviceId)/")
    }

    /// POST /api/v1/events/pushnotifications/unsubscribe/<deviceId>/
    func unsubscribePush(deviceId: String) async throws {
        try await post("\(baseURL)/pushnotifications/unsubscribe/\(deviceId)/")
    }
}
