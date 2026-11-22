#!/usr/bin/env bash
# Runs the pure-Swift logic tests on Linux (Docker image swift:6.1), without Xcode or a Mac.
#
#   scripts/linux_harness.sh                               # the default test files below
#   scripts/linux_harness.sh AssistantEvalTests            # a --filter for swift test
#   ATTND_ASSISTANT_EVAL=router scripts/linux_harness.sh AssistantEvalTests   # + the full router eval
#
# It copies every Attnd/*.swift that imports only Foundation into build/linux-harness/ (a SwiftPM
# package), adds stand-ins for the few Apple-only pieces they touch (SHA256, CFBoolean, and
# ISODate / EventTimeFormat / HexColor cut from Helpers.swift), and the test files in TESTS.
# Reports of the eval land in build/assistant-eval/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/build/linux-harness"
TESTS=(PlannerFixture AssistantFixture AssistantRouterTests ConversationContextTests PlanProposalTests
       AssistantFlowTests MyScheduleTests LiveFollowTests AssistantBlocksTests AssistantExtrasTests PlanEditingTests PlanRequestTests PlannerTests
       ComponentTests AssistantEvalData AssistantEval AssistantEvalTests)
[[ -n "${HARNESS_TESTS:-}" ]] && read -r -a TESTS <<< "$HARNESS_TESTS"
APPLE='^import (SwiftUI|UIKit|MapKit|CoreLocation|ActivityKit|AppIntents|FoundationModels|MetricKit|Security|CryptoKit|Network|os|Observation|DeviceCheck|WebKit|VisionKit|Vision|ImageIO|UserNotifications|CoreSpotlight|CoreImage|UniformTypeIdentifiers)$'
SKIP=(APIClient.swift Diagnostics.swift Helpers.swift)
# Copied without `import ActivityKit` (an `ActivityAttributes` stand-in below), so LiveFollowLogic compiles.
ACTIVITYKIT=(LiveActivityModel.swift)

rm -rf "$PKG" && mkdir -p "$PKG/Sources/Attnd" "$PKG/Tests/AttndTests" "$ROOT/build/assistant-eval"
for f in "$ROOT"/Attnd/*.swift; do
  name="$(basename "$f")"
  [[ " ${SKIP[*]} " == *" $name "* ]] && continue
  if [[ " ${ACTIVITYKIT[*]} " == *" $name "* ]]; then
    sed '/^import ActivityKit$/d' "$f" > "$PKG/Sources/Attnd/$name"
    continue
  fi
  grep -qE "$APPLE" "$f" && continue
  sed '/^import CoreGraphics$/d' "$f" > "$PKG/Sources/Attnd/$name"
done
{
  echo 'import Foundation'
  echo '// Linux harness only: stand-ins for Apple-only APIs the pure files touch.'
  echo 'enum SHA256 { static func hash(data: Data) -> [UInt8] { var h: UInt64 = 0xcbf29ce484222325; for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }; return (0..<32).map { UInt8(truncatingIfNeeded: h >> (UInt64($0 % 8) * 8)) } } }'
  echo 'func CFGetTypeID(_ n: NSNumber) -> Int { String(cString: n.objCType) == "c" ? 1 : 0 }'
  echo 'func CFBooleanGetTypeID() -> Int { 1 }'
  echo 'protocol ActivityAttributes: Decodable, Encodable { associatedtype ContentState: Codable & Hashable }'
  awk '/^\/\/ MARK: - ISO 8601 parsing/{on=1} /^\/\/ MARK: - Deep links/{on=0} on' "$ROOT/Attnd/Helpers.swift"
} > "$PKG/Sources/Attnd/LinuxShims.swift"
for t in "${TESTS[@]}"; do cp "$ROOT/AttndTests/$t.swift" "$PKG/Tests/AttndTests/"; done
cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "Attnd", targets: [
  .target(name: "Attnd", swiftSettings: [.swiftLanguageMode(.v6)]),
  .testTarget(name: "AttndTests", dependencies: ["Attnd"], swiftSettings: [.swiftLanguageMode(.v6)]),
])
SWIFT
FILTER=()
[[ $# -gt 0 ]] && FILTER=(--filter "$1")
docker run --rm -v "$PKG:/p" -v "$ROOT/build/assistant-eval:/out" -w /p \
  -e ATTND_ASSISTANT_EVAL="${ATTND_ASSISTANT_EVAL:-}" -e ATTND_ASSISTANT_EVAL_ONLY="${ATTND_ASSISTANT_EVAL_ONLY:-}" \
  -e ATTND_ASSISTANT_EVAL_OUT=/out swift:6.1 swift test "${FILTER[@]}"
