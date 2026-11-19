// PlanSummaryStore.swift
// Attnd (app + App Clip)
//
// The plan page's one-line day summaries + "Read more" (`AppState.daySummaries`), written by
// Foundation Models (`EventAssistant.daySummary`) from `PlanPage.summaryPrompt`, cached on disk
// per (plan version, day) — `PlanPage.summaryKey` — in
// `Application Support/attnd-plan/summaries-<event id>.json` (excluded from backup); without the
// model or when it fails, `PlanPage.fallbackSummary`. Nothing here runs in screenshot mode or
// without the on-device model's plan page.

import Foundation
import Observation

@MainActor
@Observable
final class PlanSummaryStore {
    struct Summary: Codable, Hashable, Sendable {
        var line: String
        var more: String
        /// Written by the on-device model (false: the plain fallback, not stored).
        var generated: Bool
    }

    /// Summary key (`PlanPage.summaryKey`) → summary, for the current event.
    private(set) var summaries: [String: Summary] = [:]

    @ObservationIgnored private var eventId: Int?
    @ObservationIgnored private var working: Set<String> = []
    /// Kept per event: the newest 40 days' summaries.
    private static let maxStored = 40

    private static func file(_ eventId: Int) -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-plan", isDirectory: true) else { return nil }
        StorageDirectory.prepare(directory)
        return directory.appendingPathComponent("summaries-\(eventId).json")
    }

    func load(eventId: Int?) {
        Self.removeOldWeatherFolder()
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        working = []
        summaries = eventId.flatMap(Self.file).flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Summary].self, from: $0) } ?? [:]
    }

    /// The day's summary: the cached one, else the fallback while (once) the model writes one.
    func summary(_ plan: Plan, _ date: PlanDate, _ bundle: EventBundle, modelAvailable: Bool) -> Summary {
        let key = PlanPage.summaryKey(plan, date)
        if let cached = summaries[key] { return cached }
        let fallback = Summary(line: PlanPage.fallbackSummary(plan, date, timeZone: bundle.event.timeZone, locale: .current),
                               more: "", generated: false)
        guard modelAvailable, !working.contains(key) else { return fallback }
        working.insert(key)
        let prompt = PlanPage.summaryPrompt(plan, date, bundle, locale: .current)
        let eventId = bundle.event.id
        Task { [weak self] in
            do {
                let reply = try await EventAssistant.daySummary(prompt)
                guard let self, self.eventId == eventId, !reply.line.isEmpty else { return }
                self.store(key, Summary(line: reply.line, more: reply.more, generated: true), eventId: eventId)
            } catch {
                AppLog.caught(error, .planner, "day_summary", level: .notice)
            }
        }
        return fallback
    }

    /// Builds before Nov 19, 2026 kept a WeatherKit forecast and these summaries in
    /// `attnd-weather/`; weather is gone, so the old folder is deleted once.
    private static var removedOldFolder = false
    private static func removeOldWeatherFolder() {
        guard !removedOldFolder else { return }
        removedOldFolder = true
        guard let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-weather", isDirectory: true),
              FileManager.default.fileExists(atPath: old.path) else { return }
        try? FileManager.default.removeItem(at: old)
    }

    private func store(_ key: String, _ summary: Summary, eventId: Int) {
        summaries[key] = summary
        if summaries.count > Self.maxStored {
            // Keys for the same day differ by plan version: keep the newest written (arbitrary order is fine).
            for old in summaries.keys.filter({ $0 != key }).prefix(summaries.count - Self.maxStored) { summaries[old] = nil }
        }
        if let data = try? JSONEncoder().encode(summaries), let url = Self.file(eventId) { try? data.write(to: url, options: .atomic) }
    }
}
