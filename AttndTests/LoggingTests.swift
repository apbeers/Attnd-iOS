// LoggingTests.swift
// AttndTests
//
// Logging and diagnostics (API-013 / API-014, shared logging spec): redaction, the record format,
// gzip, debug codes, perf buckets, the upload body and the ring buffer.

import XCTest
@testable import Attnd

final class LoggingTests: XCTestCase {

    // MARK: - Redaction

    func testPathTemplate_IdsAndQueriesRemoved() {
        XCTAssertEqual(LogRedaction.pathTemplate("events/5/bundle/"), "events/{id}/bundle/")
        XCTAssertEqual(LogRedaction.pathTemplate("events/nearby/?lat=30.2672&lng=-97.7431"), "events/nearby/")
        XCTAssertEqual(LogRedaction.pathTemplate("events/lookup/?q=Austin%20Tech"), "events/lookup/")
        XCTAssertEqual(LogRedaction.pathTemplate("https://attnd.app/api/v2/events/12/join/?x=1#y"), "/api/v2/events/{id}/join/")
        XCTAssertEqual(LogRedaction.pathTemplate("https://attnd.app"), "/")
        XCTAssertEqual(LogRedaction.pathTemplate("devices/"), "devices/")
        XCTAssertEqual(LogRedaction.pathTemplate("/api/app-status/"), "/api/app-status/")
        XCTAssertEqual(LogRedaction.pathTemplate("devices/3F2A9C1E-1234-4ABC-9DEF-0123456789AB/"), "devices/{id}/")
        XCTAssertEqual(LogRedaction.pathTemplate("tokens/a1b2c3d4e5f60718293a4b5c/"), "tokens/{id}/")
        XCTAssertEqual(LogRedaction.pathTemplate("users/someone@example.com/"), "users/{id}/")
        // API names stay, including the version.
        XCTAssertEqual(LogRedaction.pathTemplate("/api/v2/diagnostics/logs/"), "/api/v2/diagnostics/logs/")
    }

    func testTextFields_LengthOnlyInProduction() {
        XCTAssertEqual(LogRedaction.textFields("street tacos", includeText: false), ["query_len": 12])
        XCTAssertEqual(LogRedaction.textFields("street tacos", includeText: true), ["query_len": 12, "query": "street tacos"])
        XCTAssertEqual(LogRedaction.textFields("plan my day", key: "request", includeText: false), ["request_len": 11])
    }

    func testCoordinateRoundedToHundredths() {
        XCTAssertEqual(LogRedaction.coordinate(30.267153), 30.27, accuracy: 1e-9)
        XCTAssertEqual(LogRedaction.coordinate(-97.743061), -97.74, accuracy: 1e-9)
    }

    func testScrub_RemovesSecretsAndIdentifiers() {
        XCTAssertEqual(LogRedaction.scrub("mail jane.doe@example.com now"), "mail <email> now")
        XCTAssertEqual(LogRedaction.scrub("Authorization: Bearer abc.DEF-123_xyz"), "Authorization: Bearer <redacted>")
        XCTAssertEqual(LogRedaction.scrub("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl done"), "jwt <token> done")
        XCTAssertEqual(LogRedaction.scrub("device 3f2a9c1e-1234-4abc-9def-0123456789ab joined"), "device <uuid> joined")
        XCTAssertEqual(LogRedaction.scrub("token " + String(repeating: "ab12", count: 16)), "token <hex>")
        XCTAssertEqual(LogRedaction.scrub("GET https://attnd.app/api/v2/events/lookup/?q=secret failed"),
                       "GET https://attnd.app/api/v2/events/lookup/ failed")
        XCTAssertEqual(LogRedaction.scrub("api_key=sk-live-123 and password: hunter2"), "api_key=<redacted> and password: <redacted>")
        // Ordinary text is left alone.
        XCTAssertEqual(LogRedaction.scrub("GET events/{id}/bundle/ 304 in 182 ms"), "GET events/{id}/bundle/ 304 in 182 ms")
        XCTAssertEqual(LogRedaction.scrub("short"), "short")
        // A debug code is fine to log (it is the session's own id).
        XCTAssertEqual(LogRedaction.scrub("Debug mode D-7K3QX on"), "Debug mode D-7K3QX on")
    }

    func testErrorFields() {
        let fields = LogRedaction.errorFields(APIError.serverError(503))
        XCTAssertEqual(fields["kind"], "server_503")
        XCTAssertEqual(fields["type"], "APIError")
        let url = LogRedaction.errorFields(URLError(.timedOut))
        XCTAssertEqual(url["url_error"], "timeout")
        XCTAssertEqual(url["domain"], .string(NSURLErrorDomain))
        XCTAssertEqual(url["code"], .int(URLError.Code.timedOut.rawValue))
        XCTAssertEqual(LogRedaction.urlErrorKind(URLError(.notConnectedToInternet)), "offline")
        XCTAssertEqual(LogRedaction.urlErrorKind(URLError(.cancelled)), "cancelled")
        XCTAssertEqual(LogRedaction.urlErrorKind(URLError(.cannotFindHost)), "dns")
        XCTAssertEqual(LogRedaction.urlErrorKind(URLError(.secureConnectionFailed)), "tls")
        XCTAssertEqual(LogRedaction.urlErrorKind(URLError(.badServerResponse)), "other")
    }

    func testSupportInfoNeverHoldsTheDebugCode() {
        // The debug code must never be linked to the device id (spec §3).
        let info = SupportInfo(
            appVersion: "2.0.1", buildNumber: "1", serverHost: "attnd.app", apiVersion: 2, osVersion: "27.2",
            deviceModel: "iPhone18,1", isAppClip: false, deviceId: "3f2a9c1e-1234-4abc-9def-0123456789ab"
        )
        XCTAssertFalse(info.plainText.contains("D-"))
    }

    // MARK: - Record format (v = 1)

    private func record(seq: Int, level: LogLevel = .debug, ts: String? = nil, msg: String = "hello") -> LogRecord {
        LogRecord(
            ts: ts ?? Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now), monoMs: 523_101, seq: seq,
            level: level, cat: .net, event: "net.request.finished", msg: msg, f: ["status": 304, "ms": 182, "not_modified": true],
            app: "2.0.131", build: "131", os: "iOS 27.2", model: "iPhone18,1", state: "fg", net: "wifi",
            eventId: 5, diag: nil
        )
    }

    func testRecordEncoding_WireKeys() throws {
        let data = try JSONEncoder().encode(record(seq: 4182))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["v", "ts", "mono_ms", "seq", "level", "cat", "event", "msg", "f", "app", "build",
                                         "os", "model", "state", "net", "event_id"])
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["level"] as? String, "debug")
        XCTAssertEqual(json["cat"] as? String, "net")
        XCTAssertEqual(json["mono_ms"] as? Int, 523_101)
        let fields = try XCTUnwrap(json["f"] as? [String: Any])
        XCTAssertEqual(fields["status"] as? Int, 304)
        XCTAssertEqual(fields["not_modified"] as? Bool, true)
        // No diag key without a debug session.
        XCTAssertNil(json["diag"])
    }

    func testRecordDecoding_RoundTripAndLenient() throws {
        let original = record(seq: 7)
        let decoded = try JSONDecoder().decode(LogRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        let sparse = try JSONDecoder().decode(LogRecord.self, from: Data(#"{"seq":3,"level":5,"cat":"nope","extra":1}"#.utf8))
        XCTAssertEqual(sparse.seq, 3)
        XCTAssertEqual(sparse.level, .error)
        XCTAssertEqual(sparse.cat, .lifecycle)
        XCTAssertEqual(sparse.v, 1)
    }

    func testLevelsAndCategories() {
        XCTAssertEqual(LogLevel.allCases.map(\.name), ["trace", "debug", "info", "notice", "warning", "error", "fault"])
        XCTAssertEqual(LogLevel.allCases.map(\.rawValue), Array(0...6))
        XCTAssertTrue(LogLevel.warning > .info)
        XCTAssertEqual(LogCategory.allCases.map(\.rawValue), [
            "net", "push", "background", "live", "location", "map", "planner", "assistant", "search", "storage", "ui",
            "perf", "auth", "lifecycle", "logging",
        ])
        XCTAssertEqual(record(seq: 1).compactFields, "ms=182 not_modified=true status=304")
    }

    // MARK: - Gzip

    func testCRC32() {
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(Gzip.crc32(Data()), 0)
    }

    func testGzip_HeaderPayloadTrailer() throws {
        let text = Data(String(repeating: #"{"event":"net.request.finished"}"#, count: 50).utf8)
        let gz = try XCTUnwrap(Gzip.compress(text))
        XCTAssertEqual(Array(gz.prefix(4)), [0x1F, 0x8B, 0x08, 0x00])
        XCTAssertLessThan(gz.count, text.count)
        let trailer = Array(gz.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        XCTAssertEqual(crc, Gzip.crc32(text))
        XCTAssertEqual(Int(size), text.count)
        let deflated = gz.subdata(in: 10..<(gz.count - 8))
        let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(inflated, text)
    }

    // MARK: - Debug codes

    func testDebugCode_Format() {
        for _ in 0..<200 {
            let code = DebugCode.generate()
            XCTAssertTrue(DebugCode.isValid(code), code)
            XCTAssertEqual(code.count, 7)
            XCTAssertTrue(code.hasPrefix("D-"))
            XCTAssertFalse(code.dropFirst(2).contains { "ILOU".contains($0) })
        }
        XCTAssertTrue(DebugCode.isValid("D-7K3QX"))
        XCTAssertFalse(DebugCode.isValid("D-7K3QI"))
        XCTAssertFalse(DebugCode.isValid("D-7k3qx"))
        XCTAssertFalse(DebugCode.isValid("X-7K3QX"))
        XCTAssertFalse(DebugCode.isValid("D-7K3Q"))
    }

    // MARK: - Perf buckets (API-014)

    func testPerfBuckets() {
        // The server's labels exactly (attnd-web events/usage.py PERF_METRICS).
        XCTAssertEqual([0, 499, 500, 999, 1_000, 1_999, 3_999, 4_000, 60_000].map(PerfBucket.launch(ms:)),
                       ["<0.5s", "<0.5s", "<1s", "<1s", "<2s", "<2s", "<4s", ">=4s", ">=4s"])
        XCTAssertEqual([0, 249, 250, 499, 999, 1_999, 4_999, 5_000].map(PerfBucket.bundleFetch(ms:)),
                       ["<250ms", "<250ms", "<500ms", "<500ms", "<1s", "<2s", "<5s", ">=5s"])
        XCTAssertEqual([4_999, 9_999, 14_999, 29_999, 59_999, 60_000].map(PerfBucket.pushRefreshDelay(ms:)),
                       ["<5s", "<10s", "<15s", "<30s", "<60s", ">=60s"])
        XCTAssertEqual([99, 249, 499, 999, 1_999, 2_000].map(PerfBucket.planner(ms:)),
                       ["<100ms", "<250ms", "<500ms", "<1s", "<2s", ">=2s"])
        XCTAssertEqual([249, 499, 999, 1_999, 3_999, 4_000].map(PerfBucket.mapFirstRender(ms:)),
                       ["<250ms", "<500ms", "<1s", "<2s", "<4s", ">=4s"])
        XCTAssertEqual(PerfBucket.apiError(status: 404), "4xx")
        XCTAssertEqual(PerfBucket.apiError(status: 503), "5xx")
        XCTAssertNil(PerfBucket.apiError(status: 304))
        XCTAssertEqual(PerfBucket.apiError(URLError(.timedOut)), "timeout")
        XCTAssertEqual(PerfBucket.apiError(URLError(.notConnectedToInternet)), "offline")
        XCTAssertNil(PerfBucket.apiError(URLError(.cancelled)))
    }

    func testPerfMetrics_DrainDropsOldEntries() {
        let metrics = PerfMetrics()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        metrics.record(.perfBundle304, at: now.addingTimeInterval(-60))
        metrics.record(.perfBundleFetch, detail: "<250ms", at: now.addingTimeInterval(-7 * 24 * 3600))
        let drained = metrics.drain(now: now)
        XCTAssertEqual(drained.map(\.metric), [.perfBundle304])
        XCTAssertTrue(metrics.isEmpty)
    }

    // MARK: - Upload body and Retry-After

    func testUploadBody_SplicesLines() throws {
        let header = LogUploadHeader(session: "D-7K3QX", app: "2.0.131", build: "131", os: "iOS 27.2", model: "iPhone18,1", reason: "debug_mode")
        let lines = try [record(seq: 1), record(seq: 2)].map { try JSONEncoder().encode($0) }
        let body = try XCTUnwrap(header.body(lines: lines))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["session"] as? String, "D-7K3QX")
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["reason"] as? String, "debug_mode")
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["seq"] as? Int }, [1, 2])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: XCTUnwrap(header.body(lines: []))))
    }

    func testRetryAfter() {
        XCTAssertEqual(APIClient.retryAfter("120"), 120)
        XCTAssertEqual(APIClient.retryAfter(" 5 "), 5)
        XCTAssertNil(APIClient.retryAfter(nil))
        XCTAssertNil(APIClient.retryAfter("soon"))
        let now = Date(timeIntervalSince1970: 1_794_700_000)  // 2026-11-14T…Z
        let later = now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(APIClient.retryAfter(formatter.string(from: later), now: now) ?? 0, 90, accuracy: 1)
    }

    // MARK: - Ring buffer

    private func makeStore() throws -> LogStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attnd-logs-test-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LogStore(directory: directory)
    }

    func testStore_WritesReadsAndRotates() throws {
        let store = try makeStore()
        XCTAssertEqual(store.lastSequence(), 0)
        let padding = String(repeating: "x", count: 600)
        let count = 2_500
        for seq in 1...count { store.append(record(seq: seq, msg: padding)) }
        // Rotated once past ~1 MB: both files exist, together ≤ ~2 MB, the newest lines kept.
        let previous = try XCTUnwrap(store.previousURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(store.lastSequence(), count)
        let records = store.records()
        XCTAssertEqual(records.last?.seq, count)
        XCTAssertGreaterThan(records.count, 1_000)
        XCTAssertEqual(records.map(\.seq), records.map(\.seq).sorted())
        // A fresh store on the same files continues the sequence.
        XCTAssertEqual(LogStore(directory: store.directory).lastSequence(), count)
    }

    func testStore_PendingUploadsStartWithDebugMode() throws {
        let store = try makeStore()
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let old = stamp.format(Date.now.addingTimeInterval(-3600))
        store.append(record(seq: 1, level: .error, ts: old))
        store.append(record(seq: 2, level: .error, ts: old))
        XCTAssertEqual(store.records().map(\.seq), [1, 2])

        // Debug mode: only what is captured from the moment it is turned on (no pre-roll).
        let since = stamp.format(Date.now)
        store.beginPending(after: 0, since: since)
        XCTAssertTrue(store.batch().isEmpty)
        store.append(record(seq: 3))
        store.append(record(seq: 4))
        XCTAssertEqual(store.batch().map(\.seq), [3, 4])
        XCTAssertEqual(store.batch(maxEntries: 1).map(\.seq), [3])
        store.acknowledge(through: 3)
        XCTAssertEqual(store.batch().map(\.seq), [4])
        // Lines are the stored JSON.
        let line = try XCTUnwrap(store.batch().first?.line)
        XCTAssertEqual(try JSONDecoder().decode(LogRecord.self, from: line).seq, 4)
        store.endPending()
        store.append(record(seq: 5))
        XCTAssertTrue(store.batch().isEmpty)
        XCTAssertEqual(store.records().map(\.seq), [1, 2, 3, 4, 5])
    }

    func testPolicy_ReleaseKeepsErrorsOnly() {
        XCTAssertEqual(LogPolicy.captureLevel(developerBuild: false), .error)
        XCTAssertEqual(LogPolicy.captureLevel(developerBuild: true), .debug)
        XCTAssertTrue(LogLevel.fault >= LogPolicy.captureLevel(developerBuild: false))
        XCTAssertFalse(LogLevel.warning >= LogPolicy.captureLevel(developerBuild: false))
    }

    func testStore_BatchRespectsByteLimit() throws {
        let store = try makeStore()
        store.beginPending(after: 0, since: nil)
        for seq in 1...10 { store.append(record(seq: seq, msg: String(repeating: "y", count: 1_000))) }
        let lineBytes = try XCTUnwrap(store.batch().first?.line.count)
        XCTAssertEqual(store.batch(maxBytes: lineBytes * 3 + 3).count, 3)
        // One oversized line still goes alone rather than blocking the queue.
        XCTAssertEqual(store.batch(maxBytes: 10).count, 1)
    }
}
