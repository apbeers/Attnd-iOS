#!/usr/bin/env python3
"""Short summary of an xcodebuild test log: passed / failed / skipped tests and each failure's message.

    python3 scripts/ci/test_summary.py build/xcodebuild-integration.log "Integration · dev"

Prints the summary and, on GitHub Actions, adds a step-summary section and one `::error` annotation
per failed test. Exits 1 when a test failed, or when no test passed but some were skipped (for the
live API tests that means ATTND_IT_SERVER / ATTND_IT_KEY never reached the test process), or when no
test ran at all; 0 otherwise.
"""
import os
import re
import sys

# "Test Case '-[AttndTests.APIClientIntegrationTests testFoo]' passed (0.123 seconds)."
# "Test case 'APIClientIntegrationTests.testFoo()' failed on 'iPhone …' (0.123 seconds)"
RESULT = re.compile(r"^Test [Cc]ase '(?:-\[[\w.]+ (?P<objc>\w+)\]|[\w.]+?\.(?P<swift>\w+)\(\))' "
                    r"(?P<result>passed|failed|skipped)")
# "/path/File.swift:123: error: -[AttndTests.APIClientIntegrationTests testFoo] : XCTAssertEqual failed: …"
FAILURE = re.compile(r'^(?P<file>/[^:]+):(?P<line>\d+): error: -\[[\w.]+ (?P<test>\w+)\] : (?P<msg>.+)$')
TIMESTAMP = re.compile(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ')


def escape(text, prop=False):
    text = text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    return text.replace(':', '%3A').replace(',', '%2C') if prop else text


def main():
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print(f'test_summary.py: no log at {sys.argv[1] if len(sys.argv) > 1 else "(none)"}')
        return 1
    label = sys.argv[2] if len(sys.argv) > 2 else 'Tests'
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd()).rstrip('/') + '/'
    results = {}   # test -> passed/failed/skipped (last wins)
    failures = {}  # test -> [(rel file, line, message)]
    with open(sys.argv[1], errors='replace') as log:
        for raw in log:
            line = TIMESTAMP.sub('', raw.rstrip('\n'))
            m = RESULT.match(line)
            if m:
                results[m['objc'] or m['swift']] = m['result']
                continue
            m = FAILURE.match(line)
            if m:
                path = m['file']
                rel = path[len(workspace):] if path.startswith(workspace) else path
                failures.setdefault(m['test'], []).append((rel, m['line'], m['msg'][:500]))

    passed = sorted(t for t, r in results.items() if r == 'passed')
    failed = sorted(t for t, r in results.items() if r == 'failed')
    skipped = sorted(t for t, r in results.items() if r == 'skipped')
    ok = not failed and bool(passed)
    headline = f'{label}: {len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped'
    if not results:
        headline += ' (no tests ran; see the build log)'
    elif not passed and skipped:
        headline += ' (everything skipped: the server/key did not reach the test process)'
    print(headline)
    for test in failed:
        for rel, line, msg in failures.get(test, [('', '', 'failed')]):
            print(f'  FAILED {test}: {msg}' + (f'  ({rel}:{line})' if rel else ''))

    if os.environ.get('GITHUB_ACTIONS') == 'true':
        for test in failed:
            for rel, line, msg in failures.get(test, [('', '', 'failed')]):
                props = f'file={escape(rel, True)},line={line},' if rel else ''
                print(f'::error {props}title={escape(label + " · " + test, True)}::{escape(msg)}')
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary:
            with open(summary, 'a') as out:
                out.write(f'### {headline}\n\n')
                if failed:
                    out.write('| Test | Failure |\n|---|---|\n')
                    for test in failed:
                        for _, _, msg in failures.get(test, [('', '', 'failed')]):
                            out.write(f'| `{test}` | {msg.replace("|", chr(92) + "|")} |\n')
                    out.write('\n')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
