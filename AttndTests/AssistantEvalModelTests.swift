// AssistantEvalModelTests.swift
// AttndTests
//
// The assistant eval in model mode: every question through the real on-device path
// (`EventAssistant.assistantTurn`, Foundation Models tools; the router answers when the model
// fails, as in the app). Never part of the normal run:
//   - needs ATTND_ASSISTANT_EVAL=model (or all); xcodebuild passes TEST_RUNNER_ATTND_ASSISTANT_EVAL;
//   - skipped unless `SystemLanguageModel.default` is available (Apple Intelligence on: a Mac with
//     Apple silicon running the simulator, or an iPhone that supports it).
// Writes assistant-eval-ios-model-<time>.json (ATTND_ASSISTANT_EVAL_OUT, else build/assistant-eval/)
// and attaches it to the test result. Wrong answers never fail the test: the report is the result.
// How to run: attnd-web docs/assistant_eval/README.md → Model mode.

import XCTest
@testable import Attnd
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AssistantEvalModelTests: XCTestCase {

    func testModelEval() async throws {
        try XCTSkipUnless(AssistantEvalTests.enabled(.model), "Set ATTND_ASSISTANT_EVAL=model (TEST_RUNNER_ATTND_ASSISTANT_EVAL via xcodebuild) to run the model eval.")
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence's on-device model isn't available here (\(SystemLanguageModel.default.availability)).")
        }
        var runner = AssistantEvalRunner(mode: .model) { input, ctx, conversation in
            let retrieved = AssistantModel.retrieve(input, ctx)
            do {
                let out = try await EventAssistant.assistantTurn(input, ctx, conversation: conversation, retrieved: retrieved) { _, _, _ in }
                return ModelTurnOutputLike(text: out.text, shown: out.shown, actions: out.actions, toolCalls: out.toolCalls)
            } catch {
                print("model error for \"\(input)\": \(error)")
                return nil
            }
        }
        runner.beginQuestion = { AssistantSessionStore.shared.reset() }
        let report = await AssistantEvalTests.runAll(runner)
        let path = report.write(now: runner.catalogue.fixture.now)
        print(report.summary + "\nReport: \(path)")
        let attachment = XCTAttachment(string: report.json(now: runner.catalogue.fixture.now))
        attachment.name = "assistant-eval-ios-model.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        #else
        throw XCTSkip("FoundationModels isn't in this SDK.")
        #endif
    }
}
