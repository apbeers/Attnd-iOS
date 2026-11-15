// MetricKitReporter.swift
// Attnd (app target only — not the App Clip or the widget extension)
//
// MetricKit (shared logging spec §6):
//   - Diagnostic payloads (crashes, hangs, CPU / disk-write exceptions, launch diagnostics) are
//     sent anonymously to `POST /api/v2/diagnostics/reports/` (API-013) as
//     `{platform, app, build, os, model, reports: [{kind, occurred_at, build, os, model, reason,
//     summary, exception, payload, diag?}]}`: no device id; `diag` only while debug mode / a Dev
//     build uploads logs, so the report joins that session. `payload` is MetricKit's own JSON
//     (call stacks; the admin panel symbolicates them with the build's dSYMs, kept as CI
//     artifacts). Kinds: crash, hang, cpu, disk_write, launch. Each request is written to
//     `Application Support/attnd-logs/reports/` first and deleted once the server has it, so a
//     failed upload is retried at the next launch (at most 20 kept).
//   - Daily metric payloads become the API-014 perf counts: time to first draw →
//     `perf_launch_cold`, resume time → `perf_launch_warm` (one count per histogram bucket,
//     bucketed like `PerfBucket.launch`), sent with the next usage batch of a joined event.
//     The full app's launch buckets come only from here (LaunchTiming logs its own measurement).
//
// Nothing here runs in screenshot mode. MetricKit delivers payloads at most once a day (crash
// and hang diagnostics at the next launch); Xcode's Debug → Simulate MetricKit Payloads tests it.

import Foundation
import MetricKit

final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReporter()

    static let maxStoredReports = 20

    private var started = false

    /// AppDelegate, at launch.
    func start() {
        guard !started, !ScreenshotMode.isActive else { return }
        started = true
        MXMetricManager.shared.add(self)
        Task.detached(priority: .utility) { await ReportUploader.shared.uploadStored() }
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let at = payload.timeStampEnd
            var counts: [(UsageMetric, String, Int)] = []
            if let launch = payload.applicationLaunchMetrics {
                counts += Self.launchCounts(launch.histogrammedTimeToFirstDraw, metric: .perfLaunchCold)
                counts += Self.launchCounts(launch.histogrammedApplicationResumeTime, metric: .perfLaunchWarm)
            }
            for (metric, detail, count) in counts {
                PerfMetrics.shared.record(metric, detail: detail, at: at, count: count)
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [Data] = []
        for payload in payloads {
            let at = payload.timeStampEnd
            func add(_ kind: String, _ diagnostics: [MXDiagnostic]?) {
                for diagnostic in diagnostics ?? [] {
                    if let body = Self.reportBody(kind: kind, diagnostic: diagnostic, at: at) { reports.append(body) }
                    AppLog.notice(.lifecycle, "lifecycle.exit_reason", "MetricKit \(kind) report", [
                        "reason": .string(kind), "build": .string(diagnostic.metaData.applicationBuildVersion),
                    ])
                }
            }
            add("crash", payload.crashDiagnostics)
            add("hang", payload.hangDiagnostics)
            add("cpu", payload.cpuExceptionDiagnostics)
            add("disk_write", payload.diskWriteExceptionDiagnostics)
            add("launch", payload.appLaunchDiagnostics)
        }
        guard !reports.isEmpty else { return }
        let stored = reports
        Task.detached(priority: .utility) {
            await ReportUploader.shared.store(stored)
            await ReportUploader.shared.uploadStored()
        }
    }

    // MARK: Payload → reports / counts

    /// One count per histogram bucket that has launches, at the bucket's midpoint.
    static func launchCounts(_ histogram: MXHistogram<UnitDuration>, metric: UsageMetric) -> [(UsageMetric, String, Int)] {
        var counts: [String: Int] = [:]
        for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator {
            guard bucket.bucketCount > 0 else { continue }
            let start = bucket.bucketStart.converted(to: .milliseconds).value
            let end = bucket.bucketEnd.converted(to: .milliseconds).value
            let ms = Int(((start + end) / 2).rounded())
            counts[PerfBucket.launch(ms: ms), default: 0] += bucket.bucketCount
        }
        return counts.keys.sorted().map { (metric, $0, counts[$0] ?? 0) }
    }

    /// One request body: `{"platform":"ios","app":…,"build":…,"os":…,"model":…,"reports":[{…}]}`.
    static func reportBody(kind: String, diagnostic: MXDiagnostic, at: Date) -> Data? {
        guard let payload = try? JSONSerialization.jsonObject(with: diagnostic.jsonRepresentation()) as? [String: Any] else { return nil }
        let env = LogEnvironment.current
        let build = diagnostic.metaData.applicationBuildVersion
        var report: [String: Any] = [
            "kind": kind,
            "occurred_at": ISODate.string(from: at),
            "build": build,
            "os": diagnostic.metaData.osVersion,
            "model": diagnostic.metaData.deviceType,
            "summary": summary(kind: kind, diagnostic: diagnostic),
            "payload": payload,
        ]
        // The marketing version is known only when the report is from this build.
        if build == env.build { report["app"] = env.app }
        if let crash = diagnostic as? MXCrashDiagnostic {
            if let reason = crash.terminationReason { report["reason"] = String(reason.prefix(200)) }
            if let objc = crash.exceptionReason {
                report["exception"] = ["type": objc.className, "message": objc.exceptionName]
            }
        }
        if let diag = LogCore.shared.uploadSession?.code { report["diag"] = diag }
        let body: [String: Any] = [
            "platform": "ios", "app": env.app, "build": env.build, "os": env.os, "model": env.model,
            "reports": [report],
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// "EXC_BAD_ACCESS (SIGSEGV)", "Hang 2.4 s", … (no user data).
    static func summary(kind: String, diagnostic: MXDiagnostic) -> String {
        switch diagnostic {
        case let crash as MXCrashDiagnostic:
            var parts: [String] = []
            if let type = crash.exceptionType { parts.append("exception \(type)") }
            if let code = crash.exceptionCode { parts.append("code \(code)") }
            if let signal = crash.signal { parts.append("signal \(signal)") }
            return parts.isEmpty ? "Crash" : "Crash: " + parts.joined(separator: ", ")
        case let hang as MXHangDiagnostic:
            return String(format: "Hang %.1f s", hang.hangDuration.converted(to: .seconds).value)
        case let cpu as MXCPUExceptionDiagnostic:
            return String(format: "CPU exception: %.0f s CPU", cpu.totalCPUTime.converted(to: .seconds).value)
        case let disk as MXDiskWriteExceptionDiagnostic:
            return String(format: "Disk writes: %.0f MB", disk.totalWritesCaused.converted(to: .megabytes).value)
        case let launch as MXAppLaunchDiagnostic:
            return String(format: "Slow launch: %.1f s", launch.launchDuration.converted(to: .seconds).value)
        default:
            return kind
        }
    }
}

/// Stored MetricKit reports and their upload (gzip, anonymous: no `X-Diag-Session`).
actor ReportUploader {
    static let shared = ReportUploader()

    private var busy = false

    private var directory: URL? {
        LogStore.defaultDirectory?.appendingPathComponent("reports", isDirectory: true)
    }

    func store(_ reports: [Data]) {
        guard let directory else { return }
        StorageDirectory.prepare(directory)
        for report in reports {
            let url = directory.appendingPathComponent("\(UUID().uuidString).json")
            do {
                try report.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                AppLog.caught(error, .storage, "report_store")
            }
        }
        // Oldest first out when over the cap.
        let files = storedFiles()
        if files.count > MetricKitReporter.maxStoredReports {
            for url in files.prefix(files.count - MetricKitReporter.maxStoredReports) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func uploadStored() async {
        guard !busy, !ScreenshotMode.isActive else { return }
        busy = true
        defer { busy = false }
        for url in storedFiles() {
            // Kept at most 7 days (API_V2.md).
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date.now.timeIntervalSince(modified) > 7 * 24 * 3600 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url), let gzipped = Gzip.compress(data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let result = await APIClient.shared.postDiagnostics("diagnostics/reports/", gzippedJSON: gzipped, diagSession: nil)
            switch result {
            case .accepted, .rejected:
                try? FileManager.default.removeItem(at: url)
                let status: Int
                if case .rejected(let code) = result { status = code } else { status = 200 }
                AppLog.info(.logging, "logging.report.sent", "Diagnostic report sent", ["kind": "metrickit", "count": 1, "status": .int(status)])
            case .retryAfter, .failed:
                AppLog.debug(.logging, "logging.upload.failed", "Diagnostic report kept for later", ["error": "deferred", "entries": 1])
                return
            }
        }
    }

    private func storedFiles() -> [URL] {
        guard let directory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}
