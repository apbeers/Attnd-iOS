// WeatherStore.swift
// Attnd (app target only — not in the App Clip)
//
// The plan page's weather (WeatherKit, planner_view_spec §4) and the on-device day summaries:
//   - `WeatherStore` (`AppState.weather`): the daily + hourly forecast for the event's place
//     (`PlanWeather.coordinate`: the event's coordinate, else its locations' centre), fetched
//     with `WeatherService.shared.weather(for:including: .daily, .hourly)` while the plan page is
//     shown and at most once an hour (`PlanWeather.needsFetch`). The last forecast is kept on
//     disk per event (`Application Support/attnd-weather/<event id>.json`, excluded from backup),
//     so it shows offline with "as of 2:14 PM". Apple's attribution (the Apple Weather mark,
//     light and dark, and the legal page link) is fetched with it and its images cached in the
//     same folder; `WeatherAttributionView` shows them wherever weather is shown. Failures
//     (offline, WeatherKit unavailable) keep the cached forecast and are logged with
//     `AppLog.caught` (`error.caught`).
//   - `PlanSummaryStore` (`AppState.daySummaries`): the plan page's one-line day summary + "Read
//     more", written by Foundation Models (`EventAssistant.daySummary`) from
//     `PlanPage.summaryPrompt`, cached on disk per (plan version, day) — `PlanPage.summaryKey` —
//     in `Application Support/attnd-weather/summaries-<event id>.json`; without the model or when
//     it fails, `PlanPage.fallbackSummary`.
// Nothing here runs in screenshot mode or without the on-device model's plan page.

import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit
import WeatherKit

@MainActor
@Observable
final class WeatherStore {
    /// The current event's last forecast (from disk or WeatherKit).
    private(set) var forecast: PlanForecast?
    /// The Apple Weather mark (cached images) and the legal page.
    private(set) var markLight: UIImage?
    private(set) var markDark: UIImage?
    private(set) var legalURL: URL?

    @ObservationIgnored private var eventId: Int?
    @ObservationIgnored private var fetching = false

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-weather", isDirectory: true)
    }

    private static func file(_ name: String) -> URL? {
        guard let directory else { return nil }
        StorageDirectory.prepare(directory)
        return directory.appendingPathComponent(name)
    }

    /// The event's cached forecast and attribution (on join, restore, switch).
    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        forecast = eventId.flatMap { id in Self.file("\(id).json").flatMap { try? Data(contentsOf: $0) } }
            .flatMap(PlanForecast.decode)
        markLight = Self.file("mark-light.png").flatMap { UIImage(contentsOfFile: $0.path) }
        markDark = Self.file("mark-dark.png").flatMap { UIImage(contentsOfFile: $0.path) }
        legalURL = Self.file("legal.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(URL.init(string:))
    }

    /// Leaving an event: its forecast is deleted with the bundle.
    func delete(eventId: Int) {
        if let url = Self.file("\(eventId).json") { try? FileManager.default.removeItem(at: url) }
        if let url = Self.file("summaries-\(eventId).json") { try? FileManager.default.removeItem(at: url) }
        if self.eventId == eventId { forecast = nil }
    }

    /// Fetches a new forecast when the cached one is missing, for another place or an hour old.
    func refreshIfNeeded(_ bundle: EventBundle) async {
        guard !ScreenshotMode.isActive, !fetching, let point = PlanWeather.coordinate(bundle) else { return }
        let eventId = bundle.event.id
        if self.eventId != eventId { load(eventId: eventId) }
        guard PlanWeather.needsFetch(forecast, at: point, now: .now) else { return }
        fetching = true
        defer { fetching = false }
        do {
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let (daily, hourly) = try await WeatherService.shared.weather(for: location, including: .daily, .hourly)
            let calendar = PlanCalendar.calendar(bundle.event.timeZone)
            let days = daily.forecast.map { day in
                PlanDayForecast(
                    // A day's `date` is its start in the place's zone: noon-ish lands on the right day.
                    date: PlanDate(day.date.addingTimeInterval(6 * 3600), in: calendar).description,
                    high: day.highTemperature.converted(to: .celsius).value,
                    low: day.lowTemperature.converted(to: .celsius).value,
                    precipitationChance: day.precipitationChance,
                    symbol: day.symbolName,
                    condition: day.condition.description
                )
            }
            let hours = hourly.forecast.prefix(240).map { hour in
                PlanHourForecast(date: hour.date, temperature: hour.temperature.converted(to: .celsius).value,
                                 precipitationChance: hour.precipitationChance, symbol: hour.symbolName)
            }
            let fresh = PlanForecast(eventId: eventId, fetchedAt: .now, latitude: point.latitude, longitude: point.longitude,
                                     days: days, hours: Array(hours))
            guard self.eventId == eventId else { return }
            forecast = fresh
            if let data = fresh.encoded(), let url = Self.file("\(eventId).json") { try? data.write(to: url, options: .atomic) }
            await refreshAttribution()
        } catch {
            AppLog.caught(error, .planner, "weather", level: .notice)
        }
    }

    /// The Apple Weather mark (light + dark) and the legal link, cached for offline use.
    private func refreshAttribution() async {
        do {
            let attribution = try await WeatherService.shared.attribution
            legalURL = attribution.legalPageURL
            if let url = Self.file("legal.txt") { try? attribution.legalPageURL.absoluteString.write(to: url, atomically: true, encoding: .utf8) }
            if let image = await Self.download(attribution.combinedMarkLightURL, to: "mark-light.png") { markLight = image }
            if let image = await Self.download(attribution.combinedMarkDarkURL, to: "mark-dark.png") { markDark = image }
        } catch {
            AppLog.caught(error, .planner, "weather_attribution", level: .notice)
        }
    }

    private static func download(_ url: URL, to name: String) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            if let file = file(name) { try? data.write(to: file, options: .atomic) }
            return image
        } catch {
            AppLog.caught(error, .planner, "weather_mark", level: .notice)
            return nil
        }
    }

    /// The forecast lines for the on-device model (empty without a forecast).
    func promptLines(_ bundle: EventBundle) -> [String] {
        guard forecast?.eventId == bundle.event.id else { return [] }
        return PlanWeather.promptLines(
            forecast, days: PlanCalendar.eventDays(bundle, now: .now),
            zone: bundle.event.timeZone, fahrenheit: Self.usesFahrenheit, locale: .current
        )
    }

    /// °F where the locale's temperature unit is Fahrenheit (US and a few others).
    static var usesFahrenheit: Bool {
        Locale.current.measurementSystem == .us
    }
}

/// The Apple Weather mark and the legal link (required wherever weather shows).
struct WeatherAttributionView: View {
    let store: WeatherStore
    var asOf: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if let mark = colorScheme == .dark ? store.markDark ?? store.markLight : store.markLight ?? store.markDark {
                Image(uiImage: mark)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 12)
                    .accessibilityLabel("Apple Weather")
            } else {
                Text("\u{F8FF} Weather")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel("Apple Weather")
            }
            if let legal = store.legalURL {
                Link("Legal", destination: legal)
                    .font(.caption2)
            }
            if let asOf {
                Text(asOf)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Day summaries

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
            .appendingPathComponent("attnd-weather", isDirectory: true) else { return nil }
        StorageDirectory.prepare(directory)
        return directory.appendingPathComponent("summaries-\(eventId).json")
    }

    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        working = []
        summaries = eventId.flatMap(Self.file).flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Summary].self, from: $0) } ?? [:]
    }

    /// The day's summary: the cached one, else the fallback while (once) the model writes one.
    func summary(_ plan: Plan, _ date: PlanDate, _ bundle: EventBundle, forecast: String?, modelAvailable: Bool) -> Summary {
        let key = PlanPage.summaryKey(plan, date)
        if let cached = summaries[key] { return cached }
        let fallback = Summary(line: PlanPage.fallbackSummary(plan, date, timeZone: bundle.event.timeZone, locale: .current),
                               more: "", generated: false)
        guard modelAvailable, !working.contains(key) else { return fallback }
        working.insert(key)
        let prompt = PlanPage.summaryPrompt(plan, date, bundle, forecast: forecast, locale: .current)
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

    private func store(_ key: String, _ summary: Summary, eventId: Int) {
        summaries[key] = summary
        if summaries.count > Self.maxStored {
            // Keys for the same day differ by plan version: keep the newest written (arbitrary order is fine).
            for old in summaries.keys.filter({ $0 != key }).prefix(summaries.count - Self.maxStored) { summaries[old] = nil }
        }
        if let data = try? JSONEncoder().encode(summaries), let url = Self.file(eventId) { try? data.write(to: url, options: .atomic) }
    }
}
