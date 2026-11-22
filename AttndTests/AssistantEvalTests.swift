// AssistantEvalTests.swift
// AttndTests
//
// The assistant eval in router mode (attnd-web docs/assistant_eval/README.md).
//   - testCatalogueMatchesTheFixture (always): the catalogue is well formed and every entity it
//     names exists in the DEMO bundle, so a DEMO change can't silently empty a check.
//   - testCriticalQuestionsRouter (always, fast): the `critical` questions (safety, injection,
//     invented facts, core finding) pass on the rule-based router.
//   - testRouterEval (opt-in: ATTND_ASSISTANT_EVAL=router or all; through xcodebuild
//     TEST_RUNNER_ATTND_ASSISTANT_EVAL): every question, a JSON report, a summary in the log;
//     never fails on a wrong answer (the report is the result).

import XCTest
@testable import Attnd

@MainActor
final class AssistantEvalTests: XCTestCase {

    static func enabled(_ mode: EvalMode) -> Bool {
        let value = (ProcessInfo.processInfo.environment["ATTND_ASSISTANT_EVAL"] ?? "").lowercased()
        return value == "all" || value == "1" || value.split(separator: ",").contains(Substring(mode.rawValue))
    }

    func testCatalogueMatchesTheFixture() {
        let runner = AssistantEvalRunner(mode: .router)
        let catalogue = runner.catalogue
        XCTAssertEqual(catalogue.version, 1)
        XCTAssertGreaterThanOrEqual(catalogue.questions.count, 150)
        var ids = Set<String>()
        var known = Set<String>(runner.bundle.locations.map(\.name))
        known.formUnion(runner.bundle.schedule.map(\.name))
        known.formUnion(runner.bundle.notifications.map(\.title))
        let rules: Set<String> = ["invented_phone", "invented_url", "invented_email", "invented_price", "ids_in_text", "json_in_text",
                                  "reveal_prompt", "invented_lockers", "invented_wifi", "invented_forecast", "claims_taylor", "claims_fireworks"]
        func names(in e: EvalExpect) -> [String] {
            var out: [String] = e.entitiesAny ?? []
            out += e.entitiesAll ?? []
            out += e.entitiesNone ?? []
            out += (e.actionsAny ?? []).compactMap(\.target)
            for alternative in e.anyOf ?? [] { out += names(in: alternative) }
            return out
        }
        func rulesIn(_ e: EvalExpect) -> [String] { (e.mustNot ?? []) + (e.anyOf ?? []).flatMap(rulesIn) }
        for q in catalogue.questions {
            XCTAssertTrue(ids.insert(q.id).inserted, "duplicate id \(q.id)")
            for id in q.follows ?? [] { XCTAssertNotNil(catalogue.question(id), "\(q.id) follows unknown \(id)") }
            for e in [q.expect, q.expectModel, q.expectRouter].compactMap({ $0 }) {
                for name in names(in: e) { XCTAssertTrue(known.contains(name), "\(q.id): \(name) is not in the DEMO bundle") }
                for rule in rulesIn(e) { XCTAssertTrue(rules.contains(rule), "\(q.id): unknown rule \(rule)") }
            }
        }
        _ = runner.baseContext()  // the fixture's My schedule entries exist
    }

    func testCriticalQuestionsRouter() async {
        let runner = AssistantEvalRunner(mode: .router)
        let grader = AssistantEvalGrader(bundle: runner.bundle, now: runner.now)
        for q in runner.catalogue.questions where q.critical == true {
            let outcome = await runner.run(q)
            let grade = grader.grade(q, outcome, mode: .router)
            XCTAssertTrue(grade.passed, "\(q.id) \"\(q.text)\": \(grade.failures.joined(separator: "; ")) — answer: \(grader.answerText(outcome))")
        }
    }

    func testRouterEval() async throws {
        try XCTSkipUnless(Self.enabled(.router), "Set ATTND_ASSISTANT_EVAL=router (TEST_RUNNER_ATTND_ASSISTANT_EVAL via xcodebuild) to run the full router eval.")
        let runner = AssistantEvalRunner(mode: .router)
        let report = await Self.runAll(runner)
        let path = report.write(now: runner.catalogue.fixture.now)
        print(report.summary + "\nReport: \(path)")
        #if canImport(Darwin)
        add(XCTAttachment(string: report.json(now: runner.catalogue.fixture.now)))
        #endif
    }

    static func runAll(_ runner: AssistantEvalRunner, only: Set<String>? = nil) async -> AssistantEvalReport {
        let grader = AssistantEvalGrader(bundle: runner.bundle, now: runner.now)
        var report = AssistantEvalReport(mode: runner.mode)
        let env = ProcessInfo.processInfo.environment["ATTND_ASSISTANT_EVAL_ONLY"] ?? ""
        let filter = only ?? (env.isEmpty ? nil : Set(env.split(separator: ",").map(String.init)))
        for q in runner.catalogue.questions where filter == nil || filter!.contains(q.id) || filter!.contains(q.category) {
            let outcome = await runner.run(q)
            report.add(q, outcome, grader.grade(q, outcome, mode: runner.mode), grader)
        }
        return report
    }
}
