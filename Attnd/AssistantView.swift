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

/// The cover's root: compact → the plan page with the dock; regular width → chat column + page.
struct PlanPageHost: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PlanArrangement {
                    NavigationStack {
                        ChatColumn()
                            .navigationTitle("Assistant")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { PageCloseItem() }
                    }
                } secondary: {
                    PlanPageStack(showsDock: false)
                }
            } else {
                PlanPageStack(showsDock: true)
            }
        }
        .modifier(PageLiveTasks())
    }
}

/// The plan page in its own navigation stack (item details pushed from the page).
private struct PlanPageStack: View {
    /// Phones: the dock (results, pills, bottom bar, text box) on the keyboard. Wide: only the
    /// bottom bar (the chat column has the text box).
    let showsDock: Bool

    @Environment(AppState.self) private var appState
    @State private var available: CGFloat = 700

    var body: some View {
        @Bindable var assistant = appState.assistant
        NavigationStack(path: $assistant.pagePath) {
            PlanPageView()
                .navigationTitle("My Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if showsDock { PageCloseItem() }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        PlanBottomBar()
                        if showsDock {
                            PlanDockView(maxPaneHeight: max(160, available / 3))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, showsDock ? 0 : 10)
                }
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
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
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split)
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

// MARK: - Dock (phones; the chat column has its own)

private struct PlanDockView: View {
    let maxPaneHeight: CGFloat

    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    @State private var results: [EventSearchResult] = []
    @State private var resultsQuery: String?

    var body: some View {
        let assistant = appState.assistant
        let pane = PlanDock.pane(
            draft: assistant.draft, resultsQuery: resultsQuery,
            hasAnswer: assistant.answer != nil, proposalOptions: assistant.proposal?.options.count
        )
        VStack(spacing: 8) {
            switch pane {
            case .results:
                ResultsPane(results: results, query: resultsQuery ?? "", maxHeight: maxPaneHeight, focused: $inputFocused)
                    .transition(.opacity)
            case .answer:
                if let answer = assistant.answer {
                    AnswerCard(turn: answer, maxHeight: maxPaneHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .none:
                EmptyView()
            }
            DockPills()
            AssistantInputBar(focused: $inputFocused, onSend: send)
        }
        .padding(.bottom, 8)
        .animation(.snappy, value: pane)
        .animation(.snappy, value: assistant.answer?.id)
        .animation(.snappy, value: assistant.proposal)
        .animation(.snappy, value: assistant.undoPill)
        .modifier(DockResultsTracking(results: $results, resultsQuery: $resultsQuery))
        .modifier(DockFocus(focused: $inputFocused))
    }

    private func send() {
        let text = appState.assistant.draft
        appState.assistant.draft = ""
        resultsQuery = nil
        results = []
        appState.assistant.submit(text)
    }
}

/// The proposal pill (+ "Also fill this gap?" after a Remove) and the Undo pill.
private struct DockPills: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        if let proposal = assistant.proposal, let preview = assistant.preview {
            ProposalPill(proposal: proposal, preview: preview)
            FillGapChips(proposal: proposal)
        }
        if let pill = assistant.undoPill {
            UndoPillView(pill: pill)
        }
    }
}

/// After a row's Remove: "Also fill this gap?" with the gap's ideas (each a new proposal).
private struct FillGapChips: View {
    let proposal: PlanProposal

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        if let bundle = appState.currentBundle, let removal = PlanPage.removal(proposal, bundle, now: .now) {
            let ideas = PlanPage.fillIdeas(removal.edit, removed: removal.itemId, bundle, appState.likeSet, now: .now)
            if !ideas.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also fill this gap?")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ChipRow(chips: ideas.map { ChipItem(id: String($0), label: bundle.scheduleItem($0)?.name ?? "An item") }) { chip in
                        guard let id = Int(chip.id) else { return }
                        let removedName = bundle.scheduleItem(removal.itemId)?.name ?? "it"
                        let name = bundle.scheduleItem(id)?.name ?? "it"
                        assistant.proposeEdit([.replace(item: removal.itemId, with: id)], label: "Swap \(removedName) for \(name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
            }
        }
    }
}

/// The search results for the typed text, debounced; the previous ones stay until then.
private struct DockResultsTracking: ViewModifier {
    @Binding var results: [EventSearchResult]
    @Binding var resultsQuery: String?

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let draft = appState.assistant.draft
        content.task(id: draft) {
            let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                resultsQuery = nil
                results = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let index = appState.searchIndex else { return }
            let found = Array(index.search(query, now: .now).prefix(8))
            withAnimation(.snappy) {
                results = found
                resultsQuery = query
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

// MARK: - Chat column (wide windows)

private struct ChatColumn: View {
    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    @State private var results: [EventSearchResult] = []
    @State private var resultsQuery: String?

    var body: some View {
        let assistant = appState.assistant
        let pane = PlanDock.pane(
            draft: assistant.draft, resultsQuery: resultsQuery,
            hasAnswer: false, proposalOptions: assistant.proposal?.options.count
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if assistant.transcript.isEmpty && assistant.answer == nil {
                        ChatEmptyState()
                    }
                    ForEach(assistant.transcript) { turn in
                        ChatTurnView(turn: turn)
                            .id(turn.id)
                    }
                    if let answer = assistant.answer, answer.streaming || !assistant.transcript.contains(where: { $0.id == answer.id }) {
                        ChatTurnView(turn: answer)
                            .id(answer.id)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: assistant.transcript.last?.id) {
                if let id = assistant.transcript.last?.id {
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if pane == .results {
                    ResultsPane(results: results, query: resultsQuery ?? "", maxHeight: 260, focused: $inputFocused)
                }
                DockPills()
                AssistantInputBar(focused: $inputFocused, onSend: send)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .animation(.snappy, value: pane)
        }
        .modifier(DockResultsTracking(results: $results, resultsQuery: $resultsQuery))
        .modifier(DockFocus(focused: $inputFocused))
    }

    private func send() {
        let text = appState.assistant.draft
        appState.assistant.draft = ""
        resultsQuery = nil
        results = []
        appState.assistant.submit(text)
    }
}

private struct ChatEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ask or change your plan", systemImage: "sparkles")
                .font(.headline)
            Text("Type what you'd like below — \"swap the next thing\", \"where are the restrooms?\", \"no food until 3\". Everything stays on your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// One turn of the chat column: what was typed, then the answer's blocks.
private struct ChatTurnView: View {
    let turn: AssistantController.Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let input = turn.input, !input.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    Text(input)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 16))
                }
            }
            ForEach(Array(turn.blocks.enumerated()), id: \.offset) { index, block in
                AssistantBlockView(block: block, turn: turn, index: index)
            }
            if turn.streaming && turn.blocks.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Thinking on your iPhone…").foregroundStyle(.secondary)
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
            TextField("Change your plan or search…", text: $assistant.draft)
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

/// Results as you type (nothing is sent; Return runs the full turn), with inline plan actions.
private struct ResultsPane: View {
    let results: [EventSearchResult]
    let query: String
    let maxHeight: CGFloat
    var focused: FocusState<Bool>.Binding

    @Environment(AppState.self) private var appState

    var body: some View {
        let ctx = appState.assistant.context()
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if results.isEmpty {
                    Text("Nothing matches “\(query)”. Press Return to ask.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(results) { result in
                    let action = ctx.flatMap { ctx in Self.ref(result.target).flatMap { PlanDock.resultAction($0, ctx) } }
                    ResultLine(result: result, action: action, focused: focused)
                    if result.id != results.last?.id { Divider() }
                }
            }
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    /// Search targets as assistant references (the event itself has no plan action).
    static func ref(_ target: SearchTarget) -> EntityRef? {
        switch target {
        case .location(let id): return EntityRef(kind: .location, id: id)
        case .scheduleItem(let id): return EntityRef(kind: .schedule, id: id)
        case .notification(let id): return EntityRef(kind: .update, id: id)
        case .event: return nil
        }
    }
}

private struct ResultLine: View {
    let result: EventSearchResult
    let action: DockResultAction?
    var focused: FocusState<Bool>.Binding

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Button {
                focused.wrappedValue = false
                appState.open(result.target)
            } label: {
                HeartableResultRow(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let action {
                actionView(action)
            }
        }
    }

    @ViewBuilder
    private func actionView(_ action: DockResultAction) -> some View {
        switch action {
        case .inPlan:
            Image(systemName: action.systemImage)
                .foregroundStyle(.tint)
                .accessibilityLabel(action.label)
        case .addToPlan(let id):
            Button(action.label, systemImage: action.systemImage) {
                appState.assistant.draft = ""
                appState.assistant.addToPlan(id)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("\(action.label): \(result.title)")
        case .planAround(let id):
            Button(action.label, systemImage: action.systemImage) {
                appState.assistant.draft = ""
                appState.assistant.planAround(id)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("\(action.label): \(result.title)")
        }
    }
}

// MARK: - Answer card

/// The last non-edit turn, compact (≤ a third of the window, scrollable inside). Swipe down or ×
/// dismisses it; results replace it while typing.
private struct AnswerCard: View {
    let turn: AssistantController.Turn
    let maxHeight: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            AnswerCardHandle()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(turn.blocks.enumerated()), id: \.offset) { index, block in
                        AssistantBlockView(block: block, turn: turn, index: index)
                    }
                    if turn.streaming && turn.blocks.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Thinking on your iPhone…").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .gesture(DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > 60 { appState.assistant.dismissAnswer() }
        })
        .accessibilityAction(named: "Dismiss") { appState.assistant.dismissAnswer() }
    }
}

private struct AnswerCardHandle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                appState.assistant.dismissAnswer()
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

// MARK: - Pills

/// The shown proposal: "−2 items, +1 lunch break" with Apply (one option, or each option of a
/// change such as a shared plan), or "Pick one of 3" when the options are rows; × clears it.
private struct ProposalPill: View {
    let proposal: PlanProposal
    let preview: PlanPreview

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(.tint)
            Text(preview.pill)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !proposal.hasOptionRows || proposal.options.count == 1 {
                ForEach(Array(proposal.options.prefix(2).enumerated()), id: \.offset) { index, option in
                    Button(proposal.options.count == 1 ? "Apply" : option.label) {
                        assistant.applyProposal(index)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
            }
            Button {
                assistant.clearProposal()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(proposal.text)
    }
}

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
