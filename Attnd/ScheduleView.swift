// ScheduleView.swift
// Attnd
//
// Schedule tab. A NavigationSplitView (list → item detail) on regular width,
// collapsing to a push stack on compact width. The same list also powers the
// "schedule" and "now/next" panes beside the map on wide layouts.
//
// Display config: `schedule_style` (timeline / by_day / by_location / now_next,
// grouped by ScheduleGrouping) and `enable_search`. All times are shown in the
// event's time zone. Countdown labels update live via TimelineView.
//
// With the on-device model the floating "My plan" button sits over it (AssistantView.swift).

import SwiftUI

// MARK: - Tab

struct ScheduleTab: View {
    @Environment(AppState.self) private var appState
    @State private var selection: ScheduleItem?

    var body: some View {
        NavigationSplitView {
            ScheduleView(selection: $selection)
                .eventStatusBanners()
                // The large title on the bar's own row: no empty band above it.
                .toolbarTitleDisplayMode(.inlineLarge)
                // After the filter menu, in its own glass group (only when Updates is hidden).
                .optionsToolbarItem(for: .schedule, separated: true)
        } detail: {
            NavigationStack {
                Group {
                    if let selection {
                        // Show the latest copy after a bundle refresh.
                        ScheduleItemDetailView(item: appState.schedule.first { $0.id == selection.id } ?? selection)
                    } else {
                        ContentUnavailableView("Select an Item", systemImage: "calendar")
                    }
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
            }
        }
        // A jump from search, a link or a notification (AppState.navigate).
        .onChange(of: appState.focusRequest, initial: true) {
            guard case .scheduleItem(let id)? = appState.focusRequest,
                  let item = appState.schedule.first(where: { $0.id == id }) else { return }
            appState.focusRequest = nil
            selection = item
        }
    }
}

// MARK: - List

struct ScheduleView: View {
    /// nil uses the display config's `schedule_style`.
    var style: ScheduleStyle? = nil
    var title: String = "Schedule"
    /// Bound in a split view's sidebar. nil when used inside a plain NavigationStack,
    /// where rows push their own destinations.
    var selection: Binding<ScheduleItem?>? = nil

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedLocationId: Int?
    @State private var showEnded = false

    /// The tab's own layout (API-027 `schedule_tab`) picks the list; else `display.schedule_style`.
    private var resolvedStyle: ScheduleStyle {
        style ?? appState.scheduleTabLayout?.style.flatMap(ScheduleStyle.init(rawValue:)) ?? appState.display.scheduleStyle
    }

    /// Ended items are hidden by default, except for archived events and when nothing is left to come (then the
    /// ended items are listed greyed instead of an empty tab; the server keeps the Schedule tab for them).
    private var hidesEnded: Bool {
        resolvedStyle != .nowNext && !showEnded && appState.currentEvent?.isArchived != true
            && appState.schedule.contains { !ScheduleTiming.hasEnded($0, at: Date()) }
    }

    private func visibleItems(now: Date) -> [ScheduleItem] {
        appState.schedule.filter { item in
            if hidesEnded, ScheduleTiming.hasEnded(item, at: now) { return false }
            if let id = selectedLocationId, item.locationId != id { return false }
            return SearchMatching.matches(item, query: searchText)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let sections = ScheduleGrouping.sections(
                for: visibleItems(now: now),
                style: resolvedStyle,
                now: now,
                timeZone: appState.timeZone,
                locations: appState.locations
            )
            list(sections: sections, now: now)
                .overlay {
                    if sections.isEmpty { emptyState }
                }
        }
        .navigationTitle(title)
        .modifier(SearchableIf(enabled: appState.display.enableSearch, text: $searchText, prompt: "Search schedule"))
        .refreshable { await appState.pullToRefresh() }
        // Walk times to each item's location (no compass needed here).
        .usesUserLocation(heading: false)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(sections: [ScheduleSection], now: Date) -> some View {
        if let selection {
            List(selection: selection) {
                listContent(sections: sections, now: now)
            }
        } else {
            List {
                listContent(sections: sections, now: now)
            }
            .navigationDestination(for: ScheduleItem.self) { item in
                ScheduleItemDetailView(item: item)
            }
            .navigationDestination(for: Location.self) { location in
                LocationDetailView(location: location)
            }
        }
    }

    /// "My schedule" first (iOS, Nov 21, 2026: upcoming entries, then the ended ones dimmed),
    /// then the event's whole schedule in its style. No Liked chip any more.
    @ViewBuilder
    private func listContent(sections: [ScheduleSection], now: Date) -> some View {
        let layout = appState.scheduleTabLayout
        if searchText.isEmpty, selectedLocationId == nil {
            if layout?.showsMySchedule ?? true {
                MyScheduleSection(now: now, open: open)
            }
            // API-027: the organizer's featured items.
            let featured = (layout?.featured ?? []).compactMap { id in appState.schedule.first { $0.id == id } }
            if !featured.isEmpty {
                Section {
                    ForEach(featured) { item in
                        NavigationLink(value: item) {
                            ScheduleRowView(item: item, showLocation: true, now: now, timeZone: appState.timeZone)
                        }
                        .scheduleItemPeek(item, now: now) { open(item) }
                    }
                } header: {
                    Text(layout?.featuredTitle ?? "Featured")
                }
            }
        }
        scheduleSections(sections, now: now)
    }

    @ViewBuilder
    private func scheduleSections(_ sections: [ScheduleSection], now: Date) -> some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items) { item in
                    NavigationLink(value: item) {
                        ScheduleRowView(
                            item: item,
                            showLocation: selectedLocationId == nil && resolvedStyle != .byLocation,
                            now: now,
                            timeZone: appState.timeZone
                        )
                    }
                    .scheduleItemPeek(item, now: now) { open(item) }
                }
            } header: {
                if !section.title.isEmpty {
                    Text(section.title)
                }
            }
        }
        if !sections.isEmpty, let note = EventTimeFormat.zoneNote(for: appState.timeZone, at: now) {
            Section {
            } footer: {
                Text(note)
            }
        }
    }

    /// "Open" in a row's peek: select it in the split view, else show it in its tab / search.
    private func open(_ item: ScheduleItem) {
        if let selection {
            selection.wrappedValue = item
        } else {
            appState.navigate(to: .scheduleItem(item.id))
        }
    }

    // MARK: Filter

    private var filterMenu: some View {
        Menu {
            if resolvedStyle != .nowNext {
                Toggle(isOn: $showEnded) {
                    Label("Show Ended Items", systemImage: "clock.arrow.circlepath")
                }
            }

            Picker(selection: $selectedLocationId) {
                Text("All Locations").tag(Int?.none)
                ForEach(appState.locations) { location in
                    Text(location.name).tag(Int?.some(location.id))
                }
            } label: {
                Label("Location", systemImage: "mappin.and.ellipse")
            }
            .pickerStyle(.inline)
        } label: {
            // Icon and title: bars show the icon, vertical bars and accessibility use the title.
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                .symbolVariant(selectedLocationId != nil || showEnded ? .fill : .none)
        }
    }

    private var emptyState: some View {
        Group {
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if appState.isLoading {
                ProgressView()
            } else if hidesEnded, !appState.schedule.isEmpty {
                ContentUnavailableView(
                    "All Done!",
                    systemImage: "checkmark.circle",
                    description: Text("No upcoming items. Use the filter to show ended ones.")
                )
            } else if selectedLocationId != nil {
                ContentUnavailableView(
                    "Nothing Here",
                    systemImage: "calendar",
                    description: Text("No items are scheduled at this location.")
                )
            } else if resolvedStyle == .nowNext, !appState.schedule.isEmpty {
                ContentUnavailableView(
                    "Nothing Coming Up",
                    systemImage: "checkmark.circle",
                    description: Text("Everything on the schedule has ended.")
                )
            } else {
                ContentUnavailableView(
                    "No Schedule",
                    systemImage: "calendar",
                    description: Text("Schedule items will appear here once they're published.")
                )
            }
        }
    }
}

// MARK: - Row

struct ScheduleRowView: View {
    let item: ScheduleItem
    let showLocation: Bool
    let now: Date
    let timeZone: TimeZone

    @Environment(AppState.self) private var appState

    /// "8 min walk" to the item's location when the user is within walking range of it.
    private var walkText: String? {
        guard !ScheduleTiming.hasEnded(item, at: now),
              let direction = appState.userLocation.direction(to: appState.location(id: item.locationId)?.coordinate),
              WalkTime.isWithinWalkingRange(direction.meters) else { return nil }
        return direction.isHere ? "You're here" : WalkTime.rowText(straightMeters: direction.meters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: timeZone, now: now))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if showLocation {
                    Text(item.locationName ?? ScheduleGrouping.generalTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.headline)
                Spacer()
                // Live countdown (the list re-renders every 30 s): "in 12 min", "Started 5 min ago", "Now".
                if let relative = RelativeTimeText.item(item, now: now, timeZone: timeZone) {
                    Text(relative)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(ScheduleTiming.hasEnded(item, at: now) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                HeartButton(target: .scheduleItem(item.id), font: .subheadline)
            }
            if let progress = ScheduleTiming.progress(item, at: now) {
                ItemProgressBar(progress: progress)
            }
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !item.tags.isEmpty {
                Text(TagText.line(item.tags))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if let walkText {
                Label(walkText, systemImage: "figure.walk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Peek

extension View {
    /// Long press: a preview card with the key info, and Heart / Show on Map / Open.
    func scheduleItemPeek(_ item: ScheduleItem, now: Date, open: @escaping () -> Void) -> some View {
        modifier(ScheduleItemPeekModifier(item: item, now: now, open: open))
    }
}

private struct ScheduleItemPeekModifier: ViewModifier {
    let item: ScheduleItem
    let now: Date
    let open: () -> Void

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let target = SearchTarget.scheduleItem(item.id)
        let hearted = appState.isHearted(target)
        let location = appState.location(id: item.locationId)
        content.contextMenu {
            Button {
                appState.toggleHeart(target)
            } label: {
                Label(hearted ? MyScheduleText.remove : "Add to My Schedule", systemImage: hearted ? "heart.slash" : "heart")
            }
            if let location, location.coordinate != nil, appState.shows(.map) {
                Button {
                    appState.showOnMap(locationId: location.id)
                } label: {
                    Label("Show on Map", systemImage: "map")
                }
            }
            Button(action: open) {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        } preview: {
            ScheduleItemPeek(
                item: item,
                timeText: EventTimeFormat.range(start: item.startTime, end: item.endTime, in: appState.timeZone, now: now),
                relativeText: RelativeTimeText.item(item, now: now, timeZone: appState.timeZone, includeEnd: true),
                locationName: location?.name ?? item.locationName ?? ScheduleGrouping.generalTitle,
                hearted: hearted
            )
        }
    }
}

// MARK: - Item detail

struct ScheduleItemDetailView: View {
    let item: ScheduleItem

    @Environment(AppState.self) private var appState
    /// The container's width: two columns from `DetailColumns.minWidth`.
    @State private var width: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HeartToolbarItem(target: .scheduleItem(item.id), appState: appState)
        }
        .task(id: item.id) { appState.track(.scheduleItemView, id: item.id) }
        // Distance + arrow to the item's location.
        .usesUserLocation(heading: true)
    }

    /// API-024: the sections the event's `item_detail` layout lists (or the built-in default,
    /// today's screen), in order; each draws only when the item has its data.
    private func content(now: Date) -> some View {
        let bundle = appState.currentBundle
        let sections = appState.screenSections(
            .itemDetail, now: now, subject: bundle.map { ScreenFacts.subject(item, $0) } ?? .empty
        ) { bundle, state in
            ScreenFacts.item(item, bundle, state)
        }
        return Group {
            if let columns = DetailColumns.split(sections, screen: .itemDetail, width: Double(width)) {
                // Wide (iPhone Duo unfolded): when and where leading, the details trailing.
                HStack(spacing: 0) {
                    List {
                        ForEach(columns.leading, id: \.type) { section in
                            self.section(section, now: now)
                        }
                    }
                    List {
                        ForEach(columns.trailing, id: \.type) { section in
                            self.section(section, now: now)
                        }
                    }
                }
            } else {
                List {
                    ForEach(sections, id: \.type) { section in
                        self.section(section, now: now)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder
    private func section(_ section: LayoutSection, now: Date) -> some View {
        switch section.type {
        case "header": header(section, now: now)
        case "about":
            let about = AboutText.merged(description: item.description, about: item.context?.about)
            if !about.isEmpty {
                Section(section.title ?? "About") {
                    Text(about)
                }
            }
        // API-018: performers, price / age / accessibility, links.
        case "performers":
            if let context = item.context { PerformersSection(performers: context.performers, title: section.title) }
        case "good_to_know":
            if let context = item.context { ItemFactsSection(context: context, title: section.title) }
        case "links":
            if let context = item.context { ContextLinksSection(links: context.links, title: section.title) }
        case "countdown":
            Section(section.title ?? "Starts In") {
                Countdown(item: item)
            }
        case "place_link": placeLink(section)
        // "ask_about": removed Nov 21, 2026 (no Ask About This); older layouts draw nothing.
        default:
            EmptyView()
        }
    }

    private func header(_ section: LayoutSection, now: Date) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name).font(.title2.bold())
                if section.shows("time") {
                    Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: appState.timeZone, now: now))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if section.shows("status") {
                    if ScheduleTiming.isHappening(item, at: now) {
                        Label(
                            RelativeTimeText.item(item, now: now, timeZone: appState.timeZone, includeEnd: true) ?? "Happening now",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .font(.subheadline.bold())
                        .foregroundStyle(.tint)
                        if let progress = ScheduleTiming.progress(item, at: now) {
                            ItemProgressBar(progress: progress)
                        }
                    } else if let relative = RelativeTimeText.item(item, now: now, timeZone: appState.timeZone) {
                        Text(relative)
                            .font(.subheadline.bold())
                            .foregroundStyle(ScheduleTiming.hasEnded(item, at: now) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }
                }
                if section.shows("tags"), !item.tags.isEmpty {
                    Text(TagText.line(item.tags))
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            if section.shows("time"), let note = EventTimeFormat.zoneNote(for: appState.timeZone, at: now) {
                Text(note)
            }
        }
    }

    private func placeLink(_ section: LayoutSection) -> some View {
        Section(section.title ?? "Location") {
            if let location = appState.location(id: item.locationId) {
                NavigationLink(value: location) {
                    HStack {
                        Label(location.name, systemImage: "mappin.and.ellipse")
                        Spacer(minLength: 8)
                        DistanceBadge(target: location.coordinate, font: .subheadline)
                    }
                }
            } else {
                Label(item.locationName ?? ScheduleGrouping.generalTitle, systemImage: "mappin.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ScheduleTab()
        .environment(AppState())
}

// MARK: - My schedule section

/// The Schedule tab's first section: My schedule's timed entries (items and places at a time),
/// upcoming first and the ended ones dimmed at the end; then "Saved Places" (no time). Hidden while empty.
private struct MyScheduleSection: View {
    let now: Date
    let open: (ScheduleItem) -> Void

    @Environment(AppState.self) private var appState
    @State private var showsShare = false

    var body: some View {
        if let bundle = appState.currentBundle {
            let rows = appState.mySchedule.sectionRows(bundle, now: now)
            let saved = appState.mySchedule.savedPlaceIds.compactMap { bundle.location($0) }
            let changes = appState.scheduleOrganizerChanges
            if !rows.isEmpty || !changes.isEmpty {
                Section {
                    ForEach(changes) { change in
                        OrganizerChangeRow(change: change)
                    }
                    ForEach(rows) { row in
                        rowView(row, bundle)
                            .opacity(row.ended ? 0.5 : 1)
                    }
                } header: {
                    HStack {
                        Text(MyScheduleText.title)
                        Spacer()
                        // Batch 7: share My schedule as a /p/ link with its QR code.
                        if !appState.personal.heartedScheduleItems.isEmpty {
                            Button {
                                showsShare = true
                            } label: {
                                Label("Share", systemImage: "qrcode")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption.weight(.semibold))
                            }
                            .textCase(nil)
                        }
                    }
                }
                .sheet(isPresented: $showsShare) {
                    NavigationStack {
                        ScrollView {
                            if let link = appState.assistant.shareLink("schedule") {
                                ShareCard(title: link.title, url: link.url,
                                          subtitle: "\(link.items) items, read-only. Friends can use it or merge it with theirs.")
                                    .padding()
                                    .task(id: link.url) { appState.assistant.logShare("schedule", url: link.url, items: link.items) }
                            }
                        }
                        .navigationTitle("Share My Schedule")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close", systemImage: "xmark", role: .close) { showsShare = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            // Places saved without a time (a time only when asked for: the heart's menu).
            if !saved.isEmpty {
                Section {
                    ForEach(saved) { location in
                        Button {
                            appState.navigate(to: .location(location.id))
                        } label: {
                            HStack {
                                Label(location.name, systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(.primary)
                                Spacer()
                                HeartButton(target: .location(location.id), font: .subheadline)
                            }
                        }
                    }
                } header: {
                    Text(MyScheduleText.savedPlaces)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MyScheduleRow, _ bundle: EventBundle) -> some View {
        switch row.entry.kind {
        case .item:
            if let item = bundle.scheduleItem(row.entry.id) {
                NavigationLink(value: item) {
                    ScheduleRowView(item: item, showLocation: true, now: now, timeZone: appState.timeZone)
                }
                .scheduleItemPeek(item, now: now) { open(item) }
            }
        case .place:
            Button {
                appState.navigate(to: .location(row.entry.id))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(EventTimeFormat.range(start: row.start, end: row.end, in: appState.timeZone, now: now))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    HStack(alignment: .firstTextBaseline) {
                        Label(row.name, systemImage: "mappin.and.ellipse")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        HeartButton(target: row.target, font: .subheadline)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// "Moved to 8:00 PM · Keep / Remove / Find Another" for an item in My schedule the organizer
/// changed (iOS: a live hint with a fix).
private struct OrganizerChangeRow: View {
    let change: MySchedule.OrganizerChange

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text).font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if change.kind != .cancelled {
                    Button("Keep") { appState.keepOrganizerChange(change.itemId) }
                }
                Button("Remove", role: .destructive) {
                    if change.kind == .cancelled {
                        appState.keepOrganizerChange(change.itemId)
                    } else {
                        appState.removeFromSchedule(.scheduleItem(change.itemId))
                    }
                }
                Button("Find Another") {
                    appState.searchText = change.name
                    appState.openSearch()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var text: String {
        switch change.kind {
        case .moved(let start):
            return "\(change.name) moved to \(EventTimeFormat.time(start, in: appState.timeZone))."
        case .changed:
            return "\(change.name) changed."
        case .cancelled:
            return "\(change.name) was cancelled."
        }
    }
}
