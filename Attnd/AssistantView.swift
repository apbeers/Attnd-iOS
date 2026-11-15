// AssistantView.swift
// Attnd (app target only — not in the App Clip)
//
// The My plan tab (plan tab spec, Nov 15, 2026): one screen that never turns into a conversation.
//   - `MyPlanTab`: its own NavigationStack (`AppState.planPath`: details opened from the plan, the
//     answer card and results), Options in the toolbar.
//   - `MyPlanScreen`: the timeline (PlanView.swift) scrolling above the bottom area, which sits on
//     the keyboard: the matches while typing, else the answer card (the last non-edit turn,
//     ≤ a third of the screen, scrollable inside, swipe down or × to dismiss), the proposal pill
//     ("−2 items, +1 lunch break" · Apply · ×), the Undo pill (~8 s) and the input bar
//     ("Change your plan or search…", intent chip Searching… / Asking… / Editing plan…).
//   - `SearchOverlay`: the same bar over the other tabs (the floating search button,
//     `floatingSearchButton()` in ContentView.swift): search answers there; a plan edit switches
//     to My plan with its preview.
// Screenshot mode and the App Clip have no My plan tab (EventSearchView.swift's sheet instead).

import SwiftUI

// MARK: - Tab

struct MyPlanTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        NavigationStack(path: $state.planPath) {
            MyPlanScreen()
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
                .navigationDestination(for: HeartedListRoute.self) { _ in
                    HeartedListView()
                }
        }
    }
}

struct MyPlanScreen: View {
    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    /// The draft the live results are for (debounced).
    @State private var settledDraft = ""
    @State private var predicted: TurnPath = .search
    @State private var height: CGFloat = 600

    private var assistant: AssistantController { appState.assistant }

    var body: some View {
        ScrollView {
            PlanTimeline()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AssistantBottomArea(
                focused: $inputFocused,
                predicted: predicted,
                settledDraft: settledDraft,
                maxCardHeight: height / 3,
                onSend: send
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .navigationTitle("My Plan")
        .navigationBarTitleDisplayMode(.inline)
        .eventStatusBanners()
        .optionsToolbarItem()
        // Distances on cards and the live hints (only while already permitted).
        .usesUserLocation(heading: true)
        .modifier(AssistantDraftTracking(settledDraft: $settledDraft, predicted: $predicted))
        .task {
            // Live hints once a minute while the tab is shown.
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
            // No plan yet: the input focused with the examples above it.
            guard !appState.planner.hasPlan, assistant.proposal == nil, !ScreenshotMode.isActive else { return }
            try? await Task.sleep(for: .milliseconds(450))
            inputFocused = true
        }
        .onChange(of: assistant.focusSerial) {
            guard appState.selectedTab == .plan else { return }
            inputFocused = true
        }
    }

    private func send() {
        let text = assistant.draft
        assistant.draft = ""
        settledDraft = ""
        assistant.submit(text)
    }
}

/// The intent chip and live results follow the typing, debounced; typing again hides the answer card.
private struct AssistantDraftTracking: ViewModifier {
    @Binding var settledDraft: String
    @Binding var predicted: TurnPath

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let assistant = appState.assistant
        content
            .onChange(of: assistant.draft) { _, text in
                if !text.isEmpty { assistant.dismissAnswer() }
            }
            .task(id: assistant.draft) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                settledDraft = assistant.draft
                predicted = assistant.predict(assistant.draft)
            }
    }
}

// MARK: - Bottom area (on the keyboard)

private struct AssistantBottomArea: View {
    var focused: FocusState<Bool>.Binding
    let predicted: TurnPath
    let settledDraft: String
    let maxCardHeight: CGFloat
    var onClose: (() -> Void)? = nil
    let onSend: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        let draft = settledDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let typing = !draft.isEmpty && assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines) == draft
        VStack(spacing: 8) {
            if typing, assistant.proposal == nil {
                LiveResults(query: draft, maxHeight: maxCardHeight)
            } else if let answer = assistant.answer {
                AnswerCard(turn: answer, maxHeight: maxCardHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let proposal = assistant.proposal, let preview = assistant.preview {
                ProposalPill(proposal: proposal, preview: preview)
            }
            if let pill = assistant.undoPill {
                UndoPillView(pill: pill)
            }
            AssistantInputBar(focused: focused, predicted: predicted, onClose: onClose, onSend: onSend)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: assistant.answer?.id)
        .animation(.snappy, value: assistant.proposal)
        .animation(.snappy, value: assistant.undoPill)
    }
}

// MARK: - Input bar

struct AssistantInputBar: View {
    var focused: FocusState<Bool>.Binding
    let predicted: TurnPath
    var onClose: (() -> Void)? = nil
    let onSend: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var assistant = appState.assistant
        let busy = assistant.busy
        HStack(spacing: 8) {
            IntentChip(path: busy ?? assistant.forced ?? predicted, isForced: assistant.forced != nil, isBusy: busy != nil) {
                assistant.cycleForced()
            }
            TextField("Change your plan or search…", text: $assistant.draft)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .onKeyPress(.escape) {
                    guard assistant.proposal != nil else { return .ignored }
                    assistant.clearProposal()
                    return .handled
                }
                .textInputAutocapitalization(.sentences)
                .frame(minHeight: 36)
            if let onClose {
                Button(action: onClose) {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
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

// MARK: - Answer card

/// The last non-edit turn, compact (≤ a third of the screen, scrollable inside). Swipe down or ×
/// dismisses it; typing again hides it.
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
        .frame(maxHeight: max(160, maxHeight))
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
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
        .padding(.top, 6)
    }
}

/// Results as you type (nothing is sent; Return runs the full turn).
private struct LiveResults: View {
    let query: String
    let maxHeight: CGFloat

    @Environment(AppState.self) private var appState

    var body: some View {
        if let index = appState.searchIndex {
            let results = Array(index.search(query, now: .now).prefix(8))
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(results) { result in
                            Button {
                                appState.open(result.target)
                            } label: {
                                HeartableResultRow(result: result)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .onScreenEntity(result.target)
                            if result.id != results.last?.id { Divider() }
                        }
                    }
                    .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: max(160, maxHeight))
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            }
        }
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

// MARK: - Over other tabs

/// The floating search button's bar over a tab other than My plan: matches while typing, the
/// answer card, and the bar itself (focused on open). A plan edit switches to My plan.
struct SearchOverlay: View {
    @Environment(AppState.self) private var appState
    @FocusState private var inputFocused: Bool
    @State private var settledDraft = ""
    @State private var predicted: TurnPath = .search
    @State private var height: CGFloat = 600

    var body: some View {
        let assistant = appState.assistant
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AssistantBottomArea(
                focused: $inputFocused,
                predicted: predicted,
                settledDraft: settledDraft,
                maxCardHeight: height / 3,
                onClose: { assistant.closeOverlay() },
                onSend: send
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .modifier(AssistantDraftTracking(settledDraft: $settledDraft, predicted: $predicted))
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            inputFocused = true
        }
        .onChange(of: assistant.focusSerial) { inputFocused = true }
        .onChange(of: inputFocused) { _, focused in
            // Keyboard down with nothing typed and nothing shown: the button comes back.
            if !focused, assistant.draft.isEmpty, assistant.answer == nil { assistant.closeOverlay() }
        }
    }

    private func send() {
        let assistant = appState.assistant
        let text = assistant.draft
        assistant.draft = ""
        settledDraft = ""
        assistant.submitFromOverlay(text)
    }
}
