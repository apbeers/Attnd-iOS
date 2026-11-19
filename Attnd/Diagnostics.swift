// Diagnostics.swift
// Attnd (app + App Clip)
//
// The pieces behind AppLog (AppLog.swift):
//   - LogStore: the ring buffer on disk (JSON lines, two files of ~1 MB, newest kept) and the
//     lines waiting for upload. Every captured record is kept on disk (no in-memory pre-roll).
//   - LogUploader: batches (≤ 500 entries, ≤ 256 KB), gzip, `POST /api/v2/diagnostics/logs/`
//     (API-013), honouring 429 `Retry-After`; only in Dev builds and debug mode.
//   - Gzip (RFC 1952 around the system's raw DEFLATE), DebugCode (`D-XXXXX`).
//   - PerfBucket + PerfMetrics (API-014): anonymous performance counts with bucketed details, sent
//     with the usage batch (`UsageReporter`) of the joined event, or the next one.

import Foundation

// MARK: - Ring buffer

/// Owned by `LogCore.queue`: never touch it from anywhere else.
final class LogStore: @unchecked Sendable {

    /// Each of the two files; together ~2 MB.
    static let maxFileBytes = 1_000_000
    static let maxPending = 20_000
    static let earlyUploadCount = 200

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-logs", isDirectory: true)
    }

    /// A line waiting for upload.
    struct PendingLine: Sendable, Hashable {
        var seq: Int
        var line: Data
    }

    let directory: URL?
    private var handle: FileHandle?
    private var currentBytes = 0
    private var pending: [PendingLine] = []
    private var collectsPending = false
    private var uploadNudged = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL?) {
        self.directory = directory
    }

    var currentURL: URL? { directory?.appendingPathComponent("current.jsonl") }
    var previousURL: URL? { directory?.appendingPathComponent("previous.jsonl") }

    // MARK: Writing

    func append(_ record: LogRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if currentBytes + line.count > Self.maxFileBytes { rotate() }
        guard let handle = openHandle() else { return }
        do {
            try handle.write(contentsOf: line)
            currentBytes += line.count
        } catch {
            // The disk is full or the file went away: reopen next time.
            try? handle.close()
            self.handle = nil
        }
        if collectsPending {
            pending.append(PendingLine(seq: record.seq, line: line.dropLast()))
            if pending.count > Self.maxPending {
                // Drop a block (not one line at a time), so the line below doesn't trip it again.
                let dropped = min(pending.count, pending.count - Self.maxPending + 500)
                pending.removeFirst(dropped)
                AppLog.warning(.logging, "logging.dropped", "\(dropped) log lines dropped before upload", [
                    "count": .int(dropped), "reason": "cap",
                ])
            }
            // Dev builds: a batch every ~30 s or 200 records, whichever comes first.
            if pending.count >= Self.earlyUploadCount, !uploadNudged {
                uploadNudged = true
                Task.detached(priority: .utility) { await LogUploader.shared.uploadPending() }
            }
        }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        guard let directory, let url = currentURL else { return nil }
        StorageDirectory.prepare(directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        currentBytes = Int((try? handle.seekToEnd()) ?? 0)
        self.handle = handle
        return handle
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        currentBytes = 0
        guard let current = currentURL, let previous = previousURL else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
    }

    // MARK: Reading

    /// The seq of the newest line on disk (0 when there is none), read from the file's tail.
    func lastSequence() -> Int {
        for url in [currentURL, previousURL].compactMap({ $0 }) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > 16_384 ? size - 16_384 : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                if let record = try? decoder.decode(SequenceOnly.self, from: Data(line)) { return record.seq }
            }
        }
        return 0
    }

    private struct SequenceOnly: Decodable {
        var seq: Int
        var ts: String?
    }

    private func diskLines() -> [Data] {
        [previousURL, currentURL].compactMap { $0 }.flatMap { url -> [Data] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return data.split(separator: 0x0A).map { Data($0) }
        }
    }

    /// Everything on disk, oldest first.
    func records() -> [LogRecord] {
        var bySeq: [Int: LogRecord] = [:]
        for line in diskLines() {
            if let record = try? decoder.decode(LogRecord.self, from: line) { bySeq[record.seq] = record }
        }
        return bySeq.values.sorted { $0.seq < $1.seq }
    }

    // MARK: Pending uploads

    /// Starts collecting lines for upload: those on disk after `cursor` (and from `since`), then
    /// every new one.
    func beginPending(after cursor: Int, since: String?) {
        var lines: [PendingLine] = []
        for line in diskLines() {
            guard let head = try? decoder.decode(SequenceOnly.self, from: line), head.seq > cursor else { continue }
            if let since, (head.ts ?? "") < since { continue }
            lines.append(PendingLine(seq: head.seq, line: line))
        }
        lines.sort { $0.seq < $1.seq }
        if lines.count > Self.maxPending { lines.removeFirst(lines.count - Self.maxPending) }
        pending = lines
        collectsPending = true
    }

    func endPending() {
        collectsPending = false
        pending = []
    }

    /// The oldest pending lines that fit one request.
    func batch(maxEntries: Int = LogUploader.maxEntries, maxBytes: Int = LogUploader.maxBytes) -> [PendingLine] {
        var result: [PendingLine] = []
        var bytes = 0
        for line in pending {
            guard result.count < maxEntries else { break }
            if !result.isEmpty, bytes + line.line.count + 1 > maxBytes { break }
            result.append(line)
            bytes += line.line.count + 1
        }
        return result
    }

    var hasPending: Bool { !pending.isEmpty }

    func acknowledge(through seq: Int) {
        pending.removeAll { $0.seq <= seq }
        uploadNudged = false
    }

    /// The records as one `.jsonl` file in the temporary directory (the viewer's Share).
    static func exportFile(_ records: [LogRecord]) throws -> URL {
        let encoder = JSONEncoder()
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attnd-logs-\(Int(Date.now.timeIntervalSince1970)).jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Upload (API-013)

/// Body of `POST /api/v2/diagnostics/logs/` (gzip): the header fields, then `entries` spliced
/// in from the stored lines unchanged.
struct LogUploadHeader: Encodable, Sendable {
    var session: String
    var platform = "ios"
    var app: String
    var build: String
    var os: String
    var model: String
    var reason: String

    /// `{"session":…, …, "entries":[<line>,<line>]}`
    func body(lines: [Data]) -> Data? {
        guard var head = try? JSONEncoder().encode(self), head.last == UInt8(ascii: "}") else { return nil }
        head.removeLast()
        head.append(contentsOf: Array(#","entries":["#.utf8))
        for (index, line) in lines.enumerated() {
            if index > 0 { head.append(UInt8(ascii: ",")) }
            head.append(line)
        }
        head.append(contentsOf: Array("]}".utf8))
        return head
    }
}

/// Uploads pending log lines while a session runs: every ~10 s in debug mode, every ~30 s (or
/// 200 records) in Dev builds, and when the app goes to the background (API_V2.md → Diagnostics).
actor LogUploader {
    static let shared = LogUploader()

    static let maxEntries = 500
    /// Uncompressed JSON per request; gzip makes it far smaller than the server's 256 KB as sent
    /// (and it stays under the 2 MB decompressed limit).
    static let maxBytes = 256 * 1024

    static func interval(for session: LogUploadSession?) -> Duration {
        session?.reason == "dev" ? .seconds(30) : .seconds(10)
    }

    private var loop: Task<Void, Never>?
    private var notBefore = Date.distantPast
    private var failures = 0
    private var busy = false
    /// Halved after a 413, back to the maximum after a success.
    private var entryLimit = LogUploader.maxEntries

    func start() {
        guard loop == nil else { return }
        loop = Task {
            // The first batch (what an earlier launch left) goes out soon.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self.uploadPending()
                try? await Task.sleep(for: LogUploader.interval(for: LogCore.shared.uploadSession))
            }
        }
    }

    /// Debug mode ended: send the rest under its code, then stop collecting.
    func finish(_ session: LogUploadSession) async {
        loop?.cancel()
        loop = nil
        await upload(session)
        await LogCore.shared.onQueue { $0.endPending() }
    }

    func uploadPending() async {
        guard let session = LogCore.shared.uploadSession else { return }
        await upload(session)
    }

    private func upload(_ session: LogUploadSession) async {
        guard !busy, !ScreenshotMode.isActive else { return }
        busy = true
        defer { busy = false }
        let env = LogCore.shared.environment
        let header = LogUploadHeader(session: session.code, app: env.app, build: env.build, os: env.os, model: env.model, reason: session.reason)
        // A few batches per round, so a backlog drains without hogging the network.
        for _ in 0..<6 {
            guard Date.now >= notBefore else { return }
            let limit = entryLimit
            let batch = await LogCore.shared.onQueue { $0.batch(maxEntries: limit) }
            guard let last = batch.last else { return }
            guard let body = header.body(lines: batch.map(\.line)), let gzipped = Gzip.compress(body) else { return }
            switch await APIClient.shared.postDiagnostics("diagnostics/logs/", gzippedJSON: gzipped, diagSession: session.code) {
            case .accepted:
                failures = 0
                entryLimit = Self.maxEntries
                LogCore.shared.acknowledge(through: last.seq)
                // Logged after the batch went out, so it travels in the next one (once).
                AppLog.debug(.logging, "logging.upload", "Sent \(batch.count) log lines", [
                    "entries": .int(batch.count), "bytes": .int(gzipped.count), "status": 200,
                ])
            case .rejected(413) where batch.count > 1:
                // Too large: the same lines again in smaller batches.
                entryLimit = max(1, batch.count / 2)
            case .rejected(let status):
                // The server can't use this batch: drop it rather than retry forever.
                LogCore.shared.acknowledge(through: last.seq)
                AppLog.warning(.logging, "logging.upload.failed", "Log batch rejected (\(status)), dropped",
                               ["error": "rejected", "status": .int(status), "entries": .int(batch.count)])
            case .retryAfter(let seconds):
                notBefore = Date.now.addingTimeInterval(seconds)
                AppLog.debug(.logging, "logging.upload", "Log upload deferred for \(Int(seconds)) s", [
                    "entries": 0, "bytes": 0, "status": 429, "retry_after_s": .int(Int(seconds)),
                ])
                return
            case .failed(let reason):
                failures += 1
                let delay = min(600, 30 * pow(2, Double(min(failures, 5))))
                notBefore = Date.now.addingTimeInterval(delay)
                AppLog.warning(.logging, "logging.upload.failed", "Log upload failed (\(reason)), next try in \(Int(delay)) s",
                               ["error": .string(reason), "entries": .int(batch.count)])
                return
            }
        }
    }
}

// MARK: - Gzip

/// gzip (RFC 1952): header, the system's raw DEFLATE (`NSData.CompressionAlgorithm.zlib` is
/// RFC 1951 without a zlib wrapper), CRC-32 and size.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflated)
        append(crc32(data), to: &out)
        append(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Debug code

/// `D-XXXXX`: five Crockford base32 characters, random per debug session (Dev builds: one per
/// install). Never derived from the device id.
enum DebugCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        "D-" + String((0..<5).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    static func isValid(_ code: String) -> Bool {
        guard code.count == 7, code.hasPrefix("D-") else { return false }
        return code.dropFirst(2).allSatisfy { alphabet.contains($0) }
    }
}

// MARK: - Anonymous performance metrics (API-014)

/// Bucketed details of the perf usage metrics: the server's labels (attnd-web
/// `events/usage.py` `PERF_METRICS`, API_V2.md); anything else is dropped there.
enum PerfBucket {
    /// `perf_launch_cold` / `perf_launch_warm`.
    static func launch(ms: Int) -> String {
        bucket(ms, [(500, "<0.5s"), (1_000, "<1s"), (2_000, "<2s"), (4_000, "<4s")], last: ">=4s")
    }

    /// `perf_bundle_fetch` (200, request → decoded) and `perf_bundle_304`.
    static func bundleFetch(ms: Int) -> String {
        bucket(ms, [(250, "<250ms"), (500, "<500ms"), (1_000, "<1s"), (2_000, "<2s"), (5_000, "<5s")], last: ">=5s")
    }

    /// `perf_push_refresh_delay`: a `content_updated` push received → its bundle shown (includes the
    /// 0–10 s random delay).
    static func pushRefreshDelay(ms: Int) -> String {
        bucket(ms, [(5_000, "<5s"), (10_000, "<10s"), (15_000, "<15s"), (30_000, "<30s"), (60_000, "<60s")], last: ">=60s")
    }

    /// `perf_planner_ms`: one planner run (the request → the plan, the on-device model included).
    static func planner(ms: Int) -> String {
        bucket(ms, [(100, "<100ms"), (250, "<250ms"), (500, "<500ms"), (1_000, "<1s"), (2_000, "<2s")], last: ">=2s")
    }

    /// `perf_map_first_render`: the Map tab appears → its first camera settles with the pins.
    static func mapFirstRender(ms: Int) -> String {
        bucket(ms, [(250, "<250ms"), (500, "<500ms"), (1_000, "<1s"), (2_000, "<2s"), (4_000, "<4s")], last: ">=4s")
    }

    /// `perf_api_error` for an HTTP status (nil below 400).
    static func apiError(status: Int) -> String? {
        switch status {
        case 400..<500: return "4xx"
        case 500..<600: return "5xx"
        default:        return nil
        }
    }

    /// `perf_api_error` for a transport error (nil when cancelled).
    static func apiError(_ error: URLError) -> String? {
        switch LogRedaction.urlErrorKind(error) {
        case "timeout":   return "timeout"
        case "cancelled": return nil
        default:          return "offline"
        }
    }

    /// `perf_live_start_fail`: "disabled", "denied", "limit" or "error".
    static let liveStartReasons: Set<String> = ["disabled", "denied", "limit", "error"]

    private static func bucket(_ ms: Int, _ limits: [(Int, String)], last: String) -> String {
        for (limit, name) in limits where ms < limit { return name }
        return last
    }
}

/// Perf counts from anywhere (any thread), waiting for the next usage flush of a joined event
/// (`UsageReporter`). Not in screenshot mode; at most 50 waiting, none older than 6 days
/// (the server accepts `at` within the last 7).
final class PerfMetrics: @unchecked Sendable {
    static let shared = PerfMetrics()

    struct Entry: Sendable, Hashable {
        var metric: UsageMetric
        var detail: String?
        var at: Date
        var count: Int
    }

    static let maxWaiting = 50
    static let maxAge: TimeInterval = 6 * 24 * 3600

    private let lock = NSLock()
    private var waiting: [Entry] = []
    private var observer: (@Sendable () -> Void)?

    func record(_ metric: UsageMetric, detail: String? = nil, at: Date = .now, count: Int = 1) {
        guard !ScreenshotMode.isActive, count > 0 else { return }
        let observer = lock.withLock { () -> (@Sendable () -> Void)? in
            waiting.append(Entry(metric: metric, detail: detail, at: at, count: count))
            if waiting.count > Self.maxWaiting { waiting.removeFirst(waiting.count - Self.maxWaiting) }
            return self.observer
        }
        AppLog.debug(.perf, "perf.metric", "\(metric.rawValue) \(detail ?? "")",
                     ["name": .string(metric.rawValue), "bucket": .string(detail ?? ""), "count": .int(count)])
        observer?()
    }

    /// Called after each record (UsageReporter schedules a flush).
    func setObserver(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { self.observer = observer }
    }

    func drain(now: Date = .now) -> [Entry] {
        lock.withLock {
            let entries = waiting.filter { now.timeIntervalSince($0.at) < Self.maxAge }
            waiting = []
            return entries
        }
    }

    var isEmpty: Bool { lock.withLock { waiting.isEmpty } }
}
