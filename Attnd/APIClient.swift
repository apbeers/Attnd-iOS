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

    /// A stable name for logs (`error.caught` fields; no server text).
    var logKind: String {
        switch self {
        case .invalidURL:            return "invalid_url"
        case .unauthorized:          return "unauthorized"
        case .notFound:              return "not_found"
        case .badRequest:            return "bad_request"
        case .serverError(let code): return "server_\(code)"
        case .decodingError:         return "decoding"
        case .networkError:          return "network"
        case .updateRequired:        return "update_required"
        }
    }
}

/// Outcome of a diagnostics upload (`POST diagnostics/logs/` or `reports/`, API-013).
enum DiagnosticsUploadResult: Sendable, Equatable {
    case accepted
    /// The server can't use it (400, 413, 422, …): drop it.
    case rejected(Int)
    /// 429 (or the endpoint isn't there yet): wait this many seconds.
    case retryAfter(TimeInterval)
    /// Offline or a server error: try again later.
    case failed(String)
}

extension Notification.Name {
    /// Posted when the server says this build's API version is retired (410 / 426).
    static let attndUpdateRequired = Notification.Name("com.arcu.attnd.updateRequired")
}

// MARK: - Server switch

/// TestFlight (and Xcode) installs can switch between the production and dev servers in Options
/// (owner, Nov 19, 2026: testing on the Release build that TestFlight installs after a release).
/// App Store installs always use the build's server. App Review installs look exactly like TestFlight
/// ones (a sandbox receipt), so a Release build still starts on production there: the build decides
/// the default, the switch only overrides it.
enum ServerSwitch {
    static let productionHost = "attnd.app"
    static let devHost = "dev.attnd.app"
    static let choiceKey = "pref.serverChoice"

    enum Choice: String, CaseIterable, Sendable {
        case production, dev
        var host: String { self == .production ? ServerSwitch.productionHost : ServerSwitch.devHost }
        var title: String { self == .production ? "Production" : "Dev" }
    }

    /// A TestFlight or Xcode install. `appStoreReceiptURL` ends in `sandboxReceipt` outside the App
    /// Store; it is read through KVC because the property is deprecated (iOS 18) and its replacement,
    /// `AppTransaction`, is async, while the host must be known before the first request.
    static let isSwitchable: Bool = {
        #if DEBUG
        return true
        #else
        return (Bundle.main.value(forKey: "appStoreReceiptURL") as? URL)?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    static var storedChoice: Choice? {
        UserDefaults.standard.string(forKey: choiceKey).flatMap(Choice.init(rawValue:))
    }

    /// Pure (unit-tested): the build's host unless the install is switchable and a choice was made.
    static func host(buildHost: String, switchable: Bool, choice: Choice?) -> String {
        guard switchable, let choice else { return buildHost }
        return choice.host
    }

    /// The domain of the join / shared-plan links this launch builds: dev.attnd.app on the dev server
    /// (the app and the clip open both as Universal Links), attnd.app otherwise.
    static var linkHost: String { APIClient.serverHost == devHost ? devHost : productionHost }

    /// The choice the current host corresponds to (what Options shows).
    static func current(host: String) -> Choice { host == productionHost ? .production : .dev }
}

// MARK: - APIClient

final class APIClient: Sendable {

    static let shared = APIClient()

    /// The build's own server, from the ATTND_SERVER build setting (Info.plist): Dev builds (develop)
    /// the dev server, Release builds (main) attnd.app.
    static let buildServerHost: String = {
        let host = (Bundle.main.object(forInfoDictionaryKey: "ATTND_SERVER") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty || host.hasPrefix("$(") ? ServerSwitch.productionHost : host
    }()

    /// The server this launch talks to: the build's, unless a test install chose another one in
    /// Options (`ServerSwitch`). Fixed for the process; a switch applies at the next launch.
    static let serverHost: String = ServerSwitch.host(
        buildHost: buildServerHost,
        switchable: ServerSwitch.isSwitchable,
        choice: ServerSwitch.storedChoice
    )

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

    /// API-019: sent as `app_clip` with join / device registration, so the server pushes to the App
    /// Clip's tokens on the clip's APNs topic. Decided at runtime from the bundle id (the clip's ends
    /// in `.clip`); the app and the clip share this code with no compile-time switch.
    let isAppClip: Bool

    static func isAppClip(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix(".clip") ?? false
    }

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
        self.isAppClip = Self.isAppClip(bundleIdentifier: Bundle.main.bundleIdentifier)
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
        let body = JoinRequest(deviceId: deviceId, pushToken: Self.nonEmpty(pushToken), appVersion: appVersion,
                               appClip: isAppClip)
        return try await post("events/\(eventId)/join/", body: body)
    }

    /// POST events/<id>/leave/
    @discardableResult
    func leaveEvent(eventId: Int, deviceId: String) async throws -> StatusResponse {
        try await post("events/\(eventId)/leave/", body: LeaveRequest(deviceId: deviceId))
    }

    /// POST devices/ — registration, push token, notification preference and (API-011) the
    /// Live Activity push token.
    @discardableResult
    func registerDevice(
        deviceId: String,
        pushToken: String?,
        subscribed: Bool?,
        liveActivityToken: LiveActivityTokenChange = .unchanged
    ) async throws -> StatusResponse {
        var token = liveActivityToken
        // An empty token means none: send null rather than "".
        if case .set(let hex) = token, Self.nonEmpty(hex) == nil { token = .clear }
        let body = DeviceRequest(
            deviceId: deviceId,
            pushToken: Self.nonEmpty(pushToken),
            appVersion: appVersion,
            subscribed: subscribed,
            liveActivityToken: token,
            appClip: isAppClip
        )
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
        let (data, http) = try await perform(req, template: "/api/app-status/", requestId: Self.newRequestId())
        let code = http.statusCode
        guard (200...299).contains(code) else { throw APIError.serverError(code) }
        return try decode(data)
    }

    // MARK: - Diagnostics (API-013)

    /// `POST diagnostics/logs/` (with the debug code as `X-Diag-Session`) or `diagnostics/reports/`
    /// (anonymous, none). The body is gzip-compressed JSON. Never logged as a request itself, so
    /// uploads don't feed the logs they upload; never throws.
    func postDiagnostics(_ path: String, gzippedJSON body: Data, diagSession: String?, isRetry: Bool = false) async -> DiagnosticsUploadResult {
        guard let url = URL(string: baseURL + path) else { return .rejected(0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let token = await bearerToken()
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        req.setValue(Self.newRequestId(), forHTTPHeaderField: "X-Request-Id")
        if let diagSession { req.setValue(diagSession, forHTTPHeaderField: "X-Diag-Session") }
        req.httpBody = body
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: req)
        } catch let error as URLError {
            return .failed(LogRedaction.urlErrorKind(error))
        } catch {
            return .failed("network")
        }
        guard let http = response as? HTTPURLResponse else { return .failed("no_response") }
        switch http.statusCode {
        case 200...299:
            return .accepted
        case 401 where !isRetry:
            if attest { await AttestationManager.shared.invalidateToken() }
            return await postDiagnostics(path, gzippedJSON: body, diagSession: diagSession, isRetry: true)
        case 429, 503:
            return .retryAfter(Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 60)
        case 404, 405, 410:
            // An older server without the endpoint: check again in an hour.
            return .retryAfter(3600)
        case 400..<500:
            return .rejected(http.statusCode)
        default:
            return .failed("http_\(http.statusCode)")
        }
    }

    /// `Retry-After`: seconds, or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = .now) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// A random id for `X-Request-Id`, also logged as `req_id`, so the server's line joins ours.
    static func newRequestId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
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
            AppLog.caught(error, .net, "decode_\(T.self)", level: .error, ["bytes": .int(data.count)])
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

        let requestId = Self.newRequestId()
        let template = LogRedaction.pathTemplate(path)
        let (data, http) = try await perform(req, template: template, requestId: requestId, attempt: isRetry ? 2 : 1)

        switch http.statusCode {
        case 200...299, 304:
            return (data, http)

        case 401:
            // Token expired or invalid — invalidate and retry once.
            guard !isRetry else { throw APIError.unauthorized }
            AppLog.info(.net, "net.request.retry", "\(method) \(template): 401, re-attesting", [
                "path": .string(template), "req_id": .string(requestId), "reason": "401",
            ])
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

    /// Runs one request with `X-Request-Id` (and `X-Diag-Session` while logs are uploaded), and
    /// logs it: `net.request.started` / `finished` (status, ms, bytes, 304, req_id) / `failed`.
    /// Errors and HTTP ≥ 400 are also counted as `perf_api_error` (API-014). `template` is the
    /// path with ids as `{id}` and no query.
    private func perform(_ request: URLRequest, template: String, requestId: String, attempt: Int = 1) async throws -> (Data, HTTPURLResponse) {
        var req = request
        req.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        if let diag = AppLog.diagSession { req.setValue(diag, forHTTPHeaderField: "X-Diag-Session") }
        let method = req.httpMethod ?? "GET"
        AppLog.trace(.net, "net.request.started", "\(method) \(template)", [
            "method": .string(method), "path": .string(template), "req_id": .string(requestId), "attempt": .int(attempt),
        ])
        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            let ms = (ContinuousClock.now - started).wholeMilliseconds
            let kind = (error as? URLError).map(LogRedaction.urlErrorKind) ?? "network"
            AppLog.log(kind == "cancelled" ? .debug : .warning, .net, "net.request.failed",
                       "\(method) \(template) failed (\(kind)) after \(ms) ms", [
                "method": .string(method), "path": .string(template), "req_id": .string(requestId),
                "ms": .int(ms), "error": .string(kind), "code": .int((error as NSError).code),
            ])
            if let urlError = error as? URLError, let detail = PerfBucket.apiError(urlError) {
                PerfMetrics.shared.record(.perfApiError, detail: detail)
            }
            throw APIError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        let status = http.statusCode
        let level: LogLevel = status >= 500 ? .warning : (status >= 400 ? .notice : .debug)
        AppLog.log(level, .net, "net.request.finished", "\(method) \(template) \(status) in \(ms) ms", {
            var fields: LogFields = [
                "method": .string(method), "path": .string(template), "status": .int(status), "ms": .int(ms),
                "bytes": .int(data.count), "req_id": .string(requestId), "attempt": .int(attempt),
                "cache": .string(status == 304 ? "304" : (req.value(forHTTPHeaderField: "If-None-Match") != nil ? "etag" : "none")),
            ]
            if let server = http.value(forHTTPHeaderField: "X-Request-Id"), server != requestId {
                fields["server_req_id"] = .string(server)
            }
            return fields
        }())
        if let detail = PerfBucket.apiError(status: status), !(status == 401 && attempt == 1) {
            PerfMetrics.shared.record(.perfApiError, detail: detail)
        }
        return (data, http)
    }
}
