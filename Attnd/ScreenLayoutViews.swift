// ScreenLayoutViews.swift
// Attnd (app and App Clip)
//
// API-024 server-driven screens, the SwiftUI side of `ScreenLayout.swift`:
//   - `AppState.screenSections(_:now:subject:facts:)`: the sections a screen draws, from the
//     bundle's layout (never in screenshot mode: `AppState.screenLayouts` is nil there) or the
//     built-in default. The detail screens (`ScheduleItemDetailView`, `LocationDetailView`), the
//     event's info (`EventInfoView`), Options' event rows and the map's overlay call it and draw
//     each section with their own pieces, so with the built-in layouts they look as before.
//   - `HomeTab`: the Home tab (`display.tabs` lists `home`), nothing but the `home` layout's
//     sections, drawn with the assistant's component library (`Components/`): the event header,
//     the urgent announcement, a countdown to the gates, now / next, the plan (with the on-device
//     model), liked things, what's on, a map preview, places, updates, FAQ, getting there, about,
//     links, the flyer and the website. Taps push the detail on Home's own stack.

import SwiftUI

extension AppState {
    /// What the layout conditions read beyond the bundle.
    func screenFactsState(now: Date) -> ScreenFacts.State {
        ScreenFacts.State(
            now: now,
            modelAvailable: hasAssistant,
            hasPlan: hasAssistant && !(planner.plan?.isEmpty ?? true),
            hasLikes: !likeSet.isEmpty
        )
    }

    /// The sections `screen` draws for a subject, in order (rules in `ScreenLayout.resolve`).
    func screenSections(
        _ screen: LayoutScreen,
        now: Date,
        subject: ScreenLayout.Subject = .empty,
        facts: (EventBundle, ScreenFacts.State) -> Set<String>
    ) -> [LayoutSection] {
        guard let bundle = currentBundle else { return [] }
        return ScreenLayout.resolve(screen, layouts: screenLayouts, facts: facts(bundle, screenFactsState(now: now)), subject: subject)
    }
}

// MARK: - Home tab

struct HomeTab: View {
    @Environment(AppState.self) private var appState
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HomeScreen(now: context.date) { target in
                    path.append(target)
                }
            }
            .navigationTitle(appState.currentEvent?.name ?? "Home")
            .navigationBarTitleDisplayMode(.inline)
            .eventStatusBanners()
            .optionsToolbarItem(for: .home)
            .navigationDestination(for: SearchTarget.self) { target in
                SearchDestinationView(target: target)
            }
            .navigationDestination(for: Location.self) { location in
                LocationDetailView(location: appState.location(id: location.id) ?? location)
            }
            .navigationDestination(for: ScheduleItem.self) { item in
                ScheduleItemDetailView(item: appState.schedule.first { $0.id == item.id } ?? item)
            }
        }
    }
}

private struct HomeScreen: View {
    let now: Date
    let open: (SearchTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let sections = appState.screenSections(.home, now: now) { bundle, state in
            ScreenFacts.event(bundle, state)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.type) { section in
                    HomeSection(section: section, now: now, open: open)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .refreshable { await appState.pullToRefresh() }
    }
}

/// One section of the Home tab.
private struct HomeSection: View {
    let section: LayoutSection
    let now: Date
    let open: (SearchTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        switch section.type {
        case "header": header
        case "urgent": urgent
        case "countdown": countdown
        case "now_next":
            NowNextStrip()
        case "plan_today":
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "Your Plan Today")
                AssistantPlanView(day: nil, showsHeader: false, limit: section.limit ?? 4)
                Button("Open My Plan", systemImage: "sparkles") { appState.openPlanPage() }
                    .buttonStyle(.bordered)
            }
        case "liked":
            CardCarousel(targets: Array(likedTargets.prefix(section.limit ?? 8)), title: section.title ?? "Liked", onSelect: open)
        case "whats_on": whatsOn
        case "map":
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "Map")
                MiniMap(pins: Array(appState.locations.filter { $0.coordinate != nil }.prefix(MiniMap.maxPins)), showsUser: false)
            }
        case "places":
            CardCarousel(targets: appState.locations.prefix(section.limit ?? 8).map { SearchTarget.location($0.id) },
                         title: section.title ?? "Places", onSelect: open)
        case "updates":
            CompactList(targets: appState.notifications.prefix(section.limit ?? 3).map { SearchTarget.notification($0.id) },
                        title: section.title ?? "Latest Updates", onSelect: open)
                .blockCardBackground()
        case "faq": faq
        case "getting_there":
            textCard(section.title ?? "Getting There", appState.currentEvent?.context?.gettingThere ?? "")
        case "about": about
        case "links": links
        case "flyer":
            if let flyer = appState.currentEvent?.flyerUrl {
                Gallery(images: [GalleryImage.flyer(flyer)], title: section.title ?? "Flyer")
            }
        case "website":
            if let website = appState.currentEvent?.websiteUrl {
                EventWebsiteLink(url: website)
                    .blockCardBackground()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let event = appState.currentEvent {
            EventHeader(event: event, logoUrl: appState.logoUrl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blockCardBackground()
        }
    }

    /// The newest urgent announcement of the last 12 hours (API-011).
    @ViewBuilder
    private var urgent: some View {
        let recent = appState.notifications
            .filter { $0.isUrgent && ($0.sendTime.map { now.timeIntervalSince($0) < 12 * 3600 } ?? false) }
            .max { ($0.sendTime ?? .distantPast) < ($1.sendTime ?? .distantPast) }
        if let recent {
            UpdateCard(notification: recent, onOpen: { open(.notification(recent.id)) })
        }
    }

    /// Until the gates open: "Starts in 2:14:05" and the start in the event's zone.
    @ViewBuilder
    private var countdown: some View {
        if let start = appState.currentEvent?.startTime, start > now {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title ?? "Starts In").font(.caption.bold()).foregroundStyle(.secondary)
                Text(timerInterval: now...start, countsDown: true)
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                Text(EventTimeFormat.dateTime(start, in: appState.timeZone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .blockCardBackground()
        }
    }

    /// Items on now and next (≤ `limit`, 6 by default).
    @ViewBuilder
    private var whatsOn: some View {
        let items = appState.schedule
            .filter { item in
                guard item.startTime != nil else { return false }
                return !ScheduleTiming.hasEnded(item, at: now)
            }
            .prefix(section.limit ?? 6)
        if !items.isEmpty {
            ItemTimeline(items: Array(items), title: section.title ?? "What's On", onSelect: { item in
                open(.scheduleItem(item.id))
            })
            .blockCardBackground()
        }
    }

    @ViewBuilder
    private var faq: some View {
        let entries = appState.currentEvent?.context?.faq ?? []
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "FAQ")
                ForEach(Array(entries.prefix(section.limit ?? 3)), id: \.self) { entry in
                    DisclosureGroup(entry.question) {
                        Text(entry.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if entries.count > (section.limit ?? 3) {
                    if let eventId = appState.currentEvent?.id {
                        Button("All Questions") { open(.event(eventId)) }
                            .font(.subheadline)
                    }
                }
            }
            .blockCardBackground()
        }
    }

    @ViewBuilder
    private var about: some View {
        let event = appState.currentEvent
        let text = [event?.description ?? "", event?.context?.about ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        textCard(section.title ?? "About", text)
    }

    @ViewBuilder
    private var links: some View {
        let entries = appState.currentEvent?.context?.links ?? []
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "Links")
                ForEach(entries, id: \.url) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "safari")
                    }
                }
            }
            .blockCardBackground()
        }
    }

    @ViewBuilder
    private func textCard(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                BlockTitle(title: title)
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .blockCardBackground()
        }
    }

    /// Liked schedule items in time order, then liked places (`EventPersonalState.heartedTargets`).
    private var likedTargets: [SearchTarget] {
        guard let bundle = appState.currentBundle else { return [] }
        return appState.personal.heartedTargets(in: bundle)
    }
}
