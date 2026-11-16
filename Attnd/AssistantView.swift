// AssistantView.swift
// Attnd (app target only — not in the App Clip)
//
// The plan panel (iOS, Nov 16, 2026; Android keeps the shared plan tab spec's My plan tab): the
// floating Liquid Glass "My plan" button (`sparkles`, bottom-trailing, on every tab; it replaced the
// floating search button) opens a bottom panel over the current tab:
//   - Three snapping heights (`PlanPanelDetent`, rules in PlanPanel.swift): collapsed (grabber,
//     the one-line summary "Next: … · 7:00 PM · Main Stage" and the input bar), medium and large.
//     The grabber / header drags and snaps (a fling below collapsed closes it; tap toggles
//     collapsed ↔ medium; × closes). Collapsed and medium are Liquid Glass and the tab stays usable
//     above the panel; large is opaque, like a full-height system sheet.
//   - Body (medium / large): the plan timeline (PlanView.swift), previews of proposals in place.
//   - Dock, on the keyboard: the results pane (search results while typing — the previous results
//     stay until the next ones are ready, so it never blinks — with "Add to plan" / "Plan around
//     this" inline; otherwise the last answer card), the proposal pill, the Undo pill and the input
//     bar ("Change your plan or search…"). There is no Search / Ask / Plan toggle: the app decides.
// Why a custom panel and not `.sheet` + `presentationDetents`: a sheet covers the tab bar (tabs
// couldn't be switched with the plan open, and CLAUDE.md keeps the tab bar always visible), the
// tabs already present Options / Tour / search as their one `.sheet(item:)` (a second sheet
// can't be presented beside it), and links that switch tabs would have to dismiss and re-present
// it. The panel lives in each tab's content above the tab bar, follows the keyboard through the
// keyboard safe area, and its state (open, height, draft, proposal) is the AssistantController's,
// so it is the same on every tab.
// Screenshot mode and the App Clip have the floating search button and its sheet instead.

import SwiftUI

// MARK: - Host (every tab)

extension View {
    /// The floating "My plan" button, or the plan panel when it is open, over `tab`'s content.
    func planPanel(tab: EventTab) -> some View {
        modifier(PlanPanelModifier(tab: tab))
    }
}

private struct PlanPanelModifier: ViewModifier {
    let tab: EventTab

    @Environment(AppState.self) private var appState
    /// The collapsed panel's height without results or pills: the tab's content keeps that much
    /// bottom safe area while the panel is open, so lists scroll clear of it.
    @State private var reserved: CGFloat = 120

    func body(content: Content) -> some View {
        let open = appState.assistant.panelOpen
        ZStack {
            content
                .safeAreaPadding(.bottom, open ? reserved : FloatingSearchButtonMetrics.reservedHeight)
            ReservedRegionAvoiding {
                if open {
                    PlanPanelView(reserved: $reserved, isSelected: appState.selectedTab == tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            FloatingPlanButton {
                                appState.showPlanPanel()
                            }
                            .padding(.trailing, FloatingSearchButtonMetrics.trailingPadding)
                            .padding(.bottom, FloatingSearchButtonMetrics.bottomPadding)
                        }
                    }
                    // Stays put (under the keyboard) while a tab's own search field is typing.
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
                }
            }
        }
        .animation(.snappy, value: open)
    }
}

/// A Liquid Glass circle with sparkles ("My plan" for VoiceOver).
struct FloatingPlanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("My plan", systemImage: "sparkles")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: FloatingSearchButtonMetrics.size, height: FloatingSearchButtonMetrics.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("My plan")
        .accessibilityHint("Opens your plan. Type there to search, ask or change the plan.")
        .keyboardShortcut("f", modifiers: .command)
    }
}

// MARK: - Panel

private struct PlanPanelView: View {
    @Binding var reserved: CGFloat
    /// Its tab is the shown one (every tab has its own panel view; only that one takes focus and
    /// runs the live tasks).
    let isSelected: Bool

    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    /// Height available to the panel (the tab's content area above the tab bar or keyboard).
    @State private var available: CGFloat = 700
    /// The collapsed panel's own height (with whatever it shows).
    @State private var collapsedHeight: CGFloat = 120
    /// The panel's current height (for starting a drag).
    @State private var panelHeight: CGFloat = 120
    @State private var dragStart: CGFloat?
    @State private var dragHeight: CGFloat?
    /// The results pane: the last computed results and the text they are for.
    @State private var results: [EventSearchResult] = []
    @State private var resultsQuery: String?

    private var assistant: AssistantController { appState.assistant }

    private var detent: PlanPanelDetent { assistant.panelDetent }

    private var showsBody: Bool {
        if let dragHeight { return dragHeight > collapsedHeight + 24 }
        return detent != .collapsed
    }

    private var fixedHeight: CGFloat? {
        if let dragHeight { return dragHeight }
        guard detent != .collapsed else { return nil }
        return CGFloat(PlanPanelLayout.height(detent, available: Double(available), collapsed: Double(collapsedHeight)))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            panel
                .frame(maxWidth: 640)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { available = $0 }
        .modifier(PanelResultsTracking(results: $results, resultsQuery: $resultsQuery))
        .modifier(PanelFocus(focused: $inputFocused, isSelected: isSelected))
        .modifier(PanelLiveTasks(isSelected: isSelected, expanded: detent != .collapsed))
    }

    private var panel: some View {
        let opaque = detent == .large && dragHeight == nil
        return VStack(spacing: 0) {
            PlanPanelHeader(collapsed: !showsBody, onToggle: toggle)
                .gesture(dragGesture)
            if showsBody {
                ScrollView {
                    PlanTimeline()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
            PlanPanelDock(
                focused: $inputFocused,
                results: results,
                resultsQuery: resultsQuery,
                maxPaneHeight: max(160, available / 3),
                onSend: send
            )
        }
        .frame(height: fixedHeight)
        .modifier(PanelBackground(opaque: opaque))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            panelHeight = height
            guard dragHeight == nil, detent == .collapsed else { return }
            collapsedHeight = height
            let plain = assistant.draft.isEmpty && assistant.answer == nil && assistant.proposal == nil && assistant.undoPill == nil
            // + the panel's bottom padding.
            if plain, abs(reserved - (height + 4)) > 0.5 { reserved = height + 4 }
        }
        .animation(dragHeight == nil ? Animation.snappy : nil, value: detent)
        .accessibilityAction(named: detent == .large ? "Make smaller" : "Make bigger") {
            assistant.panelDetent = detent == .collapsed ? .medium : detent == .medium ? .large : .medium
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? panelHeight
                if dragStart == nil { dragStart = start }
                dragHeight = CGFloat(PlanPanelLayout.dragHeight(
                    start: Double(start), translation: Double(value.translation.height),
                    available: Double(available), collapsed: Double(collapsedHeight)
                ))
            }
            .onEnded { value in
                let start = dragStart ?? panelHeight
                let predicted = Double(start - value.predictedEndTranslation.height)
                let snapped = PlanPanelLayout.snap(predicted: predicted, available: Double(available), collapsed: Double(collapsedHeight))
                withAnimation(.snappy) {
                    dragStart = nil
                    dragHeight = nil
                    if let snapped {
                        assistant.panelDetent = snapped
                        if snapped == .collapsed { inputFocused = false }
                    } else {
                        assistant.closePanel()
                    }
                }
            }
    }

    private func toggle() {
        withAnimation(.snappy) {
            assistant.panelDetent = detent == .collapsed ? .medium : .collapsed
        }
    }

    private func send() {
        let text = assistant.draft
        assistant.draft = ""
        resultsQuery = nil
        results = []
        assistant.submit(text)
    }
}

/// Liquid Glass while the tab shows above it (collapsed, medium); opaque at full height.
private struct PanelBackground: ViewModifier {
    let opaque: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        if opaque {
            content
                .background(Color(.systemBackground), in: shape)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.15), radius: 16, y: 2)
        } else {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        }
    }
}

/// The search results for the typed text, debounced; the previous ones stay until then.
private struct PanelResultsTracking: ViewModifier {
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

/// Keyboard up / down when the controller asks (a request typed elsewhere, opening without a
/// plan; an item opened from the panel).
private struct PanelFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding
    let isSelected: Bool

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let assistant = appState.assistant
        content
            .task(id: isSelected) {
                guard isSelected else { return }
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled, assistant.consumeFocusRequest() { focused.wrappedValue = true }
            }
            .onChange(of: assistant.focusSerial) {
                if isSelected, assistant.consumeFocusRequest() { focused.wrappedValue = true }
            }
            .onChange(of: assistant.blurSerial) {
                focused.wrappedValue = false
            }
    }
}

/// While the panel is shown: live hints once a minute; distances (and live hints' position) while
/// it is expanded and location is already permitted.
private struct PanelLiveTasks: ViewModifier {
    let isSelected: Bool
    let expanded: Bool

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .usesUserLocation(heading: true, active: isSelected && expanded)
            .task(id: isSelected) {
                guard isSelected else { return }
                while !Task.isCancelled {
                    appState.assistant.refreshLive()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }
}

// MARK: - Header

private struct PlanPanelHeader: View {
    let collapsed: Bool
    let onToggle: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let line = appState.currentBundle.map {
            PlanPanel.summaryLine(plan: appState.planner.plan, $0, now: .now)
        } ?? ""
        VStack(spacing: 6) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 6)
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 1) {
                    Text("My Plan")
                        .font(.subheadline.weight(.semibold))
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    appState.assistant.closePanel()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 6)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .contain)
        .accessibilityHint(collapsed ? "Double-tap to show your plan." : "Double-tap to make the panel smaller.")
    }
}

// MARK: - Dock (on the keyboard)

private struct PlanPanelDock: View {
    var focused: FocusState<Bool>.Binding
    let results: [EventSearchResult]
    let resultsQuery: String?
    let maxPaneHeight: CGFloat
    let onSend: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        let pane = PlanPanel.pane(
            draft: assistant.draft, resultsQuery: resultsQuery,
            hasAnswer: assistant.answer != nil, proposalOptions: assistant.proposal?.options.count
        )
        VStack(spacing: 8) {
            switch pane {
            case .results:
                ResultsPane(results: results, query: resultsQuery ?? "", maxHeight: maxPaneHeight, focused: focused)
                    .transition(.opacity)
            case .answer:
                if let answer = assistant.answer {
                    AnswerCard(turn: answer, maxHeight: maxPaneHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case .none:
                EmptyView()
            }
            if let proposal = assistant.proposal, let preview = assistant.preview {
                ProposalPill(proposal: proposal, preview: preview)
            }
            if let pill = assistant.undoPill {
                UndoPillView(pill: pill)
            }
            AssistantInputBar(focused: focused, onSend: onSend)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.snappy, value: pane)
        .animation(.snappy, value: assistant.answer?.id)
        .animation(.snappy, value: assistant.proposal)
        .animation(.snappy, value: assistant.undoPill)
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
                        assistant.panelDetent = .collapsed
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
                    Text(appState.assistant.modelAvailable
                         ? "Nothing matches “\(query)”. Press Return to ask."
                         : "Nothing matches “\(query)”. Press Return to try it as a request.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(results) { result in
                    let action = ctx.flatMap { ctx in Self.ref(result.target).flatMap { PlanPanel.resultAction($0, ctx) } }
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
    let action: PanelResultAction?
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
            .onScreenEntity(result.target)
            if let action {
                actionView(action)
            }
        }
    }

    @ViewBuilder
    private func actionView(_ action: PanelResultAction) -> some View {
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
