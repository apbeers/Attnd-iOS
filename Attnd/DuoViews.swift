// DuoViews.swift
// Attnd (app + App Clip)
//
// The iPhone Duo screens (batch 7 "premium experience"; rules in DuoFeatures.swift):
//   - `TimeTravelScrubber`: the map's time slider (unfolded): pins of what's on then light up.
//   - `TabletopGlance` views: Home half-folded — a big Now / Next with the countdown and the urgent
//     announcement on the top half (readable at a distance, no translucency), the list or the
//     "at the event" controls on the bottom half; offered once during a live event.
//   - `StageVsStageView`: two stages' line-ups side by side (the Schedule tab's detail column).
//   - `FlyerTab`: the flyer full height on one half and the map on the other, with the places the
//     flyer names (on-device text recognition) findable on the map.
// Layout follows container geometry and size classes only (never the device); everything works
// offline from the bundle; App and App Clip alike.

import MapKit
import SwiftUI
import ImageIO
import Vision

// MARK: - Time travel

struct TimeTravelScrubber: View {
    let range: ClosedRange<Date>
    let points: [Date]
    let now: Date
    let timeZone: TimeZone
    @Binding var time: Date?

    var body: some View {
        let current = time ?? now
        let label = TimeTravel.label(current, now: now, timeZone: timeZone)
        let binding = $time
        let range = self.range, points = self.points, now = self.now
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(time == nil ? "Now" : label, systemImage: time == nil ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(time == nil ? "Drag to see what's on later" : "Lit pins: on at this time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if time != nil {
                    Button("Now", systemImage: "arrow.uturn.backward") {
                        binding.wrappedValue = nil
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            Slider(
                value: Binding(
                    get: { TimeTravel.fraction(of: binding.wrappedValue ?? now, in: range) },
                    set: { fraction in
                        let snapped = TimeTravel.snap(TimeTravel.date(at: fraction, in: range), to: points, now: now)
                        binding.wrappedValue = TimeTravel.isNow(snapped, now: now) ? nil : snapped
                    }
                ),
                in: 0...1
            )
            .accessibilityLabel("Time on the map")
            .accessibilityValue(label)
            HStack {
                Text("Now")
                Spacer()
                Text(EventTimeFormat.clock(range.upperBound, in: timeZone))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        // A tick each time it snaps onto another set start.
        .sensoryFeedback(.selection, trigger: time)
    }
}

// MARK: - Tabletop

/// The top half when half-folded: Now and Next, big, with the countdown and the urgent
/// announcement. Solid colours (no glass), large type that scales down to fit the half.
struct TabletopGlanceView: View {
    let now: Date
    /// The "at the event" mode: even larger type.
    var large = false
    let open: (SearchTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let glance = TabletopGlance.of(appState.schedule, mine: appState.personal.heartedScheduleItems, now: now)
        let urgent = UpdatesInbox.urgent(appState.notifications, dismissed: appState.personal.dismissedUrgentIds, now: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.currentEvent?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(EventTimeFormat.clock(now, in: appState.timeZone))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                // Home has no bar: its Options gear moves here with the header.
                if appState.optionsTab == .home {
                    Button {
                        appState.presentedSheet = .options
                    } label: {
                        Label("Options", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let urgent {
                Button { open(.notification(urgent.id)) } label: {
                    Label(urgent.title, systemImage: "exclamationmark.triangle.fill")
                        .font(large ? .title3.bold() : .headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .foregroundStyle(.white)
                        .background(Color.red, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Urgent: \(urgent.title)")
            }
            HStack(alignment: .top, spacing: 16) {
                slot("Now", item: glance.now, mine: glance.nowIsMine, isNext: false)
                Divider()
                slot("Next", item: glance.next, mine: glance.nextIsMine, isNext: true)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func slot(_ title: String, item: ScheduleItem?, mine: Bool, isNext: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.tint)
                if mine {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint)
                        .accessibilityLabel("In my schedule")
                }
            }
            if let item {
                Button { open(.scheduleItem(item.id)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: large ? 44 : 32, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.5)
                            .multilineTextAlignment(.leading)
                        if let place = appState.location(id: item.locationId)?.name ?? item.locationName {
                            Text(place)
                                .font(large ? .title3 : .headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if isNext, let start = item.startTime, start > now {
                            // Ticks by itself (no updates needed).
                            Text(timerInterval: now...start, countsDown: true)
                                .font(.system(size: large ? 48 : 34, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                        } else if !isNext, let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) {
                            ProgressView(timerInterval: start...end, countsDown: false) {
                                EmptyView()
                            } currentValueLabel: {
                                Text("Ends \(EventTimeFormat.clock(end, in: appState.timeZone))")
                                    .font(.subheadline.monospacedDigit())
                            }
                            .tint(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text(isNext ? "Nothing later today" : "Nothing on right now")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The bottom half in the "at the event" mode: big controls for Next (or Now) — the map,
/// My schedule's heart, directions — and the next few sets.
struct TabletopControls: View {
    let now: Date
    let open: (SearchTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let glance = TabletopGlance.of(appState.schedule, mine: appState.personal.heartedScheduleItems, now: now)
        let focus = glance.next ?? glance.now
        let place = appState.location(id: focus?.locationId)
        let upcoming = appState.schedule
            .filter { ($0.startTime ?? .distantPast) > now }
            .sorted { ($0.startTime ?? .distantPast, $0.id) < ($1.startTime ?? .distantPast, $1.id) }
            .prefix(4)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if let place, place.coordinate != nil, appState.shows(.map) {
                        bigButton("Map", systemImage: "map") { appState.showOnMap(locationId: place.id) }
                    }
                    if let focus {
                        HeartButton(target: .scheduleItem(focus.id), font: .title2, titled: true)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                    }
                    if let place, place.coordinate != nil {
                        bigButton("Directions", systemImage: "figure.walk") { WalkingDirections.open(to: place) }
                    }
                }
                if !upcoming.isEmpty {
                    Text("What's next").font(.headline)
                    ForEach(Array(upcoming)) { item in
                        Button { open(.scheduleItem(item.id)) } label: {
                            HStack {
                                Text(item.startTime.map { EventTimeFormat.clock($0, in: appState.timeZone) } ?? "")
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                    .frame(width: 96, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(1)
                                    if let name = appState.location(id: item.locationId)?.name {
                                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Exit At the Event Mode", systemImage: "rectangle.split.1x2") {
                    appState.tabletopAtEventMode = false
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
    }

    private func bigButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 16))
    }
}

/// Offered once, the first time the phone is half-folded while the event is on.
struct TabletopOfferCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Propped up at the event?", systemImage: "rectangle.split.1x2")
                .font(.headline)
            Text("At the Event mode keeps Now and Next big on the top half, with the map, your schedule and directions below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Turn On") {
                    appState.tabletopModeOffered = true
                    appState.tabletopAtEventMode = true
                }
                .buttonStyle(.glassProminent)
                Button("Not Now") { appState.tabletopModeOffered = true }
                    .buttonStyle(.glass)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockCardBackground()
    }
}

// MARK: - Stage vs stage

/// Two stages' line-ups side by side, to choose between clashing sets (the Schedule tab's detail
/// column on an unfolded iPhone Duo, before anything is selected). Clashing sets are marked.
struct StageVsStageView: View {
    var preferring: Int? = nil
    let select: (ScheduleItem) -> Void

    @Environment(AppState.self) private var appState
    @State private var left: Int?
    @State private var right: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let stages = StageCompare.stages(appState.schedule, locations: appState.locations)
            if stages.count < 2 {
                ContentUnavailableView("Select an Item", systemImage: "calendar")
            } else {
                let pair = StageCompare.defaultPair(appState.schedule, locations: appState.locations, preferring: preferring, now: now)
                let a = left ?? pair?.0 ?? stages[0].id
                let b = right ?? pair?.1 ?? stages[1].id
                let lineupA = StageCompare.lineup(a, in: appState.schedule, now: now)
                let lineupB = StageCompare.lineup(b, in: appState.schedule, now: now)
                let clashes = StageCompare.clashes(lineupA, lineupB)
                ScrollView {
                    HStack(alignment: .top, spacing: 16) {
                        column(stages: stages, chosen: a, other: b, items: lineupA, clashes: clashes, now: now) { left = $0 }
                        column(stages: stages, chosen: b, other: a, items: lineupB, clashes: clashes, now: now) { right = $0 }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Stage vs Stage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func column(stages: [Location], chosen: Int, other: Int, items: [ScheduleItem], clashes: Set<Int>,
                        now: Date, choose: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(stages.filter { $0.id != other }) { stage in
                    Button(stage.name) { choose(stage.id) }
                }
            } label: {
                Label(appState.location(id: chosen)?.name ?? "Stage", systemImage: "chevron.up.chevron.down")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            }
            ForEach(items) { item in
                Button { select(item) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: appState.timeZone, now: now))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(item.name).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                        if clashes.contains(item.id) {
                            Label("Clashes", systemImage: "arrow.left.arrow.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(ScheduleTiming.isHappening(item, at: now) ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                                in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    HeartButton(target: .scheduleItem(item.id), font: .subheadline)
                        .padding(4)
                }
                .draggable(DragPayload.item(item.id).string)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Planning board (My plan, unfolded)

/// My plan's second pane on an unfolded iPhone Duo: the day's timeline and its walking route on a
/// map ("Your Day"), the sets that would fit, and a drop target — drag a set from the list (or a
/// card from the chat) onto the board and it becomes a proposal in the chat (Apply / Undo, the
/// usual rules); applied, the timeline and the route redraw.
struct PlanningBoard: View {
    @Environment(AppState.self) private var appState
    @State private var targeted = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let planned = appState.plannedItemIds.union(appState.personal.heartedScheduleItems)
            let ideas = Array(appState.schedule
                .filter { ($0.startTime ?? .distantPast) > now && !planned.contains($0.id) }
                .sorted { ($0.startTime ?? .distantPast, $0.id) < ($1.startTime ?? .distantPast, $1.id) }
                .prefix(8))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MyScheduleDay(now: now)
                    if !ideas.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            BlockTitle(title: "Coming Up")
                            Text("Drag one onto your day, or tap +.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(ideas) { item in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text([item.startTime.map { EventTimeFormat.clock($0, in: appState.timeZone) },
                                              appState.location(id: item.locationId)?.name].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Button {
                                        appState.assistant.addToPlan(item.id)
                                    } label: {
                                        Label("Add to My Plan", systemImage: "plus.circle.fill")
                                            .labelStyle(.iconOnly)
                                            .font(.title3)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(10)
                                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                                .draggable(DragPayload.item(item.id).string)
                            }
                        }
                        .blockCardBackground()
                    }
                }
                .padding(16)
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { strings, _ in
            guard case .item(let id)? = strings.lazy.compactMap(DragPayload.parse).first else { return false }
            appState.assistant.addToPlan(id)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

// MARK: - Flyer + map

/// The Flyer tab: unfolded and wider than tall, the flyer full height on the leading half and the
/// map on the trailing one (meeting on the fold). The flyer keeps its identity when the map comes
/// and goes, so it never reloads on a fold.
struct FlyerTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let showsMap = horizontalSizeClass == .regular && proxy.size.width > proxy.size.height
                && appState.currentEvent?.flyerUrl != nil && appState.locations.contains { $0.coordinate != nil }
                && !ScreenshotMode.isActive
            let fold = ReservedRegionReader.folds(in: proxy).first { $0.height > $0.width && $0.minX > 0 }
            HStack(spacing: 0) {
                NavigationStack {
                    FlyerView(flyerUrl: appState.currentEvent?.flyerUrl)
                        .eventStatusBanners()
                        .optionsToolbarItem(for: .flyer)
                }
                .frame(width: showsMap ? MapPaneLayout.paneWidth(container: proxy.size, foldMinX: fold?.minX) : nil)
                if showsMap {
                    FlyerPlacesMap()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsMap)
        }
    }
}

/// The map beside the flyer: every place's pin; chips for the places the flyer names (found by
/// on-device text recognition of the flyer image), else every place; a tap flies to it.
private struct FlyerPlacesMap: View {
    @Environment(AppState.self) private var appState
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: Int?
    @State private var onFlyer: [Int] = []

    var body: some View {
        let located = appState.locations.filter { $0.coordinate != nil }
        let chips = onFlyer.isEmpty ? located.map(\.id) : onFlyer
        NavigationStack {
            Map(position: $position, selection: $selected) {
                ForEach(located) { location in
                    if let coordinate = location.coordinate {
                        Marker(location.name, coordinate: coordinate.clCoordinate)
                            .tag(location.id)
                    }
                }
                UserAnnotation()
            }
            .mapControls { }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(onFlyer.isEmpty ? "Places" : "On the flyer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        GlassEffectContainer(spacing: 6) {
                            HStack(spacing: 6) {
                                ForEach(chips, id: \.self) { id in
                                    if let location = appState.location(id: id) {
                                        if selected == id {
                                            Button(location.name) { fly(to: location) }
                                                .buttonStyle(.glassProminent)
                                                .controlSize(.small)
                                        } else {
                                            Button(location.name) { fly(to: location) }
                                                .buttonStyle(.glass)
                                                .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let location = appState.location(id: selected) {
                    HStack {
                        Text(location.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Details", systemImage: "info.circle") { appState.open(.location(location.id)) }
                            .buttonStyle(.glass)
                    }
                    .padding(12)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                    .padding(.horizontal)
                    .padding(.bottom, FloatingSearchButtonMetrics.reservedHeight + 8)
                }
            }
            .navigationTitle("Map")
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: appState.currentEvent?.flyerUrl) {
            guard let url = appState.currentEvent?.flyerUrl, let data = await ImageStore.shared.data(for: url) else { return }
            let lines = await FlyerText.lines(from: data)
            guard !Task.isCancelled else { return }
            onFlyer = FlyerPlaces.match(lines: lines, locations: appState.locations.filter { $0.coordinate != nil })
        }
    }

    private func fly(to location: Location) {
        guard let coordinate = location.coordinate else { return }
        selected = location.id
        withAnimation { position = .region(MapRegionMath.streetLevel(coordinate).mkRegion) }
    }
}

/// On-device text recognition of the flyer image (Vision); a PDF or anything that isn't an image
/// gives nothing. Never leaves the device.
enum FlyerText {
    static func lines(from data: Data) async -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        guard let observations = try? await request.perform(on: image) else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
}

#if DEBUG
// MARK: - Preview fixture

/// A DEMO-sized event for previews (6 stages and food places, ~30 sets around now, an urgent
/// update), so Duo layouts are judged with real amounts of content. Debug builds only.
@MainActor
enum PreviewFixture {
    static func bundle(now: Date = .now) -> EventBundle {
        let names = ["Main Stage", "Prairie Tent", "Riverside", "Taco Row", "Craft Beer Garden", "Kids Corner"]
        var locations = names.enumerated().map { index, name in
            Location(id: index + 1, name: name, category: index >= 3 ? "Food & Drink" : "Stages",
                     latitude: 32.7555 + Double(index) * 0.0007, longitude: -97.3308 + Double(index % 3) * 0.0009,
                     sortOrder: index, tags: index < 3 ? ["live music"] : ["food"])
        }
        let acts = ["Prairie Lights", "Midnight Choir", "Juniper Lane", "Velvet Mesquite", "Hazel Creek", "Neon Armadillo",
                    "Lone Star Collective", "The Grackles", "Copper Kettle", "Bluebonnet Revue"]
        var schedule: [ScheduleItem] = []
        var id = 100
        for stage in 1...3 {
            for slot in -2...7 {
                id += 1
                let start = now.addingTimeInterval(Double(slot) * 3600 + Double(stage - 1) * 1200)
                schedule.append(ScheduleItem(id: id, name: acts[(id + stage) % acts.count], startTime: start,
                                             endTime: start.addingTimeInterval(50 * 60), locationId: stage,
                                             tags: ["live music"]))
            }
        }
        schedule.append(ScheduleItem(id: 900, name: "Gates open", startTime: now.addingTimeInterval(-4 * 3600)))
        // One set with lots of detail (performers, price, Apple Music), for the detail previews.
        if let index = schedule.firstIndex(where: { $0.id == 103 }) {
            schedule[index].description = "An evening of prairie folk under the lights, with special guests."
            schedule[index].context = ScheduleItemContext(
                about: "Their first hometown show since the spring tour.",
                performers: [Performer(name: "Prairie Lights", bio: "A five-piece from Fort Worth.", genres: ["folk", "americana"],
                                       appleMusicURL: URL(string: "https://music.apple.com/us/artist/prairie-lights/1")),
                             Performer(name: "Hazel Creek", bio: "Fiddle and banjo.", genres: ["bluegrass"])],
                ageLimit: "All ages", price: "Free", accessibility: "Viewing platform by the sound desk.")
        }
        locations[0].context = LocationContext(about: "The big stage by the river.", hours: "10 AM – 11 PM",
                                               accessibility: "Step-free viewing area.")
        let event = Event(id: 1, name: "Panther Island Fest", eventCode: "DEMO", latitude: 32.7555, longitude: -97.3308,
                          startTime: now.addingTimeInterval(-4 * 3600), endTime: now.addingTimeInterval(9 * 3600),
                          timeZoneIdentifier: "America/Chicago")
        let notifications = [
            AppNotification(id: 1, title: "Set time change", body: "Prairie Lights moves to 8:30 PM.",
                            sendTime: now.addingTimeInterval(-600), priority: .urgent),
            AppNotification(id: 2, title: "Welcome!", body: "Water stations by every stage.", sendTime: now.addingTimeInterval(-7200)),
        ]
        return EventBundle(event: event, locations: locations, schedule: schedule, notifications: notifications)
    }

    static func appState(now: Date = .now) -> AppState {
        let state = AppState()
        state.applyForPreview(bundle(now: now))
        return state
    }
}

// MARK: - Previews (approximate Duo point sizes; DEMO-sized content from PreviewFixture)

#Preview("Tabletop glance", traits: .fixedLayout(width: 951, height: 320)) {
    TabletopGlanceView(now: .now, open: { _ in })
        .environment(PreviewFixture.appState())
}

#Preview("Tabletop controls", traits: .fixedLayout(width: 951, height: 320)) {
    TabletopControls(now: .now, open: { _ in })
        .environment(PreviewFixture.appState())
}

#Preview("Stage vs stage", traits: .fixedLayout(width: 669, height: 951)) {
    NavigationStack {
        StageVsStageView(select: { _ in })
    }
    .environment(PreviewFixture.appState())
}

#Preview("Home unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    HomeTab()
        .environment(PreviewFixture.appState())
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Home unfolded portrait", traits: .fixedLayout(width: 669, height: 951)) {
    HomeTab()
        .environment(PreviewFixture.appState())
        .environment(\.horizontalSizeClass, .regular)
}

#Preview("Home outer", traits: .fixedLayout(width: 466, height: 678)) {
    HomeTab()
        .environment(PreviewFixture.appState())
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("Item detail, lots, unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    let state = PreviewFixture.appState()
    NavigationStack {
        if let item = state.schedule.first(where: { $0.id == 103 }) { ScheduleItemDetailView(item: item) }
    }
    .environment(state)
    .environment(\.horizontalSizeClass, .regular)
}

#Preview("Item detail, little, unfolded", traits: .fixedLayout(width: 951, height: 669)) {
    let state = PreviewFixture.appState()
    NavigationStack {
        if let item = state.schedule.first(where: { $0.id == 900 }) { ScheduleItemDetailView(item: item) }
    }
    .environment(state)
    .environment(\.horizontalSizeClass, .regular)
}

#Preview("Place detail, unfolded", traits: .fixedLayout(width: 669, height: 951)) {
    let state = PreviewFixture.appState()
    NavigationStack {
        if let location = state.locations.first { LocationDetailView(location: location) }
    }
    .environment(state)
    .environment(\.horizontalSizeClass, .regular)
}

#Preview("Planning board", traits: .fixedLayout(width: 475, height: 669)) {
    PlanningBoard()
        .environment(PreviewFixture.appState())
}

#Preview("Time travel", traits: .fixedLayout(width: 480, height: 160)) {
    @Previewable @State var time: Date? = nil
    TimeTravelScrubber(range: Date.now...Date.now.addingTimeInterval(8 * 3600), points: [], now: .now,
                       timeZone: .current, time: $time)
        .padding()
}
#endif
