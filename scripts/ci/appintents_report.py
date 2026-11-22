#!/usr/bin/env python3
"""Lists the App Intents metadata of every bundle in an .xcarchive (informational, batch 7).

usage: appintents_report.py build/Attnd.xcarchive

Prints, per bundle, the actions in Metadata.appintents/extract.actionsdata (identifier, title,
discoverable) and every App Shortcut phrase, and appends the same as a table to
$GITHUB_STEP_SUMMARY. Exits 0 always; a warning when a bundle declares App Shortcuts or more
than the Live Activity buttons.
"""
import json
import os
import pathlib
import sys

EXPECTED = {"SkipActivityItemIntent", "DismissUrgentActivityIntent"}


def text(value):
    if isinstance(value, dict):
        for key in ("key", "value", "defaultValue", "string"):
            if key in value:
                return text(value[key])
        return json.dumps(value)[:80]
    return str(value)


def phrases(data):
    found = []
    def walk(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("phrases", "phraseTemplates") and isinstance(v, list):
                    found.extend(text(p) for p in v)
                else:
                    walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
    for key in ("autoShortcuts", "shortcuts", "autoShortcutProviderMangledName"):
        if key in data:
            walk(data[key])
    return found


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build/Attnd.xcarchive")
    rows = []
    for meta in sorted(root.rglob("Metadata.appintents")):
        bundle = next((p.name for p in meta.parents if p.suffix in (".app", ".appex")), meta.parent.name)
        files = sorted(meta.glob("*.actionsdata"))
        if not files:
            print(f"App Intents · {bundle}: no actionsdata ({', '.join(f.name for f in meta.iterdir())})")
        for f in files:
            try:
                data = json.loads(f.read_text())
            except Exception as error:  # noqa: BLE001
                print(f"App Intents · {bundle}: {f.name} unreadable ({error})")
                continue
            actions = data.get("actions") or {}
            for ident, action in sorted(actions.items()):
                title = text(action.get("title", "")) if isinstance(action, dict) else ""
                discoverable = action.get("isDiscoverable", True) if isinstance(action, dict) else "?"
                print(f"App Intents · {bundle}: action {ident} · {title} · discoverable {discoverable}")
                rows.append((bundle, ident, title, str(discoverable)))
            said = phrases(data)
            for phrase in said:
                print(f"App Intents · {bundle}: App Shortcut phrase “{phrase}”")
                rows.append((bundle, "(shortcut)", phrase, ""))
            unexpected = {i for i in actions if not any(e in i for e in EXPECTED)}
            if said or unexpected:
                print(f"::warning::App Intents · {bundle}: unexpected {sorted(unexpected)} / {len(said)} App Shortcut phrases")
            if not actions and not said:
                print(f"App Intents · {bundle}: nothing declared")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            out.write("\n### App Intents in the archive\n\n| Bundle | Action | Title / phrase | Discoverable |\n|---|---|---|---|\n")
            for r in rows or [("—", "none", "", "")]:
                out.write("| " + " | ".join(r) + " |\n")


if __name__ == "__main__":
    main()
