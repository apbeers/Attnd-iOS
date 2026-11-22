// AppLog.swift
// Attnd (app + App Clip)
//
// Structured logging (API-013, shared logging spec §1–3): one small facade for the whole app.
//
//     AppLog.debug(.net, "net.request.finished", "GET events/{id}/bundle/ 304 in 182 ms", ["status": 304, "ms": .int(ms)])
//
//   - The level is checked first: the message and fields are autoclosures, built only when the
//     level is captured. Writing (JSON encoding, the file) happens off the caller's thread on one
//     serial utility queue.
//   - Every captured record goes to `os.Logger` (subsystem com.arcu.Attnd, category = `cat`;
//     the event name is public, the text only in Debug/Dev builds) and to the ring buffer on disk
//     (`LogStore`: JSON lines, ~2 MB, newest kept), which feeds the log viewer and the uploader.
//   - Record format (identical on Android and the server, `v` = 1): `LogRecord`.
//   - Event names are dotted and stable; every one is listed in attnd-web `LOG_EVENTS.md`.
//   - Redaction (`LogRedaction`, unit-tested): never search / Ask / plan text in production
//     (lengths only), never tokens, keys, push tokens, emails or the device id / support code;
//     URLs as path templates (`events/{id}/bundle/`, no query); coordinates rounded to 0.01°.
//     Messages and string fields are scrubbed again when a record is made.
//
// Levels (`LogPolicy`):
//   - Debug and Dev builds: `debug`, kept on disk. Dev builds (the `Dev` configuration, develop →
//     TestFlight) also upload continuously under one persistent debug code per install.
//   - Production (Release): errors only (`error` and `fault`) are captured and kept on disk; there
//     is no in-memory pre-roll and nothing is uploaded.
//   - Debug mode (production, user-started from Options → About & support, 10 minutes): `debug`,
//     kept and uploaded under a random code `D-XXXXX`, from the moment it is turned on (nothing
//     from before); it turns itself off at the stored expiry, also across restarts. Never linked
//     to the device id.
//   - Screenshot mode: logs locally only, never uploads.

import Foundation
import Network
import os

// MARK: - Levels, categories, values

enum LogLevel: Int, Sendable, Hashable, Comparable, CaseIterable, Codable {
    case trace = 0, debug, info, notice, warning, error, fault

    var name: String {
        switch self {
        case .trace:   return "trace"
        case .debug:   return "debug"
        case .info:    return "info"
        case .notice:  return "notice"
        case .warning: return "warning"
        case .error:   return "error"
        case .fault:   return "fault"
        }
    }

    init?(name: String) {
        guard let level = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = level
    }

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    /// The wire form is the name ("debug"); a number 0–6 is accepted when reading.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self), let level = LogLevel(name: name) {
            self = level
        } else if let number = try? container.decode(Int.self), let level = LogLevel(rawValue: number) {
            self = level
        } else {
            self = .info
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }

    var osLogType: OSLogType {
        switch self {
        case .trace, .debug:     return .debug
        case .info:              return .info
        case .notice, .warning:  return .default
        case .error:             return .error
        case .fault:             return .fault
        }
    }
}

enum LogCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case net, push, background, live, location, map, planner, assistant, search, storage, ui, perf, auth, lifecycle, logging
}

/// One field value. Literals work directly (`["status": 304, "ok": true]`); variables use the cases.
enum LogValue: Sendable, Hashable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .string((try? container.decode(String.self)) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value):    try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value):   try container.encode(value)
        }
    }

    var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value):    return String(value)
        case .double(let value): return String(value)
        case .bool(let value):   return value ? "true" : "false"
        }
    }
}

typealias LogFields = [String: LogValue]

// MARK: - Record (spec §1, v = 1)

/// One line of the ring buffer and of an upload:
/// `{"v":1,"ts":"2026-11-15T19:04:12.381Z","mono_ms":523101,"seq":4182,"level":"debug","cat":"net",
///   "event":"net.request.finished","msg":"…","f":{…},"app":"2.0.131","build":"131","os":"iOS 27.2",
///   "model":"iPhone18,1","state":"fg","net":"wifi","event_id":5,"diag":"D-7K3QX"}`
struct LogRecord: Codable, Sendable, Hashable, Identifiable {
    var v = 1
    /// UTC, milliseconds.
    var ts: String
    /// Monotonic milliseconds since launch (`ContinuousClock`; orders lines when the wall clock jumps).
    var monoMs: Int64
    /// Increasing per install (continues across launches).
    var seq: Int
    var level: LogLevel
    var cat: LogCategory
    var event: String
    var msg: String
    var f: LogFields?
    var app: String
    var build: String
    var os: String
    var model: String
    /// "fg" or "bg".
    var state: String
    /// "wifi", "cell", "none" or "other".
    var net: String
    var eventId: Int?
    /// The debug code while logs are uploaded (Dev builds, debug mode).
    var diag: String?

    var id: Int { seq }

    enum CodingKeys: String, CodingKey {
        case v, ts, seq, level, cat, event, msg, f, app, build, os, model, state, net, diag
        case monoMs = "mono_ms"
        case eventId = "event_id"
    }

    init(
        ts: String, monoMs: Int64, seq: Int, level: LogLevel, cat: LogCategory, event: String, msg: String,
        f: LogFields?, app: String, build: String, os: String, model: String, state: String, net: String,
        eventId: Int?, diag: String?
    ) {
        self.ts = ts
        self.monoMs = monoMs
        self.seq = seq
        self.level = level
        self.cat = cat
        self.event = event
        self.msg = msg
        self.f = f
        self.app = app
        self.build = build
        self.os = os
        self.model = model
        self.state = state
        self.net = net
        self.eventId = eventId
        self.diag = diag
    }

    /// Lenient: older or foreign lines with missing keys still read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decode(Int.self, forKey: .v)) ?? 1
        ts = (try? c.decode(String.self, forKey: .ts)) ?? ""
        monoMs = (try? c.decode(Int64.self, forKey: .monoMs)) ?? 0
        seq = (try? c.decode(Int.self, forKey: .seq)) ?? 0
        level = (try? c.decode(LogLevel.self, forKey: .level)) ?? .info
        cat = (try? c.decode(LogCategory.self, forKey: .cat)) ?? .lifecycle
        event = (try? c.decode(String.self, forKey: .event)) ?? ""
        msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
        f = try? c.decode(LogFields.self, forKey: .f)
        app = (try? c.decode(String.self, forKey: .app)) ?? ""
        build = (try? c.decode(String.self, forKey: .build)) ?? ""
        os = (try? c.decode(String.self, forKey: .os)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        net = (try? c.decode(String.self, forKey: .net)) ?? ""
        eventId = try? c.decode(Int.self, forKey: .eventId)
        diag = try? c.decode(String.self, forKey: .diag)
    }

    var date: Date? { ISODate.parse(ts) }

    /// "status=304 ms=182" (sorted), for the viewer and the system log.
    var compactFields: String {
        guard let f, !f.isEmpty else { return "" }
        return f.keys.sorted().map { "\($0)=\(f[$0]!.description)" }.joined(separator: " ")
    }
}

// MARK: - Policy

enum LogPolicy {
    #if DEV
    /// The `Dev` build configuration (develop → TestFlight): debug level, uploads always.
    static let isDevBuild = true
    #else
    static let isDevBuild = false
    #endif

    #if DEBUG || DEV
    /// Debug or Dev builds: debug level by default, the "Logs" viewer, user text in logs.
    static let isDeveloperBuild = true
    #else
    static let isDeveloperBuild = false
    #endif

    /// Search, Ask and plan text may be logged (Debug and Dev builds only; production logs lengths).
    static var logsUserText: Bool { isDeveloperBuild }

    /// The level captured (and kept on disk) without debug mode: `debug` in Debug and Dev builds,
    /// errors only (`error`, `fault`) in production. Everything captured is kept on disk.
    static func captureLevel(developerBuild: Bool) -> LogLevel {
        developerBuild ? .debug : .error
    }

    static var baseLevel: LogLevel { captureLevel(developerBuild: isDeveloperBuild) }

    /// Debug mode lasts this long. It captures from the moment it is turned on (no pre-roll).
    static let debugModeDuration: TimeInterval = 10 * 60
}

/// What every record says about the build and device (no identifiers).
struct LogEnvironment: Sendable, Hashable {
    var app: String
    var build: String
    var os: String
    var model: String
    var isAppClip: Bool

    static let current: LogEnvironment = {
        let bundle = Bundle.main
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "iOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { os += ".\(version.patchVersion)" }
        return LogEnvironment(
            app: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            os: os,
            model: SupportInfo.deviceModelIdentifier(),
            isAppClip: bundle.bundleIdentifier?.hasSuffix(".clip") ?? false
        )
    }()
}

// MARK: - Redaction (unit-tested: AttndTests/LoggingTests.swift)

enum LogRedaction {

    /// A URL or API path as a template: no scheme/host, no query or fragment, ids → `{id}`.
    /// "https://attnd.app/api/v2/events/5/bundle/?x=1" → "/api/v2/events/{id}/bundle/";
    /// "events/nearby/?lat=30.2&lng=-97.7" → "events/nearby/".
    static func pathTemplate(_ raw: String) -> String {
        var path = Substring(raw)
        if let scheme = path.range(of: "://") {
            let rest = path[scheme.upperBound...]
            path = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = path[..<cut]
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { isIdentifier($0) ? "{id}" : String($0) }
            .joined(separator: "/")
    }

    /// A path segment that names one thing: digits, a UUID, a long hex string, an email or a
    /// `D-XXXXX` debug code. API names ("v2", "events", "bundle") stay.
    static func isIdentifier(_ segment: Substring) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        if segment.contains("@") { return true }
        if UUID(uuidString: String(segment)) != nil { return true }
        if segment.count >= 16, segment.allSatisfy({ $0.isHexDigit }) { return true }
        return false
    }

    /// Fields for text the user typed (search, Ask, plan requests): its length, and the text
    /// itself only when `includeText` (Debug and Dev builds).
    static func textFields(_ text: String, key: String = "query", includeText: Bool = LogPolicy.logsUserText) -> LogFields {
        var fields: LogFields = ["\(key)_len": .int(text.count)]
        if includeText { fields[key] = .string(text) }
        return fields
    }

    /// A latitude or longitude rounded to 0.01° (about 1 km).
    static func coordinate(_ degrees: Double) -> Double {
        (degrees * 100).rounded() / 100
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Constant patterns (LoggingTests exercises every one).
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // NSRegularExpression is immutable and thread-safe once made.
    private static let rules: [(NSRegularExpression, String)] = [
        // URL queries can carry anything (q=, tokens): keep scheme, host and path.
        (regex(#"(https?://[^\s?#]+)[?#][^\s]*"#), "$1"),
        (regex(#"\bbearer\s+[A-Za-z0-9._~+/=-]+"#), "Bearer <redacted>"),
        // JWTs (attestation tokens).
        (regex(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*"#), "<token>"),
        (regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#), "<email>"),
        // Device ids are UUIDs.
        (regex(#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#), "<uuid>"),
        // APNs / Live Activity push tokens and other long hex secrets.
        (regex(#"\b[0-9a-f]{32,}\b"#), "<hex>"),
        // API keys handed around as "key=…" / "token: …".
        (regex(#"\b(api[_-]?key|token|secret|password)(["']?\s*[:=]\s*["']?)[^\s"',&]+"#), "$1$2<redacted>"),
    ]

    /// Removes secrets and identifiers from free text: URL queries, bearer tokens, JWTs,
    /// emails, UUIDs (device ids), long hex strings (push tokens) and `key=value` secrets.
    static func scrub(_ text: String) -> String {
        guard text.count >= 6 else { return text }
        var result = text
        for (expression, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            guard expression.firstMatch(in: result, range: range) != nil else { continue }
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// `error.caught` fields: the error's domain, code and type (and the API error's kind).
    static func errorFields(_ error: Error) -> LogFields {
        let ns = error as NSError
        var fields: LogFields = [
            "domain": .string(ns.domain),
            "code": .int(ns.code),
            "type": .string(String(describing: type(of: error))),
        ]
        if let api = error as? APIError { fields["kind"] = .string(api.logKind) }
        if let url = error as? URLError { fields["url_error"] = .string(LogRedaction.urlErrorKind(url)) }
        return fields
    }

    /// `net.request.failed`'s `error` for a URLError: "timeout", "offline", "dns", "tls",
    /// "cancelled" or "other" (LOG_EVENTS.md).
    static func urlErrorKind(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "timeout"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotConnectToHost, .callIsActive:
            return "offline"
        case .cannotFindHost, .dnsLookupFailed:
            return "dns"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return "tls"
        case .cancelled:
            return "cancelled"
        default:
            return "other"
        }
    }
}

// MARK: - Facade

enum AppLog {
    static let subsystem = "com.arcu.Attnd"

    /// At launch (AttndApp / AttndAppClipApp init): network state, Dev-build uploads, a debug
    /// mode that is still running. Safe to call more than once.
    static func start() { LogCore.shared.start() }

    /// Whether `level` is captured right now. `log` checks it first.
    static func isEnabled(_ level: LogLevel) -> Bool { LogCore.shared.isEnabled(level) }

    static func log(
        _ level: LogLevel, _ cat: LogCategory, _ event: String,
        _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]
    ) {
        let core = LogCore.shared
        guard core.isEnabled(level) else { return }
        core.emit(level, cat, event, msg(), fields())
    }

    static func trace(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.trace, cat, event, msg(), fields())
    }

    static func debug(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.debug, cat, event, msg(), fields())
    }

    static func info(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.info, cat, event, msg(), fields())
    }

    static func notice(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.notice, cat, event, msg(), fields())
    }

    static func warning(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.warning, cat, event, msg(), fields())
    }

    static func error(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.error, cat, event, msg(), fields())
    }

    static func fault(_ cat: LogCategory, _ event: String, _ msg: @autoclosure () -> String = "", _ fields: @autoclosure () -> LogFields = [:]) {
        log(.fault, cat, event, msg(), fields())
    }

    /// Every caught error: `error.caught` with its domain, code and type, and where it happened.
    static func caught(
        _ error: Error, _ cat: LogCategory, _ context: String,
        level: LogLevel = .warning, _ fields: @autoclosure () -> LogFields = [:]
    ) {
        log(level, cat, "error.caught", "\(context): \(error.localizedDescription)",
            LogRedaction.errorFields(error).merging(fields()) { _, new in new }.merging(["where": .string(context)]) { _, new in new })
    }

    /// The debug code sent as `X-Diag-Session` while logs are uploaded (nil otherwise).
    static var diagSession: String? { LogCore.shared.uploadSession?.code }

    /// The scene went to the foreground or background (records' `state`).
    static func setForeground(_ foreground: Bool) { LogCore.shared.setForeground(foreground) }

    /// The joined event (records' `event_id`).
    static func setEventId(_ eventId: Int?) { LogCore.shared.setEventId(eventId) }

    /// Uploads what is pending now (the app is going to the background).
    static func flush() {
        guard LogCore.shared.uploadSession != nil else { return }
        Task.detached(priority: .utility) { await LogUploader.shared.uploadPending() }
    }
}

// MARK: - Core

/// Upload state: the debug code and why logs are uploaded.
struct LogUploadSession: Sendable, Hashable {
    var code: String
    /// "dev" (Dev builds, always) or "debug_mode" (production, user-started, 10 minutes).
    var reason: String
}

/// What Options shows about debug logging.
struct DebugModeStatus: Sendable, Hashable {
    var code: String
    /// When debug mode turns itself off; nil in Dev builds (always on).
    var until: Date?
}

/// The facade's shared state: levels, record context, the upload session. Thread-safe (one lock);
/// file work runs on `queue`, which owns `store`.
final class LogCore: @unchecked Sendable {
    static let shared = LogCore()

    private struct State {
        var seq: Int
        /// Captured (and kept on disk) at this level and above.
        var level: LogLevel
        var foreground = true
        var net = "none"
        var eventId: Int?
        var session: LogUploadSession?
        var debugUntil: Date?
        var started = false
    }

    private enum Keys {
        static let devCode = "log.devCode"
        static let debugCode = "log.debugMode.code"
        static let debugUntil = "log.debugMode.until"
        static let debugSince = "log.debugMode.since"
        static let cursor = "log.upload.cursor"
    }

    let environment = LogEnvironment.current
    /// Serial queue owning `store` (encoding, the ring buffer files, pending uploads).
    let queue = DispatchQueue(label: "com.arcu.Attnd.log", qos: .utility)
    /// Only touched on `queue`.
    let store: LogStore

    private let lock = NSLock()
    private var state: State
    private let loggers: [LogCategory: Logger]
    private let pathMonitor = NWPathMonitor()
    private let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// `mono_ms` counts from here (the first log call of the process, at launch).
    private let launchInstant = ContinuousClock.now

    init(directory: URL? = LogStore.defaultDirectory) {
        let store = LogStore(directory: directory)
        self.store = store
        state = State(seq: store.lastSequence(), level: LogPolicy.baseLevel)
        var loggers: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: AppLog.subsystem, category: category.rawValue)
        }
        self.loggers = loggers
        // A cursor ahead of the files (they were deleted) would skip everything new.
        if Self.cursor > state.seq { Self.cursor = state.seq }
    }

    // MARK: Capture

    func isEnabled(_ level: LogLevel) -> Bool {
        lock.withLock { level >= state.level }
    }

    func emit(_ level: LogLevel, _ cat: LogCategory, _ event: String, _ msg: String, _ fields: LogFields) {
        let now = Date()
        let mono = Int64((ContinuousClock.now - launchInstant).wholeMilliseconds)
        let text = LogRedaction.scrub(msg)
        var clean: LogFields?
        if !fields.isEmpty {
            clean = fields.mapValues { value in
                if case .string(let string) = value { return .string(LogRedaction.scrub(string)) }
                return value
            }
        }
        let env = environment
        let stamp = timestamp.format(now)
        let record = lock.withLock { () -> LogRecord in
            state.seq += 1
            return LogRecord(
                ts: stamp, monoMs: mono, seq: state.seq, level: level, cat: cat, event: event, msg: text, f: clean,
                app: env.app, build: env.build, os: env.os, model: env.model,
                state: state.foreground ? "fg" : "bg", net: state.net, eventId: state.eventId, diag: state.session?.code
            )
        }
        systemLog(record)
        queue.async { self.store.append(record) }
    }

    private func systemLog(_ record: LogRecord) {
        guard let logger = loggers[record.cat] else { return }
        let fields = record.compactFields
        let text = fields.isEmpty ? record.msg : "\(record.msg) \(fields)"
        // The text is already scrubbed; it is still kept private in production builds.
        if LogPolicy.isDeveloperBuild {
            logger.log(level: record.level.osLogType, "\(record.event, privacy: .public) \(text, privacy: .public)")
        } else {
            logger.log(level: record.level.osLogType, "\(record.event, privacy: .public) \(text, privacy: .private)")
        }
    }

    // MARK: Context

    func setForeground(_ foreground: Bool) {
        lock.withLock { state.foreground = foreground }
    }

    func setEventId(_ eventId: Int?) {
        lock.withLock { state.eventId = eventId }
    }

    private func setNet(_ net: String, constrained: Bool, expensive: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard state.net != net else { return false }
            state.net = net
            return true
        }
        if changed {
            AppLog.info(.net, "net.reachability", "Network: \(net)", [
                "net": .string(net), "constrained": .bool(constrained), "expensive": .bool(expensive),
            ])
        }
    }

    // MARK: Sessions (Dev builds, debug mode)

    var uploadSession: LogUploadSession? { lock.withLock { state.session } }

    var debugStatus: DebugModeStatus? {
        lock.withLock { state.session.map { DebugModeStatus(code: $0.code, until: state.debugUntil) } }
    }

    func start() {
        let first = lock.withLock { () -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard first else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let net: String
            if path.status != .satisfied {
                net = "none"
            } else if path.usesInterfaceType(.wifi) {
                net = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                net = "cell"
            } else {
                net = "other"
            }
            self?.setNet(net, constrained: path.isConstrained, expensive: path.isExpensive)
        }
        pathMonitor.start(queue: queue)

        guard !ScreenshotMode.isActive else { return }
        let defaults = UserDefaults.standard
        if LogPolicy.isDevBuild {
            let code: String
            if let saved = defaults.string(forKey: Keys.devCode), DebugCode.isValid(saved) {
                code = saved
            } else {
                code = DebugCode.generate()
                defaults.set(code, forKey: Keys.devCode)
            }
            activate(LogUploadSession(code: code, reason: "dev"), until: nil, since: nil)
            return
        }
        let until = defaults.object(forKey: Keys.debugUntil) as? Double
        if let until, let code = defaults.string(forKey: Keys.debugCode), Date(timeIntervalSince1970: until) > .now {
            let since = (defaults.object(forKey: Keys.debugSince) as? Double).map(Date.init(timeIntervalSince1970:))
            activate(LogUploadSession(code: code, reason: "debug_mode"), until: Date(timeIntervalSince1970: until), since: since)
            AppLog.notice(.logging, "logging.debug_mode", "Debug mode still on after a restart", [
                "on": true, "reason": "restart", "minutes": .int(Int((until - Date.now.timeIntervalSince1970) / 60)),
            ])
        } else if until != nil {
            clearDebugDefaults()
        }
    }

    /// Options → "Turn on debug logging for 10 minutes" (production builds).
    @discardableResult
    func startDebugMode(now: Date = .now) -> DebugModeStatus? {
        guard !LogPolicy.isDevBuild, !ScreenshotMode.isActive else { return debugStatus }
        if let status = debugStatus { return status }
        let code = DebugCode.generate()
        let until = now.addingTimeInterval(LogPolicy.debugModeDuration)
        // From now on only: production keeps no pre-roll of what came before.
        let since = now
        let defaults = UserDefaults.standard
        defaults.set(code, forKey: Keys.debugCode)
        defaults.set(until.timeIntervalSince1970, forKey: Keys.debugUntil)
        defaults.set(since.timeIntervalSince1970, forKey: Keys.debugSince)
        activate(LogUploadSession(code: code, reason: "debug_mode"), until: until, since: since)
        AppLog.notice(.logging, "logging.debug_mode", "Debug mode on for 10 minutes", [
            "on": true, "reason": "user", "minutes": .int(Int(LogPolicy.debugModeDuration / 60)),
        ])
        return debugStatus
    }

    /// Options → "Turn off", or the 10 minutes are over: back to normal after a last upload.
    func stopDebugMode(expired: Bool = false) {
        guard !LogPolicy.isDevBuild else { return }
        let session = lock.withLock { () -> LogUploadSession? in
            guard let session = state.session, session.reason == "debug_mode" else { return nil }
            return session
        }
        guard let session else { return }
        AppLog.notice(.logging, "logging.debug_mode", "Debug mode off", ["on": false, "reason": .string(expired ? "expired" : "user")])
        lock.withLock {
            state.session = nil
            state.debugUntil = nil
            state.level = LogPolicy.baseLevel
        }
        clearDebugDefaults()
        Task.detached(priority: .utility) {
            await LogUploader.shared.finish(session)
        }
    }

    private func clearDebugDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.debugCode)
        defaults.removeObject(forKey: Keys.debugUntil)
        defaults.removeObject(forKey: Keys.debugSince)
    }

    private func activate(_ session: LogUploadSession, until: Date?, since: Date?) {
        lock.withLock {
            state.session = session
            state.debugUntil = until
            state.level = .debug
        }
        let cursor = Self.cursor
        let sinceStamp = since.map { timestamp.format($0) }
        queue.async {
            self.store.beginPending(after: cursor, since: sinceStamp)
        }
        Task.detached(priority: .utility) { await LogUploader.shared.start() }
        if let until {
            let code = session.code
            Task.detached(priority: .utility) {
                let seconds = until.timeIntervalSinceNow
                if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
                // Only the session this timer was made for.
                if LogCore.shared.uploadSession?.code == code { LogCore.shared.stopDebugMode(expired: true) }
            }
        }
    }

    // MARK: Upload cursor (the last uploaded seq)

    static var cursor: Int {
        get { UserDefaults.standard.integer(forKey: Keys.cursor) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cursor) }
    }

    func acknowledge(through seq: Int) {
        if seq > Self.cursor { Self.cursor = seq }
        queue.async { self.store.acknowledge(through: seq) }
    }

    // MARK: Queue access

    func onQueue<T: Sendable>(_ body: @escaping @Sendable (LogStore) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self.store)) }
        }
    }

    /// Everything on disk, oldest first (the viewer).
    func records() async -> [LogRecord] {
        await onQueue { $0.records() }
    }
}

// MARK: - Signposts (Instruments: subsystem com.arcu.Attnd, category perf)

enum AppSignpost {
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "perf")
    /// The same intervals on Points of Interest, so Instruments' Time Profiler shows them by default.
    static let pointsOfInterest = OSSignposter(subsystem: AppLog.subsystem, category: .pointsOfInterest)

    /// The intervals (Instruments name; `perf.signpost` `name` from LOG_EVENTS.md).
    enum Name: String, Sendable {
        case launch
        case bundleFetch = "bundle_fetch"
        case planner
        case mapFirstRender = "map_first_render"
        // Main-thread audit (batch 7).
        case bundleApply = "bundle_apply"
        case bundleSave = "bundle_save"
        case searchIndex = "search_index"

        var signpostName: StaticString {
            switch self {
            case .bundleApply:    return "bundle apply"
            case .bundleSave:     return "bundle save"
            case .searchIndex:    return "search index"
            case .launch:         return "launch"
            case .bundleFetch:    return "bundle fetch"
            case .planner:        return "planner"
            case .mapFirstRender: return "map first render"
            }
        }
    }

    /// One running interval: begin and end it in the same flow.
    struct Interval: @unchecked Sendable {
        let name: Name
        let state: OSSignpostIntervalState
        let poiState: OSSignpostIntervalState
        let started: ContinuousClock.Instant

        var elapsedMs: Int { (ContinuousClock.now - started).wholeMilliseconds }
    }

    static func begin(_ name: Name) -> Interval {
        MainThreadWatchdog.noteBegin(name.rawValue)
        let id = signposter.makeSignpostID()
        let poiID = pointsOfInterest.makeSignpostID()
        return Interval(name: name,
                        state: signposter.beginInterval(name.signpostName, id: id),
                        poiState: pointsOfInterest.beginInterval(name.signpostName, id: poiID),
                        started: .now)
    }

    /// Ends the interval and logs `perf.signpost` (name, ms). Returns the milliseconds.
    @discardableResult
    static func end(_ interval: Interval, _ fields: @autoclosure () -> LogFields = [:]) -> Int {
        signposter.endInterval(interval.name.signpostName, interval.state)
        pointsOfInterest.endInterval(interval.name.signpostName, interval.poiState)
        MainThreadWatchdog.noteEnd(interval.name.rawValue)
        let ms = interval.elapsedMs
        AppLog.debug(.perf, "perf.signpost", "\(interval.name.rawValue) in \(ms) ms",
                     fields().merging(["name": .string(interval.name.rawValue), "ms": .int(ms)]) { _, new in new })
        return ms
    }
}

extension Duration {
    /// Whole milliseconds (rounded down).
    var wholeMilliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Launch timing

/// Cold launch = process start (or the App's init when iOS pre-warmed the process) → first
/// frame of the root view; warm launch = the scene leaving the background → active.
/// Logged as `lifecycle.launch` and counted as `perf_launch_cold` / `perf_launch_warm` (API-014;
/// the app and the App Clip alike).
@MainActor
enum LaunchTiming {
    private static var signpost: AppSignpost.Interval?
    private static var appInitAt: Date?
    private static var reported = false
    private static var wasInBackground = false
    private static var resumeStart: ContinuousClock.Instant?
    private static var backgroundAt: Date?
    private static var foregroundAt = Date.now

    /// The App's init (before the first scene).
    static func appDidInit() {
        guard appInitAt == nil else { return }
        appInitAt = .now
        signpost = AppSignpost.begin(.launch)
    }

    /// The root view's first frame.
    static func firstFrame() {
        guard !reported else { return }
        reported = true
        let start = isPrewarmed ? appInitAt : (processStartDate() ?? appInitAt)
        let ms = start.map { max(0, Int(Date.now.timeIntervalSince($0) * 1000)) } ?? 0
        if let signpost { AppSignpost.end(signpost, ["kind": "cold"]) }
        signpost = nil
        AppLog.info(.lifecycle, "lifecycle.launch", "Cold launch in \(ms) ms",
                    ["kind": "cold", "ms": .int(ms), "prewarmed": .bool(isPrewarmed)])
        PerfMetrics.shared.record(.perfLaunchCold, detail: PerfBucket.launch(ms: ms))
    }

    /// The scene phase changed (AppRootView).
    static func scenePhaseChanged(background: Bool, active: Bool) {
        if background {
            if !wasInBackground {
                AppLog.info(.lifecycle, "lifecycle.background", "To the background",
                            ["fg_s": .int(Int(Date.now.timeIntervalSince(foregroundAt)))])
                backgroundAt = .now
            }
            wasInBackground = true
            resumeStart = nil
            return
        }
        if wasInBackground, resumeStart == nil {
            resumeStart = .now
        }
        guard active, wasInBackground, let resumeStart else { return }
        wasInBackground = false
        let ms = (ContinuousClock.now - resumeStart).wholeMilliseconds
        self.resumeStart = nil
        foregroundAt = .now
        AppLog.info(.lifecycle, "lifecycle.foreground", "Back in the foreground",
                    ["since_bg_s": .int(backgroundAt.map { Int(Date.now.timeIntervalSince($0)) } ?? 0)])
        AppLog.info(.lifecycle, "lifecycle.launch", "Warm launch in \(ms) ms", ["kind": "warm", "ms": .int(ms)])
        PerfMetrics.shared.record(.perfLaunchWarm, detail: PerfBucket.launch(ms: ms))
    }

    /// iOS may start the process ahead of the user's tap ("pre-warming").
    static var isPrewarmed: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    /// When the kernel started this process.
    nonisolated static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}

// MARK: - Main-thread watchdog (batch 7; Debug and Dev builds only)

/// A background thread asks the main queue for a reply every 50 ms; when the main thread takes
/// longer than 100 ms to answer, the stall is logged as `perf.hang` with its length and the
/// signpost interval that was running (`AppSignpost`), so TestFlight logs show where the UI
/// stuttered. Never in Release builds or screenshot mode.
enum MainThreadWatchdog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [String] = []
    nonisolated(unsafe) private static var started = false

    static func noteBegin(_ name: String) {
        lock.lock(); running.append(name); lock.unlock()
    }

    static func noteEnd(_ name: String) {
        lock.lock()
        if let i = running.lastIndex(of: name) { running.remove(at: i) }
        lock.unlock()
    }

    private static var current: String? {
        lock.lock(); defer { lock.unlock() }
        return running.last
    }

    static func start() {
        #if DEBUG
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        let thread = Thread {
            let threshold: TimeInterval = 0.1
            while true {
                let sent = Date()
                let signpostAtSend = current
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + threshold) == .timedOut {
                    answered.wait()
                    let ms = Int(Date().timeIntervalSince(sent) * 1000)
                    let signpost = signpostAtSend ?? current
                    AppLog.warning(.perf, "perf.hang", "Main thread busy for \(ms) ms", {
                        var fields: LogFields = ["ms": .int(ms)]
                        if let signpost { fields["signpost"] = .string(signpost) }
                        return fields
                    }())
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        thread.name = "attnd.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        #endif
    }
}
