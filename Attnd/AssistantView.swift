// AssistantView.swift
// Attnd (app target only — not in the App Clip)
//
// The assistant screen (assistant spec §8): the floating search button's sheet in the full app
// (screenshot mode and the App Clip keep the plain search sheet, EventSearchView.swift).
//
//   - Top: the pinned plan (collapsible): the next entries with walking legs and the mini map,
//     "Your plan changed" with the planned items the organizers moved or removed, Undo, Open in
//     Schedule. Without a plan: the "Make a plan" card with the event's examples (only while
//     the on-device model is available; nothing otherwise).
//   - Live hints (spec §6): running late ("Leave now" / swap chips), gap fillers, skipped items,
//     the day's recap.
//   - The conversation: the person's turns and the assistant's blocks (AssistantBlockView),
//     shared plan offers ("Use this plan" / "Merge with mine").
//   - While typing: live search results (debounced, nothing is sent); Return / send runs the
//     full turn. Empty: suggestion chips (Happening now, Up next, Liked, categories).
//   - Bottom: one input bar (focused with the keyboard up on open) with the intent chip
//     ("Searching…", "Asking…", "Editing plan…"; tap to choose the path).
//
// The sheet keeps `AppState.searchPath`, so details pushed by results, Siri and hidden tabs
// work exactly as in the search sheet.

import SwiftUI

// MARK: - Sheet

struct AssistantSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Put the keyboard up on open (not when Siri / Spotlight opened the sheet on an item).
    let focusesInput: Bool

    var body: some View {
        @Bindable var state = appState
        NavigationStack(path: $state.searchPath) {
            AssistantScreen(focusesInput: focusesInput)
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
                .navigationDestination(for: HeartedListRoute.self) { _ in
                    HeartedListView()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        AssistantMenu()
                    }
                }
        }
        .presentationDetents([.large])
    }
}

private struct AssistantMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            if appState.planner.hasPlan, appState.tabs.contains(.schedule) {
                Button("Open My Plan in Schedule", systemImage: "list.bullet.clipboard") {
                    appState.showMyPlan()
                }
            }
            Button("Clear Conversation", systemImage: "trash", role: .destructive) {
                appState.assistant.clearConversation()
            }
            .disabled(appState.assistant.turns.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

// MARK: - Screen

struct AssistantScreen: View {
    let focusesInput: Bool

    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    /// The draft the live results are for (debounced).
    @State private var settledDraft = ""
    @State private var predicted: TurnPath = .search
    @State private var planExpanded = true

    private var assistant: AssistantController { appState.assistant }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PinnedPlanSection(expanded: $planExpanded)
                    LiveHintsSection(hints: assistant.live)
                    ForEach(assistant.turns) { turn in
                        TurnView(turn: turn)
                            .id(turn.id)
                    }
                    if assistant.busy == .plan {
                        WorkingRow(text: "Planning on your iPhone…")
                    }
                    typingContent
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .onChange(of: assistant.serial) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantInputBar(focused: $inputFocused, predicted: predicted) { send() }
        }
        .navigationTitle(assistant.modelAvailable ? "Search & Ask" : "Search")
        .navigationBarTitleDisplayMode(.inline)
        // Distances on cards and the live hints (only while already permitted).
        .usesUserLocation(heading: true)
        .task(id: assistant.draft) {
            // Live results and the intent chip follow the typing, debounced.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            settledDraft = assistant.draft
            predicted = assistant.predict(assistant.draft)
        }
        .task {
            // Live hints once a minute while the screen is open.
            while !Task.isCancelled {
                assistant.refreshLive()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // A shared plan link (API-015), once its event's content is shown.
        .task(id: [appState.pendingSharedPlan?.payload, appState.currentEvent.map { String($0.id) }]) {
            guard let shared = appState.pendingSharedPlan, appState.currentBundle != nil else { return }
            appState.pendingSharedPlan = nil
            assistant.openShared(shared)
        }
        .task {
            planExpanded = assistant.turns.count < 3
            guard focusesInput else { return }
            await focusInput()
        }
        .onChange(of: assistant.focusSerial) {
            Task { await focusInput() }
        }
    }

    @ViewBuilder
    private var typingContent: some View {
        let draft = settledDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !draft.isEmpty, assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines) == draft {
            LiveResults(query: draft)
        } else if assistant.turns.isEmpty, assistant.draft.isEmpty {
            EmptyStateChips()
        }
    }

    private func focusInput() async {
        inputFocused = true
        // The sheet may still be animating in; ask again once it has settled.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, !inputFocused else { return }
        inputFocused = true
    }

    private func send() {
        let text = assistant.draft
        assistant.draft = ""
        settledDraft = ""
        assistant.submit(text)
    }
}

// MARK: - Input bar

private struct AssistantInputBar: View {
    var focused: FocusState<Bool>.Binding
    let predicted: TurnPath
    let onSend: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var assistant = appState.assistant
        let busy = assistant.busy
        HStack(spacing: 8) {
            IntentChip(path: busy ?? assistant.forced ?? predicted, isForced: assistant.forced != nil, isBusy: busy != nil) {
                assistant.cycleForced()
            }
            TextField(assistant.modelAvailable ? "Ask, search or change your plan" : "Search or change your plan", text: $assistant.draft)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .textInputAutocapitalization(.sentences)
                .frame(minHeight: 36)
            Button(action: onSend) {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy == .ask)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The input bar floats over the conversation: the controls layer, so Liquid Glass.
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// "Searching…" / "Asking…" / "Editing plan…": what the next turn will do. Tap chooses the path
/// (automatic → Search → Ask → Plan).
private struct IntentChip: View {
    let path: TurnPath
    let isForced: Bool
    let isBusy: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: Self.symbol(path))
                }
                Text(path.label)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isForced ? AnyShapeStyle(TintShapeStyle().opacity(0.25)) : AnyShapeStyle(.quaternary), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(path.label)
        .accessibilityHint(isForced ? "Chosen. Tap to choose another way to answer." : "Automatic. Tap to choose how to answer.")
    }

    static func symbol(_ path: TurnPath) -> String {
        switch path {
        case .search: return "magnifyingglass"
        case .ask: return "sparkles"
        case .plan: return "list.bullet.clipboard"
        }
    }
}

// MARK: - Conversation

private struct TurnView: View {
    let turn: AssistantController.Turn

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = turn.input {
                UserBubble(text: input)
            }
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { index, block in
                AssistantBlockView(block: block, turn: turn, index: index)
            }
            if turn.streaming && turn.blocks.isEmpty {
                WorkingRow(text: "Thinking on your iPhone…")
            }
            if let shared = turn.shared {
                SharedOfferButtons(turnId: turn.id, offer: shared)
            }
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(TintShapeStyle().opacity(0.18), in: .rect(cornerRadius: 18))
                .accessibilityLabel("You: \(text)")
        }
    }
}

private struct WorkingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct SharedOfferButtons: View {
    let turnId: Int
    let offer: AssistantController.SharedOffer

    @Environment(AppState.self) private var appState

    var body: some View {
        if offer.handled {
            Label("Added to your plan", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                Button("Use This Plan", systemImage: "checkmark") {
                    appState.assistant.useShared(turnId: turnId, merge: false)
                }
                .buttonStyle(.borderedProminent)
                Button("Merge with Mine", systemImage: "arrow.triangle.merge") {
                    appState.assistant.useShared(turnId: turnId, merge: true)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Typing and the empty state

/// Results as you type (nothing is sent; Return runs the full turn).
private struct LiveResults: View {
    let query: String

    @Environment(AppState.self) private var appState

    var body: some View {
        if let index = appState.searchIndex {
            let results = Array(index.search(query, now: .now).prefix(8))
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Matches").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(results) { result in
                        NavigationLink(value: result.target) {
                            HeartableResultRow(result: result)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onScreenEntity(result.target)
                        if result.id != results.last?.id { Divider() }
                    }
                }
                .blockCardBackground()
            }
        }
    }
}

/// Before anything is asked: Happening now, Up next, Liked and the categories.
private struct EmptyStateChips: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let ctx = appState.assistant.context() {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.assistant.modelAvailable
                     ? "Ask about the event, find things, or change your plan. Everything stays on your iPhone."
                     : "Search the event or change your plan. Everything stays on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                let chips = AssistantRouter.suggestionChips(ctx)
                ChipRow(chips: chips.enumerated().map { ChipItem(id: String($0.offset), label: $0.element.label) }) { item in
                    guard let i = Int(item.id), i < chips.count else { return }
                    appState.assistant.chip(chips[i])
                }
            }
        }
    }
}

// MARK: - Pinned plan

private struct PinnedPlanSection: View {
    @Binding var expanded: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.planner.hasPlan {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    PlanChangesCard()
                    AssistantPlanView(showsHeader: false, limit: 4)
                    PinnedPlanActions()
                }
                .padding(.top, 8)
            } label: {
                if let plan = appState.planner.plan {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("My plan", systemImage: "list.bullet.clipboard")
                            .font(.headline)
                        Text(Planner.summary(plan, timeZone: appState.timeZone))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else if AppState.plannerAvailable {
            MakePlanCard()
        }
    }
}

private struct PinnedPlanActions: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(assistant) }
            VStack(alignment: .leading, spacing: 8) { buttons(assistant) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func buttons(_ assistant: AssistantController) -> some View {
        if appState.tabs.contains(.schedule) {
            Button("Open in Schedule", systemImage: "calendar") { appState.showMyPlan() }
        }
        Button("Share", systemImage: "square.and.arrow.up") {
            assistant.run(AssistantAction(name: .sharePlan), label: "Share my plan", source: .manual)
        }
        if appState.planner.canUndo {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                assistant.run(AssistantAction(name: .planUndo), label: "Undo", source: .manual)
            }
        }
    }
}

/// Organizer changes (spec §6): which planned items moved or went, with Re-plan / Keep as Is.
private struct PlanChangesCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let changed = appState.assistant.live.changed
        if !changed.isEmpty {
            let names = changed.map { appState.currentBundle?.scheduleItem($0)?.name ?? "A removed item" }
            VStack(alignment: .leading, spacing: 8) {
                Label("Your plan changed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text("The organizers moved or removed: " + names.joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Re-plan") {
                        appState.replanFromNow()
                        appState.assistant.refreshLive()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Keep as Is") {
                        appState.keepChangedPlan()
                        appState.assistant.refreshLive()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        }
    }
}

/// No plan yet (model available): the event's examples make one in a tap.
private struct MakePlanCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let examples = appState.currentBundle.map { PlanRequest.examples($0, now: .now) } ?? []
        VStack(alignment: .leading, spacing: 10) {
            Label("Make a plan", systemImage: "wand.and.stars")
                .font(.headline)
            Text("Say what you'd like, or try one of these. Your iPhone plans it from the schedule, your likes and walking times.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(examples) { example in
                Button {
                    appState.assistant.submit(example.text, forced: example.isPlan ? .plan : .ask)
                } label: {
                    Label(example.text, systemImage: example.isPlan ? "sparkles" : "questionmark.bubble")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(appState.planner.isPlanning)
            }
        }
        .blockCardBackground()
    }
}

// MARK: - Live hints

private struct LiveHintsSection: View {
    let hints: LiveHints

    @Environment(AppState.self) private var appState

    var body: some View {
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let late = hints.runningLate {
                    HintCard(
                        text: late.text,
                        systemImage: late.state == .leaveNow ? "figure.walk.motion" : "exclamationmark.triangle.fill",
                        tint: .orange,
                        chips: late.chips
                    )
                }
                ForEach(hints.gaps, id: \.self) { gap in
                    HintCard(text: gap.text, systemImage: "clock.badge.questionmark", tint: .blue, chips: [gap.chip])
                }
                ForEach(hints.skipped, id: \.self) { chip in
                    SkippedHint(chip: chip)
                }
                if hints.recapReady {
                    HintCard(text: "That's your day. Want the recap?", systemImage: "sparkles", tint: .purple,
                             chips: [AssistantChip(label: "Show my recap", action: AssistantAction(name: .plan))],
                             onChip: { _ in appState.assistant.submit("recap", forced: .plan) })
                }
            }
        }
    }
}

private struct HintCard: View {
    let text: String
    let systemImage: String
    let tint: Color
    let chips: [AssistantChip]
    var onChip: ((AssistantChip) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            if !chips.isEmpty {
                ChipRow(chips: chips.enumerated().map { ChipItem(id: String($0.offset), label: $0.element.label) }) { item in
                    guard let i = Int(item.id), i < chips.count else { return }
                    if let onChip { onChip(chips[i]) } else { appState.assistant.chip(chips[i]) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 16))
    }
}

private struct SkippedHint: View {
    let chip: AssistantChip

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Button(chip.label) { appState.assistant.chip(chip) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            Button {
                appState.assistant.dismissSkipped(chip)
            } label: {
                Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}
