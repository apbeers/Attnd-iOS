// APIClient.swift
// Attnd
//
// URLSession client for the Attnd API v2 (see API_V2.md). async/await, no dependencies.
//
// Authentication priority:
//   1. Attestation JWT from AttestationManager (production devices)
//   2. Static ATTND_API_KEY from Info.plist (simulator / CI / dev builds; set via
//      Config/Secrets.xcconfig, never committed)
//
// On 401, the stored JWT is cleared and the request is retried once after
// re-attesting, so token rotation is transparent to callers.
//
// The client is stateless (and therefore Sendable): callers own any ETag they
// want to send back.

import Foundation

// MARK: - API Errors

enum APIError: LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case notFound
    case badRequest(String)
    case serverError(Int)
    case decodingError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid URL."
        case .unauthorized:         return "Authorization failed."
        case .notFound:             return "Not found."
        case .badRequest(let m):    return "Bad request: \(m)"
        case .serverError(let c):   return "Server error (\(c))."
        case .decodingError(let m): return "Unexpected response from the server: \(m)"
        case .networkError(let m):  return "Network error: \(m)"
        }
    }
}

// MARK: - APIClient

final class APIClient: Sendable {

    static let shared = APIClient()

    static let baseURL = "https://attnd.app/api/v2/"

    /// Result of a conditional bundle fetch.
    enum BundleResult: Sendable {
        case updated(EventBundle, etag: String?)
        case notModified
    }

    private let session: URLSession

    /// Fallback static key for simulators and CI; read from Info.plist.
    private let staticApiKey: String

    /// Sent with join / device registration.
    let appVersion: String?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // We do our own ETag handling for the bundle; keep URLCache out of the way.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
        self.staticApiKey = Bundle.main.object(forInfoDictionaryKey: "ATTND_API_KEY") as? String ?? ""
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Events

    /// GET events/nearby/?lat=&lng=
    func nearbyEvents(latitude: Double, longitude: Double) async throws -> [NearbyEventResult] {
        let path = "events/nearby/?lat=\(latitude)&lng=\(longitude)"
        let response: NearbyEventsResponse = try decode(try await send(path).0)
        return response.results
    }

    /// GET events/lookup/?q=<code or exact name> — includes unlisted events (QR codes, deep links).
    func lookupEvent(query: String) async throws -> Event {
        let path = "events/lookup/?q=\(Self.encodeQueryValue(query))"
        let response: LookupResponse = try decode(try await send(path).0)
        return response.event
    }

    /// GET events/<id>/bundle/ with If-None-Match. Returns `.notModified` on 304.
    func bundle(eventId: Int, etag: String?, deviceId: String?) async throws -> BundleResult {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        if let deviceId { headers["X-Device-Id"] = deviceId }
        let (data, http) = try await send("events/\(eventId)/bundle/", headers: headers)
        if http.statusCode == 304 { return .notModified }
        let bundle: EventBundle = try decode(data)
        return .updated(bundle, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: - Devices

    /// POST events/<id>/join/
    @discardableResult
    func joinEvent(eventId: Int, deviceId: String, pushToken: String?) async throws -> StatusResponse {
        let body = JoinRequest(deviceId: deviceId, pushToken: pushToken, appVersion: appVersion)
        return try await post("events/\(eventId)/join/", body: body)
    }

    /// POST events/<id>/leave/
    @discardableResult
    func leaveEvent(eventId: Int, deviceId: String) async throws -> StatusResponse {
        try await post("events/\(eventId)/leave/", body: LeaveRequest(deviceId: deviceId))
    }

    /// POST devices/ — registration, push token and notification preference.
    @discardableResult
    func registerDevice(deviceId: String, pushToken: String?, subscribed: Bool?) async throws -> StatusResponse {
        let body = DeviceRequest(deviceId: deviceId, pushToken: pushToken, appVersion: appVersion, subscribed: subscribed)
        return try await post("devices/", body: body)
    }

    // MARK: - Query encoding

    /// Percent-encodes a query value, including `&`, `=` and `+`, so names like
    /// "Austin Tech & Innovation Summit" survive the round trip.
    static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Core

    /// Resolves the best available bearer token: attestation JWT, else the static key.
    private func bearerToken() async -> String {
        if let jwt = try? await AttestationManager.shared.token() {
            return jwt
        }
        return staticApiKey
    }

    private func post<Body: Encodable & Sendable>(_ path: String, body: Body) async throws -> StatusResponse {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw APIError.badRequest("Could not encode request")
        }
        let (responseData, _) = try await send(path, method: "POST", body: data)
        // Write endpoints only promise {"status": "ok"}; tolerate empty or odd bodies.
        return (try? JSONDecoder().decode(StatusResponse.self, from: responseData)) ?? StatusResponse()
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    /// Sends a request and maps HTTP status codes to `APIError`. 2xx and 304 are returned.
    private func send(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        isRetry: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: Self.baseURL + path) else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(await bearerToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }

        switch http.statusCode {
        case 200...299, 304:
            return (data, http)

        case 401:
            // Token expired or invalid — invalidate and retry once.
            guard !isRetry else { throw APIError.unauthorized }
            await AttestationManager.shared.invalidateToken()
            return try await send(path, method: method, body: body, headers: headers, isRetry: true)

        case 400:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Bad request"
            throw APIError.badRequest(message)

        case 404:
            throw APIError.notFound

        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}
