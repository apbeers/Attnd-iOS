// OnboardingView.swift
// Attnd (app and App Clip)
//
// The onboarding cards (shared spec §7): shown once after the first join on this device
// (AppState.pendingTour → ContentView), skippable, and again from Options → Tour. Never in
// screenshot mode.
//
//   1. What you can do: map, schedule, live updates, search, hearts.
//   2. Location: walk times, the compass arrow, what's nearby → the permission prompt.
//   3. Notifications (full app): set-time changes and reminders for hearts → the prompt.
//   4. "Plan your day", only when Apple Intelligence's on-device model is available
//      (`AppState.assistantAvailable`): example requests built from this event's tags and
//      categories (`OnboardingExamples`). For now each chip opens Ask with that text; the
//      planner (spec §6) will take them over.

import CoreLocation
import SwiftUI

// MARK: - Example requests (pure, unit tested)

enum OnboardingExamples {
    /// Up to four example requests for this event: "Plan my Saturday around live music and
    /// bbq" (its two most used tags, else location categories; the weekday of the first event
    /// day still ahead when the event lasts more than one day, otherwise "day"), "I've got 3
    /// hours, show me the highlights", "Kid-friendly afternoon" (only when a tag or category
    /// mentions kids or family) and "What's on near me right now?".
    static func prompts(_ bundle: EventBundle, now: Date, locale: Locale = Locale(identifier: "en_US")) -> [String] {
        var prompts: [String] = []
        let topics = topTopics(bundle, limit: 2)
        if !topics.isEmpty {
            let day = planDay(bundle, now: now, locale: locale)
            prompts.append("Plan my \(day) around \(topics.joined(separator: " and "))")
        }
        prompts.append("I've got 3 hours, show me the highlights")
        let words = allTopics(bundle).keys
        if words.contains(where: { $0.contains("kid") || $0.contains("family") || $0.contains("children") }) {
            prompts.append("Kid-friendly afternoon")
        }
        prompts.append("What's on near me right now?")
        return prompts
    }

    /// Tags of schedule items and locations by use (lower case, as sent); location categories
    /// only when there are no tags at all.
    static func allTopics(_ bundle: EventBundle) -> [String: Int] {
        var counts: [String: Int] = [:]
        for tag in bundle.schedule.flatMap(\.tags) + bundle.locations.flatMap(\.tags) {
            let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        if counts.isEmpty {
            for category in bundle.locations.compactMap(\.category) {
                let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty { counts[key, default: 0] += 1 }
            }
        }
        return counts
    }

    /// The most used topics: by count, then alphabetically.
    static func topTopics(_ bundle: EventBundle, limit: Int) -> [String] {
        allTopics(bundle)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    /// "Saturday" (the first event day from today on) for a multi-day event, else "day".
    static func planDay(_ bundle: EventBundle, now: Date, locale: Locale) -> String {
        let event = bundle.event
        let calendar = EventTimeFormat.calendar(in: event.timeZone)
        let starts = bundle.schedule.compactMap(\.startTime) + [event.startTime, event.endTime].compactMap { $0 }
        let days = Set(starts.map { calendar.startOfDay(for: $0) })
        guard days.count > 1 else { return "day" }
        let today = calendar.startOfDay(for: now)
        guard let day = days.filter({ $0 >= today }).min() ?? days.max() else { return "day" }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = event.timeZone
        style.locale = locale
        return day.formatted(style)
    }
}

// MARK: - Cards

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var page = 0
    @State private var locationAllowed = false
    @State private var isAskingLocation = false
    @State private var isAskingNotifications = false
    @State private var locationPermission = LocationPermissionManager()

    private enum Card: Hashable {
        case intro, location, notifications, plan
    }

    private var cards: [Card] {
        var cards: [Card] = [.intro, .location]
        if !AppState.isAppClip { cards.append(.notifications) }
        if AppState.assistantAvailable, !examples.isEmpty { cards.append(.plan) }
        return cards
    }

    private var examples: [String] {
        appState.currentBundle.map { OnboardingExamples.prompts($0, now: .now) } ?? []
    }

    var body: some View {
        let cards = self.cards
        NavigationStack {
            TabView(selection: $page) {
                ForEach(Array(cards.enumerated()), id: \.element) { index, card in
                    ScrollView {
                        cardView(card)
                            .frame(maxWidth: 520)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .safeAreaInset(edge: .bottom) {
                Button {
                    if page < cards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < cards.count - 1 ? "Next" : "Done")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.bottom, 12)
            }
            .navigationTitle(appState.currentEvent?.name ?? "Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", systemImage: "xmark", role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            // Seen (or skipped) once: not shown again by itself.
            appState.markTourSeen()
            locationAllowed = Self.hasLocationPermission
        }
    }

    @ViewBuilder
    private func cardView(_ card: Card) -> some View {
        switch card {
        case .intro:
            CardLayout(systemImage: "sparkles", title: "Your event, in your pocket") {
                FeatureRow(systemImage: "map", text: "Find every stage, stand and place on the map.")
                FeatureRow(systemImage: "calendar", text: "See what's on now and next, with live countdowns.")
                FeatureRow(systemImage: "bell", text: "Get the organizers' updates the moment they're sent.")
                FeatureRow(systemImage: "magnifyingglass", text: "Search everything with the button in the corner.")
                FeatureRow(systemImage: "heart", text: "Heart what you don't want to miss and follow it on your Lock Screen.")
            }
        case .location:
            CardLayout(systemImage: "location.north.line", title: "Find your way") {
                Text("With your location, Attnd shows how far each place is, which way to go and how long the walk takes. It stays on your iPhone.")
                    .foregroundStyle(.secondary)
                if locationAllowed {
                    Label("Location is on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task {
                            isAskingLocation = true
                            _ = await locationPermission.requestLocation()
                            locationAllowed = Self.hasLocationPermission
                            isAskingLocation = false
                        }
                    } label: {
                        Label("Allow Location", systemImage: "location")
                    }
                    .buttonStyle(.glass)
                    .disabled(isAskingLocation)
                }
            }
        case .notifications:
            CardLayout(systemImage: "bell.badge", title: "Don't miss a change") {
                Text("Get set-time changes and urgent news from the organizers, and a reminder 15 minutes before anything you've hearted.")
                    .foregroundStyle(.secondary)
                if appState.notificationsEnabled {
                    Label("Notifications are on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        Task {
                            isAskingNotifications = true
                            _ = await appState.setNotificationsEnabled(true)
                            isAskingNotifications = false
                        }
                    } label: {
                        Label("Turn On Notifications", systemImage: "bell")
                    }
                    .buttonStyle(.glass)
                    .disabled(isAskingNotifications)
                }
            }
        case .plan:
            CardLayout(systemImage: "wand.and.stars", title: "Plan your day") {
                Text("Ask in your own words. Apple Intelligence answers on your iPhone from the event's own schedule.")
                    .foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button {
                        // Opens Ask with the example (the search sheet replaces this one).
                        appState.showSearch(example, ask: true)
                    } label: {
                        Label(example, systemImage: "sparkles")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private static var hasLocationPermission: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }
}

private struct CardLayout<Content: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
    }
}
