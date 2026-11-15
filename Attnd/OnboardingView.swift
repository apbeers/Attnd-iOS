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
//      (`AppState.plannerAvailable`; never in the App Clip): example requests built from this
//      event's tags (`PlanRequest.examples`, the same as Android's). A plan chip makes the plan
//      and opens Schedule → My plan (spec §6); the question chip opens Ask with it.

import CoreLocation
import SwiftUI

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
        if hasPlanCard { cards.append(.plan) }
        return cards
    }

    private var hasPlanCard: Bool {
        #if APP_CLIP
        return false
        #else
        return AppState.plannerAvailable && !examples.isEmpty
        #endif
    }

    #if !APP_CLIP
    private var examples: [PlanExample] {
        appState.currentBundle.map { PlanRequest.examples($0, now: .now) } ?? []
    }
    #endif

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
                FeatureRow(systemImage: "heart", text: "Like what you don't want to miss and follow it on your Lock Screen.")
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
                Text("Get set-time changes and urgent news from the organizers, and a reminder 15 minutes before anything you've liked.")
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
            planCard
        }
    }

    @ViewBuilder
    private var planCard: some View {
        #if !APP_CLIP
        CardLayout(systemImage: "wand.and.stars", title: "Plan your day") {
            Text("Say what you'd like in your own words. Apple Intelligence builds a plan on your iPhone from the event's schedule, your likes and walking times.")
                .foregroundStyle(.secondary)
            ForEach(examples) { example in
                Button {
                    // A plan opens Schedule → My plan, the question opens Ask (either replaces this sheet).
                    appState.useExample(example)
                } label: {
                    Label(example.text, systemImage: example.isPlan ? "sparkles" : "bubble.left")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        #endif
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
