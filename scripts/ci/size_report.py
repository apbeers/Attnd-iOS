#!/usr/bin/env python3
"""What makes the .ipa big: compressed .ipa size, then per bundle (app, App Clip, extensions) the
executable, Assets.car and other files, uncompressed and zip-compressed (a rough download estimate).
Usage: size_report.py <ipa> <unzipped Payload dir> <configuration>. Informational only."""
import os, sys, zlib


def mb(n):
    return f"{n / 1_048_576:.2f} MB"


def deflated(path):
    c = zlib.compressobj(9)
    out = 0
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            out += len(c.compress(chunk))
    return out + len(c.flush())


def main():
    ipa, payload, config = sys.argv[1:4]
    rows = []
    bundles = []
    for root, dirs, _ in os.walk(payload):
        for d in dirs:
            if d.endswith(('.app', '.appex')):
                bundles.append(os.path.join(root, d))
    bundles.sort(key=len)
    for b in bundles:
        name = os.path.relpath(b, payload)
        nested = [o for o in bundles if o != b and o.startswith(b + os.sep)]
        exe = os.path.join(b, os.path.splitext(os.path.basename(b))[0])
        parts = {'executable': [0, 0], 'Assets.car': [0, 0], 'other': [0, 0]}
        for root, _, files in os.walk(b):
            if any(root == n or root.startswith(n + os.sep) for n in nested):
                continue
            for f in files:
                p = os.path.join(root, f)
                key = 'executable' if p == exe else 'Assets.car' if f == 'Assets.car' else 'other'
                parts[key][0] += os.path.getsize(p)
                parts[key][1] += deflated(p)
        rows.append((name, parts))
    lines = [f"### Size breakdown ({config})", "",
             f".ipa (compressed, all parts): **{mb(os.path.getsize(ipa))}**", "",
             "| Bundle | Part | Uncompressed | Compressed |", "|---|---|---|---|"]
    for name, parts in rows:
        for key, (raw, comp) in parts.items():
            lines.append(f"| {name} | {key} | {mb(raw)} | {mb(comp)} |")
    text = "\n".join(lines)
    print(text)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as f:
            f.write(text + "\n\n")


if __name__ == '__main__':
    main()
