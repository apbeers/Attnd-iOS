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
            hasPlan: !mySchedule.isEmpty,
            hasLikes: !mySchedule.isEmpty
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
    @State private var width: CGFloat = 0

    /// Two columns from this container width (the inner display of an unfolded iPhone Duo).
    static let twoColumnWidth: CGFloat = 700
    /// Parts that keep the whole width in two-column mode.
    static let fullWidth: Set<String> = ["header", "urgent", "countdown", "now_next"]

    var body: some View {
        let sections = appState.screenSections(.home, now: now) { bundle, state in
            ScreenFacts.event(bundle, state)
        }
        ScrollView {
            if width >= Self.twoColumnWidth {
                // Wide (iPhone Duo unfolded): the full-width parts, then two columns of sections.
                let wide = sections.filter { Self.fullWidth.contains($0.type) }
                let rest = sections.filter { !Self.fullWidth.contains($0.type) }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(wide, id: \.type) { section in
                        ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)],
                              alignment: .leading, spacing: 16) {
                        ForEach(rest, id: \.type) { section in
                            ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.type) { section in
                        ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        // Columns follow the container's width (never the device).
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The last section scrolls clear of the floating button and the tab bar, like the other tabs.
        .contentMargins(.bottom, 88, for: .scrollContent)
        .refreshable { await appState.pullToRefresh() }
    }
}

/// A screen component (Home's sections, and the same components in chat answers), drawn in the
/// Home tab's style. Reached through `ComponentView`.
struct ScreenComponentView: View {
    let component: Component
    let now: Date
    let open: (SearchTarget) -> Void

    @Environment(AppState.self) private var appState

    private var section: Component { component }

    var body: some View {
        switch component.type {
        case "header": header
        case "urgent": urgent
        case "my_schedule":
            MyScheduleUpNext(now: now, title: section.title, limit: section.limit ?? 5, open: open)
        case "my_day":
            MyScheduleDay(now: now, title: section.title, open: open)
        case "whats_on": whatsOn
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
        case "menu": menu
        case "hours":
            textCard(section.title ?? "Hours", appState.location(id: subjectId(.location))?.context?.hours ?? "")
        case "performers": performers
        case "amenities": amenities
        case "accessibility":
            textCard(section.title ?? "Accessibility", appState.currentEvent?.context?.accessibility ?? "")
        case "policies":
            textCard(section.title ?? "Policies", appState.currentEvent?.context?.policies ?? "")
        case "weather_plan":
            textCard(section.title ?? "Weather Plan", appState.currentEvent?.context?.weatherPlan ?? "")
        case "now_playing":
            NowNextStrip()
        case "map":
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "Map")
                MiniMap(pins: Array(appState.locations.filter { $0.coordinate != nil }.prefix(MiniMap.maxPins)), showsUser: false)
            }
        case "countdown":
            countdown
        case "now_next":
            NowNextStrip(locationId: section.subject.flatMap { $0.kind == .location ? $0.id : nil })
        default:
            // Unknown, or a detail-screen-only part (`ask_about` draws nothing since Nov 21, 2026).
            EmptyView()
        }
    }

    private func subjectId(_ kind: RefKind) -> Int? {
        section.subject.flatMap { $0.kind == kind ? $0.id : nil }
    }

    /// A place's menu (API-018), in a card.
    @ViewBuilder
    private var menu: some View {
        if let location = appState.location(id: subjectId(.location)), let entries = location.context?.menu, !entries.isEmpty {
            MenuList(menu: Array(entries.prefix(section.limit ?? entries.count)), title: section.title ?? "Menu · \(location.name)")
                .blockCardBackground()
        }
    }

    /// An item's performers with their genres and the start of their bio.
    @ViewBuilder
    private var performers: some View {
        if let item = appState.currentBundle?.scheduleItem(subjectId(.schedule)), let list = item.context?.performers, !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? (list.count == 1 ? "Performer" : "Performers"))
                ForEach(list, id: \.self) { performer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(performer.name).font(.headline)
                        if !performer.genres.isEmpty {
                            Text(TagText.line(performer.genres)).font(.caption).foregroundStyle(.tint)
                        }
                        if !performer.bio.isEmpty {
                            Text(performer.bio).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            .blockCardBackground()
        }
    }

    /// The event's amenities with the place they are at.
    @ViewBuilder
    private var amenities: some View {
        let entries = appState.currentEvent?.context?.amenities ?? []
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: section.title ?? "Amenities")
                ForEach(Array(entries.prefix(section.limit ?? 12)), id: \.self) { amenity in
                    let place = appState.location(id: amenity.locationId)
                    Button {
                        if let place { open(.location(place.id)) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(amenity.name).foregroundStyle(.primary)
                                if let place {
                                    Text(place.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: amenity.kind.systemImage)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(place == nil)
                }
            }
            .blockCardBackground()
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

}

// MARK: - Up next in my schedule

/// Home's "Up next in my schedule" (and the chat's `my_schedule`): the next 3–5 upcoming
/// entries as cards with time, place and walk, in the Home carousel's style; an empty state
/// otherwise. Replaces the Liked carousel and "Your Plan Today".
struct MyScheduleUpNext: View {
    let now: Date
    var title: String? = nil
    var limit = 5
    var open: ((SearchTarget) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        let rows = appState.currentBundle.map { appState.mySchedule.upNext($0, now: now, limit: min(max(limit, 3), 5)) } ?? []
        VStack(alignment: .leading, spacing: 8) {
            BlockTitle(title: title ?? "Up Next in My Schedule")
            if rows.isEmpty {
                Label(MyScheduleText.empty, systemImage: "calendar.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .blockCardBackground()
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(rows) { row in
                            card(row)
                                .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func card(_ row: MyScheduleRow) -> some View {
        let select: () -> Void = { if let open { open(row.target) } else { appState.open(row.target) } }
        switch row.entry.kind {
        case .item:
            if let item = appState.currentBundle?.scheduleItem(row.entry.id) {
                ItemCard(item: item, show: [.time, .place, .image, .distance, .like], onOpen: select)
            }
        case .place:
            if let location = appState.location(id: row.entry.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(EventTimeFormat.range(start: row.start, end: row.end, in: appState.timeZone, now: now), systemImage: "clock")
                        .font(.subheadline.bold())
                        .foregroundStyle(.tint)
                    PlaceCard(location: location, show: [.image, .distance, .like], onOpen: select)
                }
            }
        }
    }
}

// MARK: - The day in My schedule (chat)

/// "Your Day": the planned day as the plan's timeline (walks, meals) when there is a plan, else
/// My schedule's next day with entries as a list (time, name, place, walk) with each entry's
/// button; empty state otherwise. The My plan chat opens with it.
struct MyScheduleDay: View {
    let now: Date
    var title: String? = nil
    var open: ((SearchTarget) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockTitle(title: title ?? "Your Day")
            if appState.planner.hasPlan {
                AssistantPlanView(day: nil, showsHeader: false)
            } else if let bundle = appState.currentBundle {
                let rows = dayRows(bundle)
                if rows.isEmpty {
                    Label(MyScheduleText.empty, systemImage: "calendar.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .blockCardBackground()
    }

    /// Today's rows that haven't ended, else the next day with any.
    private func dayRows(_ bundle: EventBundle) -> [MyScheduleRow] {
        let upcoming = appState.mySchedule.rows(bundle, now: now).filter { !$0.ended }
        guard let first = upcoming.first else { return [] }
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let day = PlanDate(first.start, in: calendar)
        return upcoming.filter { PlanDate($0.start, in: calendar) == day }
    }

    private func rowView(_ row: MyScheduleRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(EventTimeFormat.time(row.start, in: appState.timeZone))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.tint)
                .frame(minWidth: 64, alignment: .leading)
            Button {
                if let open { open(row.target) } else { appState.open(row.target) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline).foregroundStyle(.primary)
                    if let place = row.placeName, place != row.name {
                        Text(place).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HeartButton(target: row.target, font: .subheadline)
        }
    }
}
