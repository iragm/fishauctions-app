#!/usr/bin/env python3
"""Pub dependency planning for the weekly dependency-update workflow.

Two jobs, both driven from data the pub tool already produces, so nothing here
re-implements version solving:

  plan       `flutter pub outdated --json` -> the packages whose pubspec.yaml
             constraint has to be rewritten to reach the newest release (i.e.
             the arguments for `pub upgrade --major-versions`), minus anything
             held back, plus a report of what was skipped and why.

  lock-diff  two pubspec.lock snapshots -> the markdown table for the PR body.
             Reading the lock rather than trusting the plan means the PR reports
             what actually resolved, transitive moves included.

Stdlib only: this runs on a bare GitHub runner with no pip install step.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


# ── version helpers ────────────────────────────────────────────────────────────
# Enough semver to sort and to answer "is this a breaking bump?". Pub's caret
# constraint treats 0.x specially (^0.14.4 allows 0.14.x but not 0.15.0), so a
# minor bump below 1.0.0 is a breaking one.


def parse_version(text: str) -> tuple:
    core = re.split(r"[-+]", text.strip(), maxsplit=1)[0]
    parts = []
    for chunk in core.split("."):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def is_breaking(old: str, new: str) -> bool:
    a, b = parse_version(old), parse_version(new)
    if a[0] != b[0]:
        return True
    return a[0] == 0 and a[1] != b[1]


# ── pub outdated --json ────────────────────────────────────────────────────────


def version_of(entry: dict, field: str) -> str | None:
    value = entry.get(field)
    if isinstance(value, dict):
        return value.get("version")
    return None


def cmd_plan(args: argparse.Namespace) -> int:
    data = json.loads(Path(args.outdated).read_text())
    hold = {name.strip() for name in args.hold.split(",") if name.strip()}

    targets: list[str] = []
    held: list[tuple[str, str, str]] = []  # name, current, latest
    blocked: list[tuple[str, str, str, str]] = []  # name, current, resolvable, latest

    for entry in data.get("packages", []):
        name = entry.get("package")
        kind = entry.get("kind")
        # Transitives have no constraint of ours to rewrite; a plain
        # `pub upgrade` moves them as far as the direct constraints allow.
        if not name or kind not in ("direct", "dev"):
            continue

        current = version_of(entry, "current")
        resolvable = version_of(entry, "resolvable")
        latest = version_of(entry, "latest")
        if not current or not latest or latest == current:
            continue

        if name in hold:
            held.append((name, current, latest))
            continue

        targets.append(name)
        # `latest` unreachable means something else pins us — another package's
        # constraint, or the Dart/Flutter SDK floor. Worth reporting: it is
        # usually the reason a package looks stuck for weeks on end.
        if resolvable and resolvable != latest:
            blocked.append((name, current, resolvable, latest))

    Path(args.targets_out).write_text("\n".join(sorted(targets)) + ("\n" if targets else ""))

    lines: list[str] = []
    if held:
        lines.append("**Held back by workflow config** (`PUB_HOLD` in the workflow):")
        lines.append("")
        lines.append("| Package | Current | Available |")
        lines.append("| --- | --- | --- |")
        for name, current, latest in sorted(held):
            lines.append(f"| `{name}` | {current} | {latest} |")
        lines.append("")
    if blocked:
        lines.append("**Can't reach the newest release** (another constraint or the SDK floor):")
        lines.append("")
        lines.append("| Package | Current | Best available | Newest |")
        lines.append("| --- | --- | --- | --- |")
        for name, current, resolvable, latest in sorted(blocked):
            lines.append(f"| `{name}` | {current} | {resolvable} | {latest} |")
        lines.append("")
    Path(args.report_out).write_text("\n".join(lines))

    print(f"{len(targets)} package(s) to upgrade, {len(held)} held, {len(blocked)} blocked")
    return 0


# ── pubspec.lock ───────────────────────────────────────────────────────────────
# The lock is regular enough to read with a tiny state machine: `packages:` at
# column 0, package names at two spaces, fields at four. Avoids a PyYAML
# dependency on a runner that may not have one.

LOCK_NAME = re.compile(r"^  ([A-Za-z0-9_]+):\s*$")
LOCK_FIELD = re.compile(r'^    ([a-z_]+):\s*"?([^"\n]*?)"?\s*$')


def parse_lock(path: Path) -> dict[str, dict[str, str]]:
    packages: dict[str, dict[str, str]] = {}
    in_packages = False
    current: str | None = None
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        if not line.startswith(" "):
            in_packages = line.startswith("packages:")
            current = None
            continue
        if not in_packages:
            continue
        name_match = LOCK_NAME.match(line)
        if name_match:
            current = name_match.group(1)
            packages[current] = {}
            continue
        field_match = LOCK_FIELD.match(line)
        if field_match and current:
            packages[current][field_match.group(1)] = field_match.group(2)
    return packages


def cmd_lock_diff(args: argparse.Namespace) -> int:
    before = parse_lock(Path(args.before))
    after = parse_lock(Path(args.after))

    direct: list[str] = []
    transitive: list[str] = []
    breaking = 0

    for name in sorted(set(before) | set(after)):
        old = before.get(name, {}).get("version")
        new = after.get(name, {}).get("version")
        if old == new:
            continue
        kind = after.get(name, {}).get("dependency", before.get(name, {}).get("dependency", ""))
        if old is None:
            row = f"| `{name}` | — | {new} | added |"
        elif new is None:
            row = f"| `{name}` | {old} | — | removed |"
        else:
            note = "**breaking**" if is_breaking(old, new) else ""
            if note:
                breaking += 1
            row = f"| `{name}` | {old} | {new} | {note} |"
        (direct if kind.startswith("direct") else transitive).append(row)

    lines: list[str] = []
    header = ["| Package | From | To | |", "| --- | --- | --- | --- |"]
    if direct:
        lines.append(f"#### Dart packages ({len(direct)})")
        lines.append("")
        lines.extend(header)
        lines.extend(direct)
        lines.append("")
    if transitive:
        lines.append("<details><summary>")
        lines.append(f"Transitive packages ({len(transitive)})</summary>")
        lines.append("")
        lines.extend(header)
        lines.extend(transitive)
        lines.append("")
        lines.append("</details>")
        lines.append("")
    if not direct and not transitive:
        lines.append("_No Dart package changes._")
        lines.append("")

    Path(args.out).write_text("\n".join(lines))
    print(f"{len(direct)} direct, {len(transitive)} transitive, {breaking} breaking")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    plan = sub.add_parser("plan", help="turn `pub outdated --json` into upgrade targets")
    plan.add_argument("--outdated", required=True)
    plan.add_argument("--hold", default="", help="comma-separated package names to never bump")
    plan.add_argument("--targets-out", required=True)
    plan.add_argument("--report-out", required=True)
    plan.set_defaults(func=cmd_plan)

    diff = sub.add_parser("lock-diff", help="markdown table of two pubspec.lock snapshots")
    diff.add_argument("--before", required=True)
    diff.add_argument("--after", required=True)
    diff.add_argument("--out", required=True)
    diff.set_defaults(func=cmd_lock_diff)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
