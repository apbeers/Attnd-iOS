#!/usr/bin/env python3
"""Summarise the warnings in an xcodebuild log, without ever failing the build.

    python3 scripts/ci/warnings.py build/xcodebuild-test.log "Unit tests"

Prints a deduplicated list (compiler warnings with file:line:col, then tool warnings such as
appintentsmetadataprocessor, ld or xcodebuild's own DVTAssertions) and, on GitHub Actions, emits one
`::warning` annotation per distinct warning (with file/line for source warnings) plus a step-summary
table. Exit status is always 0, so a warning never breaks a build; fix the warnings instead.
"""
import os
import re
import sys

SOURCE = re.compile(r'^(?P<file>/[^:]+?):(?P<line>\d+):(?:(?P<col>\d+):)? warning: (?P<msg>.+)$')
# "2026-11-14 22:28:29.334 tool[123:456] warning: ..." / "ld: warning: ..." / "... [MT] DVTAssertions: Warning in ..."
TOOL = re.compile(r'^(?:\d{4}-\d\d-\d\d [\d:.]+ )?(?P<tool>[\w.-]+)(?:\[\d+:\d+\])?:? (?:\[MT\] )?'
                  r'(?P<msg>(?:\w+: )?[Ww]arning(?::| in) .+)$')
TIMESTAMP = re.compile(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ')  # GitHub's prefix, when a downloaded log is passed


def escape(text, prop=False):
    text = text.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    return text.replace(':', '%3A').replace(',', '%2C') if prop else text


def main():
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        print(f'warnings.py: no log at {sys.argv[1] if len(sys.argv) > 1 else "(none)"}')
        return
    label = sys.argv[2] if len(sys.argv) > 2 else 'xcodebuild'
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd()).rstrip('/') + '/'
    source, tool = {}, {}  # key -> [count, annotation properties, message]
    with open(sys.argv[1], errors='replace') as log:
        lines = [TIMESTAMP.sub('', raw.rstrip('\n')) for raw in log]
    for i, line in enumerate(lines):
        if line.startswith('::'):
            continue  # our own annotations echoed back
        m = SOURCE.match(line)
        if m:
            path = m['file']
            rel = path[len(workspace):] if path.startswith(workspace) else path
            key = (rel, m['line'], m['col'], m['msg'])
            props = f'file={escape(rel, True)},line={m["line"]}' + (f',col={m["col"]}' if m['col'] else '')
            source.setdefault(key, [0, props, m['msg']])[0] += 1
            continue
        m = TOOL.match(line)
        if m:
            msg = re.sub(r'^[Ww]arning: ', '', m['msg'])
            following = lines[i + 1].strip() if i + 1 < len(lines) else ''
            if following.startswith('Details:'):  # xcodebuild's DVTAssertions put the reason on the next line
                msg += ' - ' + following[:300]
            key = (m['tool'], msg)
            tool.setdefault(key, [0, '', f'{m["tool"]}: {msg}'])[0] += 1

    total = len(source) + len(tool)
    github = os.environ.get('GITHUB_ACTIONS') == 'true'
    if github:
        print(f'::group::{label}: {total} distinct warning(s)')
    print(f'{label}: {total} distinct warning(s)')
    for (rel, line, col, msg), (count, _, _) in sorted(source.items()):
        print(f'  {rel}:{line}{":" + col if col else ""}: {msg}  (x{count})')
    for (name, msg), (count, _, _) in sorted(tool.items()):
        print(f'  {name}: {msg}  (x{count})')
    if github:
        print('::endgroup::')
        for count, props, msg in list(source.values()) + list(tool.values()):
            title = escape(f'{label} warning', True)
            print(f'::warning {props + "," if props else ""}title={title}::{escape(msg)}')
        summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if summary and total:
            with open(summary, 'a') as out:
                out.write(f'### {label}: {total} warning(s)\n\n| Where | Warning | Count |\n|---|---|---|\n')
                rows = [(f'`{rel}:{line}`', msg, count) for (rel, line, _, msg), (count, _, _) in sorted(source.items())]
                rows += [(name, msg, count) for (name, msg), (count, _, _) in sorted(tool.items())]
                for where, msg, count in rows:
                    cell = msg.replace('|', r'\|')
                    out.write(f'| {where} | {cell} | {count} |\n')
                out.write('\n')


if __name__ == '__main__':
    try:
        main()
    except Exception as err:  # never fail the build over the summary
        print(f'warnings.py: could not summarise warnings: {err}')
