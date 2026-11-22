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
import UIKit

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

extension AppState {
    /// A screen's sections before the facts decide visibility (catalogue 2's tab screens have no
    /// built-in default: empty = today's screen).
    func layoutSections(_ screen: LayoutScreen) -> [LayoutSection] {
        ScreenLayout.sections(for: screen, layouts: screenLayouts)
    }

    /// The Schedule / Places tabs' layout (API-027), nil = today's screen.
    var scheduleTabLayout: TabListLayout? { TabListLayout.schedule(layoutSections(.scheduleTab)) }
    var placesTabLayout: TabListLayout? { TabListLayout.places(layoutSections(.placesTab)) }

    /// The organizer placed the update banner as a section on this screen: the fixed banner
    /// above the tab stays away (catalogue 2).
    func placesUpdateBanner(on screen: LayoutScreen) -> Bool {
        layoutSections(screen).contains { $0.type == "update_banner" }
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
            // No navigation bar on Home's root (owner, Nov 21, 2026): the content starts under the
            // status bar; the header shows the event's name and, when Home is the Options tab, a
            // gear. The title stays for the Back buttons of pushed details, which keep their bar.
            .navigationTitle(appState.currentEvent?.name ?? "Home")
            .toolbar(.hidden, for: .navigationBar)
            .eventStatusBanners()
            .navigationDestination(for: SearchTarget.self) { target in
                SearchDestinationView(target: target)
            }
            .navigationDestination(for: Location.self) { location in
                LocationDetailView(location: appState.location(id: location.id) ?? location)
            }
            .navigationDestination(for: HeartedListRoute.self) { route in
                HeartedListView(savedPlacesOnly: route.savedPlacesOnly)
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
        GeometryReader { proxy in
            let posture = FoldPosture.of(container: proxy.size, folds: ReservedRegionReader.folds(in: proxy))
            if case .tabletop(let foldMinY, let foldMaxY) = posture, !ScreenshotMode.isActive {
                // Tabletop (iPhone Duo partly folded, batch 7 fix round): the top half a glance
                // that never scrolls (Now / Next big, the countdown, the urgent announcement), the
                // bottom half the rest of Home as a list, or the "at the event" controls. Both halves
                // stop at the reported fold (`.division`), so nothing sits on it.
                let bottom = sections.filter { !TabletopSplit.glanceTypes.contains($0.type) }
                VStack(spacing: 0) {
                    TabletopGlanceView(now: now, large: appState.tabletopAtEventMode, open: open)
                        .frame(height: max(foldMinY, 0))
                        .clipped()
                    Spacer(minLength: 0).frame(height: max(foldMaxY - foldMinY, 0))
                    if appState.tabletopAtEventMode {
                        TabletopControls(now: now, open: open)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                if TabletopGlance.shouldOffer(
                                    live: TabletopGlance.isLive(eventStart: appState.currentEvent?.startTime,
                                                                eventEnd: appState.currentEvent?.endTime,
                                                                schedule: appState.schedule, now: now),
                                    alreadyOffered: appState.tabletopModeOffered,
                                    modeOn: appState.tabletopAtEventMode) {
                                    TabletopOfferCard()
                                }
                                ForEach(bottom, id: \.type) { section in
                                    ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }
                        .scrollPosition(id: $topSection, anchor: .top)
                        .contentMargins(.bottom, 88, for: .scrollContent)
                    }
                }
            } else {
                scroll(sections)
                    .onAppear { foldSplit = Self.split(proxy) }
                    .onChange(of: proxy.size) { foldSplit = Self.split(proxy) }
            }
        }
    }

    /// A vertical fold across the middle: the leading column ends at the fold (minus the page
    /// padding), the gap is the fold itself.
    struct FoldSplit: Equatable { var leadingWidth: CGFloat; var gap: CGFloat }
    @State private var foldSplit: FoldSplit?

    private static func split(_ proxy: GeometryProxy) -> FoldSplit? {
        guard let fold = ReservedRegionReader.folds(in: proxy).first(where: { $0.height > $0.width }),
              fold.minX > 0, fold.maxX < proxy.size.width else { return nil }
        return FoldSplit(leadingWidth: fold.minX, gap: fold.width + 32)
    }

    /// One of the wide layout's columns (not lazy: both columns measure fully, nothing starts cut).
    private func homeColumn(_ sections: [LayoutSection]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections, id: \.type) { section in
                ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
            }
        }
    }

    private func column(_ sections: [LayoutSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(sections, id: \.type) { section in
                ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// The section at the top of the list, kept across fold / unfold / tabletop (the scroll view
    /// is rebuilt when the layout changes; it comes back at the same section).
    @State private var topSection: String?

    private func scroll(_ sections: [LayoutSection]) -> some View {
        ScrollView {
            if width >= Self.twoColumnWidth {
                // Wide (iPhone Duo unfolded): the full-width parts, then two columns of sections.
                let wide = sections.filter { Self.fullWidth.contains($0.type) }
                let rest = sections.filter { !Self.fullWidth.contains($0.type) }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(wide, id: \.type) { section in
                        ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                    }
                    // Two independent columns, both from the top (batch 7: a grid paired the
                    // sections row by row, so a tall one pushed its neighbour down), split on the
                    // fold when the system reports one.
                    let columns = HomeColumns.split(rest)
                    HStack(alignment: .top, spacing: 0) {
                        homeColumn(columns.leading)
                            .frame(width: foldSplit.map { max($0.leadingWidth - 32, 0) }, alignment: .topLeading)
                            .frame(maxWidth: foldSplit == nil ? .infinity : nil, alignment: .topLeading)
                        Color.clear.frame(width: foldSplit?.gap ?? 16)
                        homeColumn(columns.trailing)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.type) { section in
                        ComponentView(component: ComponentCatalogue.component(section), now: now, open: open)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        .scrollPosition(id: $topSection, anchor: .top)
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
        case "update_banner":
            // Catalogue 2: the newest unread update of the last day, where the organizer put it.
            if let notification = appState.latestUpdateBanner() {
                LatestUpdateBanner(notification: notification)
            }
        case "status":
            // The Demo / Event ended badges stay the fixed ones (`eventStatusBanners`).
            EmptyView()
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
                        if let url = performer.appleMusicURL {
                            ListenOnAppleMusicButton(url: url, artist: performer.name)
                                .padding(.top, 2)
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

    /// No card (owner, Nov 21, 2026): the event's name as a title and one small line, the day and
    /// the place ("Sat Nov 21 · Panther Island, Fort Worth"). The code stays in Options.
    @ViewBuilder
    private var header: some View {
        if let event = appState.currentEvent {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    // Home without its bar: Options as a small gear when Home is the Options tab.
                    if appState.optionsTab == .home, appState.selectedTab == .home {
                        Button {
                            appState.presentedSheet = .options
                        } label: {
                            Label("Options", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if let line = HomeHeaderText.line(event) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The newest urgent announcement of the last 12 hours (API-011) that wasn't dismissed:
    /// compact (title, one line of body, the time on the title's line); swipe it away (Undo).
    @ViewBuilder
    private var urgent: some View {
        if let recent = UpdatesInbox.urgent(appState.notifications, dismissed: appState.personal.dismissedUrgentIds, now: now) {
            SwipeAwayUrgentCard(notification: recent, open: { open(.notification(recent.id)) })
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
        let text = AboutText.merged(description: event?.description ?? "", about: event?.context?.about)
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
                    // Not lazy (≤ 5 cards): the row is as tall as its tallest card, all cards that height.
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(rows) { row in
                            card(row)
                                .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            // Places saved without a time aren't in Up next: one small row for them.
            let saved = appState.mySchedule.savedPlaceIds.count
            if saved > 0 {
                NavigationLink(value: HeartedListRoute(savedPlacesOnly: true)) {
                    HStack {
                        Label(saved == 1 ? "1 saved place" : "\(saved) saved places", systemImage: "heart")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        // Drag between panes (iPhone Duo unfolded): a set or place dropped here is added (Undo).
        .padding(dropTargeted ? 6 : 0)
        .background {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .dropDestination(for: String.self) { strings, _ in
            guard let payload = strings.lazy.compactMap(DragPayload.parse).first else { return false }
            switch payload {
            case .item(let id): appState.addToScheduleWithUndo(.scheduleItem(id))
            case .place(let id): appState.addToScheduleWithUndo(.location(id))
            }
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    @State private var dropTargeted = false

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

/// Home's header line: "Sat Nov 21 · Panther Island, Fort Worth" (the event's day in its own time
/// zone, then the address's first two parts).
enum HomeHeaderText {
    static func line(_ event: Event, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let start = event.startTime {
            var style = Date.FormatStyle(locale: locale).weekday(.abbreviated).month(.abbreviated).day()
            style.timeZone = event.timeZone
            parts.append(start.formatted(style))
        }
        let place = event.address
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
            .joined(separator: ", ")
        if !place.isEmpty { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Home's urgent card: compact, swiped away sideways (or with the Dismiss action for VoiceOver);
/// dismissing uses the per-event dismissed urgent ids (the banner's), the update stays in Updates,
/// and an Undo toast brings it back.
private struct SwipeAwayUrgentCard: View {
    let notification: AppNotification
    let open: () -> Void

    @Environment(AppState.self) private var appState
    @State private var offset: CGFloat = 0

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(notification.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let sent = notification.sendTime {
                        Text(EventTimeFormat.time(sent, in: appState.timeZone))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(x: offset)
        .opacity(1 - min(abs(offset) / 300, 0.6))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if abs(value.translation.width) > abs(value.translation.height) { offset = value.translation.width }
                }
                .onEnded { value in
                    if abs(value.translation.width) > 100 {
                        withAnimation(.easeOut(duration: 0.2)) { offset = value.translation.width > 0 ? 500 : -500 }
                        dismiss()
                    } else {
                        withAnimation(.spring) { offset = 0 }
                    }
                }
        )
        .accessibilityLabel("Urgent: \(notification.title)")
        .accessibilityHint("Opens the update. Swipe sideways to dismiss.")
        .accessibilityAction(named: "Dismiss") { dismiss() }
    }

    private func dismiss() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        appState.dismissUrgentWithUndo(notification.id)
    }
}

/// The Undo toast over the tabs (`AppState.undoToast`), clear of the fold and cameras. On an
/// unfolded iPhone Duo it stays inside one pane — the one where the action was tapped, else the
/// screen's primary pane — centred in it, never across the fold, just above the floating button
/// row (`UndoToastPane`).
struct UndoToastOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let fold = ReservedRegionReader.folds(in: proxy).first { $0.height > $0.width }
            let span = UndoToastPane.span(
                containerWidth: proxy.size.width,
                fold: fold.map { $0.minX...$0.maxX },
                // A flat-open inner display (portrait) folds down the middle of the window.
                windowMidX: horizontalSizeClass == .regular && proxy.size.height > proxy.size.width
                    ? (frame.maxX + proxy.safeAreaInsets.trailing) / 2 - frame.minX : nil,
                touchX: appState.undoToast?.touchX.map { $0 - frame.minX },
                primaryIsTrailing: appState.selectedTab == .map
            )
            HStack(spacing: 0) {
                Spacer(minLength: 0).frame(width: span.lowerBound)
                ReservedRegionAvoiding {
                    toastColumn
                }
                .frame(width: max(span.upperBound - span.lowerBound, 0))
                Spacer(minLength: 0)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.undoToast?.id)
    }

    private var toastColumn: some View {
        VStack {
            Spacer()
            if let toast = appState.undoToast {
                HStack(spacing: 12) {
                    Text(toast.message).font(.subheadline).lineLimit(1)
                    Button("Undo") {
                        toast.undo()
                        appState.undoToast = nil
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(appState.tintColor ?? .accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 12)
                // Just above the floating button row and the bottom safe area.
                .padding(.bottom, FloatingSearchButtonMetrics.reservedHeight + 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .debugFloatingFrame("undo_toast")
            }
        }
        .frame(maxWidth: .infinity)
    }
}
