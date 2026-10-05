#!/usr/bin/env python3
"""M1-A11Y-004 static accessibility audit (heuristic, source level).

Usage: static_audit.py [repo-root] [--json out.json]

Scans the app's SwiftUI/AppKit sources for:
  1. icon-only Buttons (label is only an Image) without an accessibilityLabel inside the label or on the button;
  2. drag-only or tap-only interactions (onDrag/onDrop/draggable/dropDestination/onTapGesture) and whether the
     same file also offers a non-drag path (onMove, a Button or a menu command);
  3. context-menu titles that have no menu-bar equivalent in MainMenu/SetupCommands (CMD-01: every context-menu
     action has a menu-bar path);
  4. tint/colour use (`foregroundStyle(.red/.orange/...)`, `tint:`) in views that do not also render Text
     (status must never be colour-only);
  5. controls (Button/Toggle/Picker/TextField/TextEditor/DatePicker/Stepper/Table/List/Slider) per file and how many
     carry an accessibilityIdentifier.
It is a static/code-level check only: NOT a VoiceOver or usability result. Every flag needs human review.
"""
import argparse
import json
import pathlib
import re
import sys

CONTROL_RE = re.compile(r"\b(Button|Toggle|Picker|TextField|TextEditor|DatePicker|Stepper|Table|List|Slider|Menu)\s*[({]")
DRAG_RE = re.compile(r"\.(onDrag|onDrop|draggable|dropDestination|onTapGesture)\b")
COLOR_RE = re.compile(r"\.(foregroundStyle|foregroundColor|tint)\(\s*(Color\.)?\.?(red|orange|yellow|green|blue|purple|pink)\b")
CONTEXT_TITLE_RE = re.compile(r'Button\("([^"]+)"')


def block_after(text, start):
    """Returns the brace block that starts at the first '{' at or after start."""
    i = text.find("{", start)
    if i < 0:
        return ""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return text[i:]


def menu_titles(root):
    titles = set()
    for path in list(root.glob("WaveWrangler/Commands/*.swift")) + list(root.glob("WaveWrangler/Sources/*Commands*.swift")):
        text = path.read_text()
        titles.update(re.findall(r'(?:routed|standard|NSMenuItem)\(\s*(?:title:\s*)?"([^"]+)"', text))
        titles.update(re.findall(r'title:\s*"([^"]+)"', text))
    return titles


def normalise(title):
    return title.replace("…", "").replace("...", "").strip().lower()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--json")
    args = parser.parse_args()
    root = pathlib.Path(args.root)
    menus = {normalise(t) for t in menu_titles(root)}
    report = {"iconOnlyButtonsWithoutLabel": [], "dragOrTapInteractions": [], "contextMenuWithoutMenuBar": [],
              "colourOnlyCandidates": [], "controls": {}}
    for path in sorted(root.glob("WaveWrangler/**/*.swift")):
        text = path.read_text()
        rel = str(path.relative_to(root))
        lines = text.splitlines()
        # 1. icon-only buttons
        for match in re.finditer(r"Button\s*(\([^)]*\))?\s*\{", text):
            label_at = text.find("label:", match.end())
            if label_at < 0 or label_at - match.end() > 600:
                continue
            label = block_after(text, label_at)
            tail = text[label_at + len(label): label_at + len(label) + 400]
            if "Image(" in label and "Text(" not in label and "Label(" not in label:
                if "accessibilityLabel" not in label and ".accessibilityLabel" not in tail.split("Button")[0]:
                    line = text[:match.start()].count("\n") + 1
                    report["iconOnlyButtonsWithoutLabel"].append(f"{rel}:{line}")
        # 2. drag/tap
        for i, line in enumerate(lines, 1):
            if DRAG_RE.search(line):
                alternative = any(k in text for k in (".onMove", "CommandRouter", "Button(", "contextMenu"))
                report["dragOrTapInteractions"].append({"at": f"{rel}:{i}", "code": line.strip()[:120],
                                                        "nonDragPathInFile": alternative})
        # 3. context menus
        for match in re.finditer(r"\.contextMenu", text):
            block = block_after(text, match.end())
            for title in CONTEXT_TITLE_RE.findall(block):
                if normalise(title) not in menus:
                    line = text[:match.start()].count("\n") + 1
                    report["contextMenuWithoutMenuBar"].append(f"{rel}:{line} “{title}”")
        # 4. colour use without text in the same view body (approximate: within 15 lines)
        for i, line in enumerate(lines, 1):
            if COLOR_RE.search(line):
                window = "\n".join(lines[max(0, i - 15): i + 15])
                if "Text(" not in window and "Label(" not in window and "accessibilityValue" not in window:
                    report["colourOnlyCandidates"].append(f"{rel}:{i} {line.strip()[:100]}")
        controls = len(CONTROL_RE.findall(text))
        if controls:
            report["controls"][rel] = {"controls": controls, "identifiers": text.count(".accessibilityIdentifier("),
                                       "labels": text.count(".accessibilityLabel("), "hints": text.count(".accessibilityHint("),
                                       "help": text.count(".help(")}
    totals = {k: sum(v[k] for v in report["controls"].values()) for k in ("controls", "identifiers", "labels", "hints", "help")}
    report["totals"] = totals
    report["menuBarTitles"] = len(menus)
    print(json.dumps(report, indent=2, ensure_ascii=False))
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
