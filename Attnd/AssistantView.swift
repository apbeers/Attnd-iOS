// AssistantView.swift
// Attnd (app + App Clip)
//
// The plan page's frame (planner_view_spec, iOS, Nov 19, 2026; it replaced the snapping plan
// panel). Only with Apple Intelligence's on-device model (`AppState.hasAssistant`); without it
// (and in screenshot mode) the floating search button and sheet instead.
//   - Closed: the floating Liquid Glass "My plan" button (`sparkles`, bottom-trailing on every
//     tab) with a small peek of the plan ("Next: Juniper Lane · 11:00 AM · Main Stage",
//     `PlanDock.summaryLine`).
//   - Open: a full-screen cover (`PlanPageHost`, presented by ContentView) with its own
//     navigation stack (`AssistantController.pagePath`: cards tapped on the page push the item's
//     normal detail; Back returns to the plan) and a Close button.
//   - Phones (compact width): the plan page (PlanView.swift) with the dock on the keyboard: the
//     small pane (search results while typing — the previous ones stay until the next are ready —
//     with "Add to plan" / "Plan around this", or the last answer card), the proposal pill (with
//     "Also fill this gap?" after a Remove), the Undo pill, the bottom bar (PlanView.swift) and
//     the glass text box "Change your plan or search…", the only control. No chat transcript.
//   - Wide windows (iPhone Duo unfolded, regular width): side by side — a chat column (this
//     session's turns with their blocks, the dock) on the leading side and the plan page on the
//     trailing side, one controller for both; split on the fold by `ArrangementView` (iOS 27.1
//     SDK, `PlanArrangement`), at the top of the cover only.
// There is no Search / Ask / Plan toggle: the app picks the path of every turn.

import SwiftUI

// MARK: - The My plan button (every tab)

extension View {
    /// The floating "My plan" button (with its peek) over a tab's content.
    func planButton() -> some View {
        modifier(PlanButtonModifier())
    }
}

private struct PlanButtonModifier: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        // Siblings in a ZStack: the extra safe area applies to the content only, so the button
        // itself sits right above the tab bar (as the search button does).
        ZStack {
            content
                .safeAreaPadding(.bottom, FloatingSearchButtonMetrics.reservedHeight)
            ReservedRegionAvoiding {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        FloatingPlanButton(peek: appState.planButtonPeek) {
                            appState.openPlanPage()
                        }
                        .debugFloatingFrame("plan_button")
                        .padding(.trailing, FloatingSearchButtonMetrics.trailingPadding)
                        .padding(.bottom, FloatingSearchButtonMetrics.bottomPadding)
                    }
                }
                // Stays put (under the keyboard) while a tab's own search field is typing.
                .ignoresSafeArea(.keyboard)
            }
        }
    }
}

extension AppState {
    /// The My plan button's peek: "Next: …" once there is a plan; nil without one (just the icon).
    var planButtonPeek: String? {
        guard let bundle = currentBundle, let plan = planner.plan, !plan.isEmpty else { return nil }
        return PlanDock.summaryLine(plan: plan, bundle, now: .now)
    }
}

/// A Liquid Glass capsule with sparkles and the plan's peek ("My plan" for VoiceOver).
struct FloatingPlanButton: View {
    var peek: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                if let peek {
                    Text(peek)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 200, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, peek == nil ? 0 : 14)
            .frame(minWidth: FloatingSearchButtonMetrics.size, minHeight: FloatingSearchButtonMetrics.size)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("My plan")
        .accessibilityValue(peek ?? "")
        .accessibilityHint("Opens your plan. Type there to search, ask or change the plan.")
        .accessibilityAddTraits(.isButton)
        .keyboardShortcut("f", modifiers: .command)
    }
}

// MARK: - The page (full-screen cover)

/// The cover's root: My plan is one continuous chat (iOS, Nov 21, 2026). Compact width (phones,
/// iPhone Duo folded): the chat alone. Regular width (iPhone Duo unfolded): the chat column and
/// the last component it showed, large, side by side (`PlanArrangement`: split on the fold, at the
/// top of the cover only). All state (transcript, composer text, proposal, working line) is the
/// controller's, so folding mid-conversation keeps it.
struct PlanPageHost: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PlanArrangement {
                    PlanChatStack()
                } secondary: {
                    NavigationStack {
                        LastComponentPane()
                            .navigationTitle("My Schedule")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            } else {
                PlanChatStack()
            }
        }
        .modifier(PageLiveTasks())
    }
}

/// The chat in its own navigation stack (cards tapped in it push the item's detail).
private struct PlanChatStack: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var assistant = appState.assistant
        NavigationStack(path: $assistant.pagePath) {
            // The chat, its composer, chips, working line and Undo card keep clear of the fold and
            // the camera housings (iPhone Duo; nothing to avoid on other iPhones).
            ReservedRegionAvoiding {
                PlanChatView()
            }
                .navigationTitle("My Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { PageCloseItem() }
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
                .navigationDestination(for: HeartedListRoute.self) { route in
                    HeartedListView(savedPlacesOnly: route.savedPlacesOnly)
                }
        }
    }
}

/// Wide layouts: the last component the chat showed (not text or chips), large; before any, the
/// day in My schedule.
private struct LastComponentPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        let turns = assistant.transcript + (assistant.answer.map { [$0] } ?? [])
        let last = turns.reversed().lazy.compactMap { turn -> (AssistantController.Turn, Int, AssistantBlock)? in
            guard let index = turn.blocks.lastIndex(where: { !$0.isChips && $0.type != "text" && $0.type != "confirm" }) else { return nil }
            return (turn, index, turn.blocks[index])
        }.first
        ScrollView {
            Group {
                if let last {
                    AssistantBlockView(block: last.2, turn: last.0, index: last.1)
                } else {
                    ComponentView(component: Component(type: "my_day"))
                }
            }
            .padding(16)
        }
    }
}


private struct PageCloseItem: ToolbarContent {
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark", role: .close) {
                appState.assistant.closePage()
            }
        }
    }
}

/// Chat column + plan page side by side; `ArrangementView` (iOS 27.1, iPhone Duo) splits them on
/// the fold. Older systems and SDKs: an HStack with the plan taking ~60 %.
private struct PlanArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        #if IOS27_SDK
        if #available(iOS 27.1, *) {
            // Side by side only when the container is wider than tall (Apple's "Preparing your app
            // for iPhone Duo"): a tall inner display shows the chat alone; split on the fold.
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                primary
                    .frame(width: max(320, proxy.size.width * 0.4))
                Divider()
                secondary
            }
        }
    }
}

/// Keyboard up / down when the controller asks (no plan yet, a request typed elsewhere).
private struct DockFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let assistant = appState.assistant
        content
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled, assistant.consumeFocusRequest() { focused.wrappedValue = true }
            }
            .onChange(of: assistant.focusSerial) {
                if assistant.consumeFocusRequest() { focused.wrappedValue = true }
            }
            .onChange(of: assistant.blurSerial) {
                focused.wrappedValue = false
            }
    }
}

/// While the page is shown: live hints once a minute, distances (location already permitted).
private struct PageLiveTasks: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .usesUserLocation(heading: false)
            .task {
                while !Task.isCancelled {
                    appState.assistant.refreshLive()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }
}

// MARK: - The chat

/// My plan as one chat: the history (per event, ≤ 40 turns), each answer's text and components
/// inline and interactive, the working line while a turn runs, a pending plan change as a card
/// with Apply, the Undo card after one, follow-up chips above the composer. Typing does nothing
/// until Return. Before anything is asked: the day in My schedule.
private struct PlanChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    var body: some View {
        let assistant = appState.assistant
        let chips = followUps
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if assistant.transcript.isEmpty && assistant.answer == nil {
                        ComponentView(component: Component(type: "my_day"))
                    }
                    ForEach(assistant.transcript) { turn in
                        ChatTurnView(turn: turn, hidesChips: turn.id == assistant.transcript.last?.id)
                            .id(turn.id)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    if let answer = assistant.answer, answer.streaming || !assistant.transcript.contains(where: { $0.id == answer.id }) {
                        ChatTurnView(turn: answer, hidesChips: true)
                            .id(answer.id)
                    }
                    if let stage = assistant.stage, assistant.busy != nil {
                        WorkingLine(text: stage)
                            .id("working")
                    }
                    if let proposal = assistant.proposal, let preview = assistant.preview {
                        ProposalCard(proposal: proposal, preview: preview)
                            .id("proposal")
                    }
                    if let pill = assistant.undoPill {
                        UndoPillView(pill: pill)
                            .id("undo")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: assistant.transcript.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: assistant.transcript.last?.id) { scrollDown(proxy) }
            .onChange(of: assistant.proposal) { scrollDown(proxy) }
            .onChange(of: assistant.stage) { scrollDown(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if !chips.isEmpty, assistant.busy == nil {
                    ChipRow(chips: chips.enumerated().map { ChipItem(id: String($0.offset), label: $0.element.label) }) { item in
                        guard let index = Int(item.id), index < chips.count else { return }
                        assistant.chip(chips[index])
                    }
                    .padding(.horizontal, 6)
                }
                AssistantInputBar(focused: $inputFocused, onSend: send)
                    .debugFloatingFrame("composer")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .modifier(DockFocus(focused: $inputFocused))
    }

    private var followUps: [AssistantChip] {
        guard let last = appState.assistant.transcript.last else { return [] }
        for case .chips(let chips) in last.blocks.reversed() { return chips }
        return []
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func send() {
        let text = appState.assistant.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32)) {
            appState.assistant.draft = ""
            appState.assistant.submit(text)
        }
    }
}

/// The thin working line: a spinning ring and the current stage ("Searching…", "Adding Taco Row…").
private struct WorkingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A pending plan change as a card in the chat: what it does, its options (each an Apply), Cancel.
private struct ProposalCard: View {
    let proposal: PlanProposal
    let preview: PlanPreview

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        VStack(alignment: .leading, spacing: 10) {
            Label(preview.pill, systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold))
            if !proposal.text.isEmpty, proposal.text != preview.pill {
                Text(proposal.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(proposal.options.prefix(PlanProposal.maxOptions).enumerated()), id: \.offset) { index, option in
                Button {
                    assistant.applyProposal(index)
                } label: {
                    Label(proposal.options.count == 1 ? "Apply" : option.label, systemImage: "checkmark")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Cancel", systemImage: "xmark", role: .cancel) {
                assistant.clearProposal()
            }
            .buttonStyle(.bordered)
        }
        .blockCardBackground()
    }
}

/// One turn: what was typed (a right bubble), the done line, then the answer's components.
private struct ChatTurnView: View {
    let turn: AssistantController.Turn
    /// The last turn's chips are above the composer instead.
    var hidesChips = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let input = turn.input, !input.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    Text(input)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 18))
                }
            }
            if let status = turn.status, !turn.streaming {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { index, block in
                if !(hidesChips && block.isChips) {
                    AssistantBlockView(block: block, turn: turn, index: index)
                }
            }
        }
    }
}

// MARK: - Input bar

struct AssistantInputBar: View {
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var assistant = appState.assistant
        let busy = assistant.busy
        HStack(spacing: 8) {
            if busy != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(busy == .ask ? "Thinking" : busy == .plan ? "Planning" : "Working")
            }
            TextField("Ask, or change your schedule…", text: $assistant.draft)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .onKeyPress(.escape) {
                    if assistant.proposal != nil {
                        assistant.clearProposal()
                    } else {
                        focused.wrappedValue = false
                    }
                    return .handled
                }
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
        // The input bar floats over the content: the controls layer, so Liquid Glass.
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Results pane


// MARK: - Answer card


// MARK: - Pills


/// "Removed Velvet Mesquite. · Undo" for ~8 s after a plan change.
private struct UndoPillView: View {
    let pill: AssistantController.UndoPill

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Text(pill.text)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", systemImage: "arrow.uturn.backward") {
                appState.assistant.undoLastChange()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .task(id: pill.id) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            appState.assistant.expireUndo(pill.id)
        }
    }
}
