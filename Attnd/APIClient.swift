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
//
// `shared` talks to the build's server (ATTND_SERVER). The live integration tests build their
// own client with `init(serverHost:apiKey:apiVersion:attest:)` so they can point it at another
// server and key without a rebuild (AttndTests/APIClientIntegrationTests.swift).

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
    /// 410 / 426: this build's API version is retired. The app shows the update screen.
    case updateRequired

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid URL."
        case .unauthorized:         return "Attnd couldn't verify this device with the server. Try again in a moment."
        case .notFound:             return "Not found."
        case .badRequest(let m):    return "Bad request: \(m)"
        case .serverError(let c):   return "Server error (\(c))."
        case .decodingError(let m): return "Unexpected response from the server: \(m)"
        case .networkError(let m):  return "Network error: \(m)"
        case .updateRequired:       return "This version of Attnd is no longer supported. Please update."
        }
    }
}

extension Notification.Name {
    /// Posted when the server says this build's API version is retired (410 / 426).
    static let attndUpdateRequired = Notification.Name("com.arcu.attnd.updateRequired")
}

// MARK: - APIClient

final class APIClient: Sendable {

    static let shared = APIClient()

    /// Host of the Attnd server, from the ATTND_SERVER build setting (Info.plist).
    /// Builds from the develop branch point at the dev server; everything else uses attnd.app.
    static let serverHost: String = {
        let host = (Bundle.main.object(forInfoDictionaryKey: "ATTND_SERVER") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty || host.hasPrefix("$(") ? "attnd.app" : host
    }()

    /// The API version this build speaks.
    static let apiVersion = 2

    /// Host, API version (the `/api/vN/` path, also sent to app-status) and base URL of this
    /// client (`shared`: the build's server and `apiVersion`).
    let host: String
    let pathVersion: Int
    let baseURL: String

    /// Result of a conditional bundle fetch.
    enum BundleResult: Sendable {
        /// `data` is the raw response body, saved as the offline copy (`EventStore`).
        case updated(EventBundle, etag: String?, data: Data)
        case notModified
    }

    private let session: URLSession

    /// Fallback static key for simulators and CI; read from Info.plist.
    private let staticApiKey: String

    /// Whether to use App Attest (on devices that support it) before the static key.
    private let attest: Bool

    /// Sent with join / device registration.
    let appVersion: String?

    private convenience init() {
        self.init(
            serverHost: Self.serverHost,
            apiKey: Bundle.main.object(forInfoDictionaryKey: "ATTND_API_KEY") as? String ?? "",
            apiVersion: Self.apiVersion,
            attest: true
        )
    }

    /// A client for any server. Used by the live integration tests; the app uses `shared`.
    /// An empty `apiKey` (with `attest: false`) sends no Authorization header at all.
    init(serverHost: String, apiKey: String, apiVersion: Int = APIClient.apiVersion, attest: Bool = false) {
        self.host = serverHost
        self.pathVersion = apiVersion
        self.baseURL = "https://\(serverHost)/api/v\(apiVersion)/"
        self.attest = attest
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // We do our own ETag handling for the bundle; keep URLCache out of the way.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.session = URLSession(configuration: config)
        self.staticApiKey = apiKey.hasPrefix("$(") ? "" : apiKey
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
        return .updated(bundle, etag: http.value(forHTTPHeaderField: "ETag"), data: data)
    }

    // MARK: - Devices

    /// POST events/<id>/join/
    @discardableResult
    func joinEvent(eventId: Int, deviceId: String, pushToken: String?) async throws -> StatusResponse {
        let body = JoinRequest(deviceId: deviceId, pushToken: Self.nonEmpty(pushToken), appVersion: appVersion)
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
        let body = DeviceRequest(deviceId: deviceId, pushToken: Self.nonEmpty(pushToken), appVersion: appVersion, subscribed: subscribed)
        return try await post("devices/", body: body)
    }

    /// API-007: `"push_token": ""` clears the server's stored token, so a missing token is
    /// omitted from the JSON (nil), never sent as an empty string.
    static func nonEmpty(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Usage (API-005)

    /// POST events/<id>/usage/ — anonymous, aggregated counts. Never includes a device ID.
    /// The response (`{"status":"ok","accepted":n}`) is ignored.
    func sendUsage(eventId: Int, entries: [UsageEntry]) async throws {
        guard !entries.isEmpty else { return }
        _ = try await post("events/\(eventId)/usage/", body: UsageRequest(events: entries))
    }

    // MARK: - App status

    /// GET /api/app-status/ (API-003). Unversioned and unauthenticated, so even a build whose
    /// API version was retired, or whose attestation fails, can learn that it must update.
    func appStatus() async throws -> AppStatus {
        var components = URLComponents(string: "https://\(host)/api/app-status/")
        components?.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: appVersion ?? ""),
            URLQueryItem(name: "api", value: String(pathVersion)),
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw APIError.serverError(code) }
        return try decode(data)
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
        if attest, let jwt = try? await AttestationManager.shared.token() {
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
    /// Internal (not private) so the integration tests can check raw responses through the same path.
    func send(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        isRetry: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = await bearerToken()
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            if attest { await AttestationManager.shared.invalidateToken() }
            return try await send(path, method: method, body: body, headers: headers, isRetry: true)

        case 400:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Bad request"
            throw APIError.badRequest(message)

        case 404:
            throw APIError.notFound

        case 410, 426:
            NotificationCenter.default.post(name: .attndUpdateRequired, object: nil)
            throw APIError.updateRequired

        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}
