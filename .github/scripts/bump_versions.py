#!/usr/bin/env python3
"""Bump every pinned version that isn't a pub package.

pub has `pub upgrade`; nothing else here does. This walks the four remaining
places a version is written down by hand and rewrites each in place:

  gradle    Gradle plugin ids (AGP, Kotlin) in settings.gradle.kts and Maven
            coordinates ("group:artifact:version") in any *.gradle.kts
  wrapper   the Gradle distribution in gradle-wrapper.properties
  actions   `uses: owner/repo@ref` across workflows and composite actions
  flutter   FLUTTER_VERSION in the workflows (off by default — see --only)

Coordinates are *discovered*, not listed, so a dependency added later is covered
without editing this script. Repositories to search are the ones the build
itself declares, picked up from the same files.

Stdlib only, plus `gh` for the GitHub API (already authenticated on a runner).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

TIMEOUT = 30

# Anything that isn't a release. Bumping onto a preview is how an unattended
# updater breaks a build in a way nobody can reproduce from a version number.
PRERELEASE = re.compile(r"(alpha|beta|rc\d|[.\-]rc|dev|eap|snapshot|preview|canary|[.\-]m\d)", re.I)

DEFAULT_MAVEN_REPOS = [
    "https://dl.google.com/dl/android/maven2",
    "https://repo1.maven.org/maven2",
    "https://plugins.gradle.org/m2",
]


@dataclass
class Change:
    section: str
    what: str
    old: str
    new: str


# ── version helpers ────────────────────────────────────────────────────────────


def parse_version(text: str) -> tuple:
    core = re.split(r"[-+]", text.strip().lstrip("v"), maxsplit=1)[0]
    parts = []
    for chunk in core.split("."):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def pick_latest(
    current: str,
    candidates: list[str],
    max_bump: str,
    ceiling: tuple | None = None,
) -> str | None:
    """Newest stable candidate strictly above `current`, or None.

    `ceiling` is an exclusive upper bound: it is how a version that must not
    move past a line — AGP, held on 8.x because AGP 9 removed an API a
    dependency still calls — keeps receiving patch releases instead of being
    frozen outright by the hold list.
    """
    current_parts = parse_version(current)
    best: tuple | None = None
    best_text: str | None = None
    for candidate in candidates:
        if PRERELEASE.search(candidate):
            continue
        parts = parse_version(candidate)
        if parts <= current_parts:
            continue
        if max_bump == "minor" and parts[0] != current_parts[0]:
            continue
        if ceiling is not None and parts >= ceiling:
            continue
        if best is None or parts > best:
            best, best_text = parts, candidate
    return best_text


def parse_ceilings(text: str) -> dict[str, tuple]:
    """`"com.android.application<9,com.foo:bar<2.5"` -> {key: exclusive max}."""
    ceilings: dict[str, tuple] = {}
    for entry in text.split(","):
        entry = entry.strip()
        if not entry or "<" not in entry:
            continue
        key, _, bound = entry.partition("<")
        ceilings[key.strip()] = parse_version(bound.strip())
    return ceilings


def note_cap(notes: list[str], what: str, current: str, capped: str | None, uncapped: str | None) -> None:
    """Record a bump a ceiling withheld, so the cap can't quietly go stale."""
    if uncapped and uncapped != capped:
        notes.append(f"| {what} | {current} | {capped or current} | {uncapped} |")


# ── network ────────────────────────────────────────────────────────────────────


def fetch(url: str) -> bytes | None:
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "fishauctions-dep-bot"})
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None


def maven_versions(repos: list[str], group: str, artifact: str) -> list[str]:
    path = f"{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
    for repo in repos:
        body = fetch(f"{repo.rstrip('/')}/{path}")
        if not body:
            continue
        try:
            root = ET.fromstring(body)
        except ET.ParseError:
            continue
        versions = [element.text for element in root.iter("version") if element.text]
        if versions:
            return versions
    return []


def gh_json(*args: str):
    try:
        result = subprocess.run(
            ["gh", "api", *args], capture_output=True, text=True, timeout=TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


# ── file rewriting ─────────────────────────────────────────────────────────────


def rewrite(path: Path, old: str, new: str) -> bool:
    """Replace every occurrence of `old`; False if there was nothing left to do.

    A pin often repeats within a file (upload-artifact@v7 three times over), and
    the first rewrite takes all of them — so a later match from the same scan
    finding nothing is the normal case, not an error.
    """
    text = path.read_text()
    if old not in text or old == new:
        return False
    path.write_text(text.replace(old, new))
    return True


# ── section: gradle ────────────────────────────────────────────────────────────

PLUGIN_ID = re.compile(r'id\("([A-Za-z0-9_.\-]+)"\)\s+version\s+"([0-9][^"]*)"')
COORDINATE = re.compile(r'"([A-Za-z0-9_.\-]+):([A-Za-z0-9_.\-]+):([0-9][A-Za-z0-9_.\-]*)"')
MAVEN_REPO = re.compile(r'maven\s*\{[^}]*?uri\("([^"]+)"\)', re.S)


def gradle_files(root: Path) -> list[Path]:
    return sorted(p for p in (root / "fishauctions_application" / "android").rglob("*.gradle.kts"))


def bump_gradle(
    root: Path, hold: set[str], max_bump: str, ceilings: dict, notes: list[str]
) -> list[Change]:
    files = gradle_files(root)
    repos = list(DEFAULT_MAVEN_REPOS)
    for path in files:
        # Whatever the build resolves from, this script resolves from — the
        # Square SDK lives in its own repo and would otherwise be invisible.
        for url in MAVEN_REPO.findall(path.read_text()):
            if url.startswith("http") and url not in repos:
                repos.append(url)

    changes: list[Change] = []
    for path in files:
        for match in PLUGIN_ID.finditer(path.read_text()):
            plugin_id, current = match.group(1), match.group(2)
            if plugin_id in hold:
                continue
            # A Gradle plugin is published under a marker coordinate whose
            # group and artifact are both derived from the plugin id.
            versions = maven_versions(repos, plugin_id, f"{plugin_id}.gradle.plugin")
            if not versions:
                # Expected for dev.flutter.* — those come from the Flutter SDK's
                # included build, not from a repository.
                continue
            latest = pick_latest(current, versions, max_bump, ceilings.get(plugin_id))
            note_cap(notes, f"plugin `{plugin_id}`", current, latest, pick_latest(current, versions, max_bump))
            if not latest:
                continue
            replacement = match.group(0).replace(f'"{current}"', f'"{latest}"')
            if rewrite(path, match.group(0), replacement):
                changes.append(Change("Android / Gradle", f"plugin `{plugin_id}`", current, latest))

        for match in COORDINATE.finditer(path.read_text()):
            group, artifact, current = match.groups()
            coordinate = f"{group}:{artifact}"
            if coordinate in hold:
                continue
            versions = maven_versions(repos, group, artifact)
            if not versions:
                continue
            latest = pick_latest(current, versions, max_bump, ceilings.get(coordinate))
            note_cap(notes, f"`{coordinate}`", current, latest, pick_latest(current, versions, max_bump))
            if not latest:
                continue
            if rewrite(path, match.group(0), f'"{group}:{artifact}:{latest}"'):
                changes.append(Change("Android / Gradle", f"`{coordinate}`", current, latest))
    return changes


# ── section: gradle wrapper ────────────────────────────────────────────────────

WRAPPER_URL = re.compile(r"gradle-([0-9][0-9A-Za-z.\-]*)-(all|bin)\.zip")


def bump_wrapper(
    root: Path, hold: set[str], max_bump: str, ceilings: dict, notes: list[str]
) -> list[Change]:
    if "gradle" in hold:
        return []
    path = (
        root
        / "fishauctions_application"
        / "android"
        / "gradle"
        / "wrapper"
        / "gradle-wrapper.properties"
    )
    if not path.exists():
        return []
    match = WRAPPER_URL.search(path.read_text())
    if not match:
        return []
    current = match.group(1)
    body = fetch("https://services.gradle.org/versions/current")
    if not body:
        return []
    try:
        latest = json.loads(body).get("version", "")
    except json.JSONDecodeError:
        return []
    chosen = pick_latest(current, [latest], max_bump)
    if not chosen:
        return []
    if not rewrite(path, match.group(0), f"gradle-{chosen}-{match.group(2)}.zip"):
        return []
    return [Change("Android / Gradle", "Gradle wrapper", current, chosen)]


# ── section: github actions ────────────────────────────────────────────────────

USES = re.compile(r"uses:\s*([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)@([A-Za-z0-9_.\-]+)")


def action_files(root: Path) -> list[Path]:
    workflows = sorted((root / ".github" / "workflows").glob("*.y*ml"))
    composites = sorted((root / ".github" / "actions").rglob("action.y*ml"))
    return workflows + composites


def latest_action_tag(repo: str) -> str | None:
    release = gh_json(f"repos/{repo}/releases/latest")
    if isinstance(release, dict) and release.get("tag_name"):
        return release["tag_name"]
    tags = gh_json(f"repos/{repo}/tags?per_page=100")
    if not isinstance(tags, list):
        return None
    names = [tag.get("name", "") for tag in tags if isinstance(tag, dict)]
    stable = [name for name in names if re.fullmatch(r"v?\d+(\.\d+)*", name)]
    return max(stable, key=parse_version) if stable else None


def bump_actions(
    root: Path, hold: set[str], max_bump: str, ceilings: dict, notes: list[str]
) -> list[Change]:
    changes: list[Change] = []
    resolved: dict[str, str | None] = {}
    for path in action_files(root):
        for match in USES.finditer(path.read_text()):
            repo, ref = match.group(1), match.group(2)
            if repo in hold or re.fullmatch(r"[0-9a-f]{40}", ref):
                # A SHA pin is a deliberate supply-chain choice; leave it alone.
                continue
            if repo not in resolved:
                resolved[repo] = latest_action_tag(repo)
            tag = resolved[repo]
            if not tag:
                continue
            # Keep the pin's granularity: `@v7` stays a major-only pin.
            components = len(ref.lstrip("v").split("."))
            digits = parse_version(tag)[:components]
            candidate = "v" + ".".join(str(part) for part in digits)
            if not pick_latest(ref, [candidate], max_bump):
                continue
            replacement = match.group(0).replace(f"@{ref}", f"@{candidate}")
            if rewrite(path, match.group(0), replacement):
                changes.append(Change("GitHub Actions", f"`{repo}`", ref, candidate))
    return changes


# ── section: flutter sdk ───────────────────────────────────────────────────────

FLUTTER_PIN = re.compile(r"FLUTTER_VERSION:\s*([0-9][0-9A-Za-z.\-]*)")


def bump_flutter(
    root: Path, hold: set[str], max_bump: str, ceilings: dict, notes: list[str]
) -> list[Change]:
    if "flutter" in hold:
        return []
    body = fetch("https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json")
    if not body:
        return []
    try:
        data = json.loads(body)
        stable_hash = data["current_release"]["stable"]
        latest = next(r["version"] for r in data["releases"] if r["hash"] == stable_hash)
    except (json.JSONDecodeError, KeyError, StopIteration):
        return []

    changes: list[Change] = []
    for path in action_files(root):
        for match in FLUTTER_PIN.finditer(path.read_text()):
            current = match.group(1)
            chosen = pick_latest(current, [latest], max_bump)
            if not chosen:
                continue
            if rewrite(path, match.group(0), f"FLUTTER_VERSION: {chosen}"):
                changes.append(Change("Toolchain", "Flutter SDK", current, chosen))
    return changes


SECTIONS = {
    "gradle": bump_gradle,
    "wrapper": bump_wrapper,
    "actions": bump_actions,
    "flutter": bump_flutter,
}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument(
        "--only",
        default="gradle,wrapper,actions",
        help=f"comma-separated sections to run ({', '.join(SECTIONS)})",
    )
    parser.add_argument("--hold", default="", help="plugin ids, group:artifact, owner/repo, 'gradle', 'flutter'")
    parser.add_argument(
        "--ceiling",
        default="",
        help="exclusive upper bounds, e.g. 'com.android.application<9' (comma-separated)",
    )
    parser.add_argument(
        "--max-bump",
        choices=("major", "minor"),
        default="major",
        help="'minor' keeps every version on its current major",
    )
    parser.add_argument("--out", required=True, help="markdown fragment to write")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    hold = {name.strip() for name in args.hold.split(",") if name.strip()}
    wanted = [name.strip() for name in args.only.split(",") if name.strip()]

    ceilings = parse_ceilings(args.ceiling)
    notes: list[str] = []

    collected: list[Change] = []
    for name in wanted:
        if name not in SECTIONS:
            raise SystemExit(f"unknown section {name!r}")
        collected.extend(SECTIONS[name](root, hold, args.max_bump, ceilings, notes))

    # The same pin lives in several files (checkout@v7 in three workflows,
    # FLUTTER_VERSION in three more); the PR should say so once.
    seen: set[tuple[str, str, str, str]] = set()
    changes: list[Change] = []
    for change in collected:
        key = (change.section, change.what, change.old, change.new)
        if key not in seen:
            seen.add(key)
            changes.append(change)

    lines: list[str] = []
    for section in dict.fromkeys(change.section for change in changes):
        rows = [change for change in changes if change.section == section]
        lines.append(f"#### {section} ({len(rows)})")
        lines.append("")
        lines.append("| What | From | To |")
        lines.append("| --- | --- | --- |")
        for change in rows:
            lines.append(f"| {change.what} | {change.old} | {change.new} |")
        lines.append("")
    if notes:
        lines.append(f"#### Capped by policy ({len(notes)})")
        lines.append("")
        lines.append("| What | Current | Applied | Newest |")
        lines.append("| --- | --- | --- | --- |")
        lines.extend(notes)
        lines.append("")
        lines.append("These sit under a `--ceiling` in the workflow. Check whether the reason still holds.")
        lines.append("")
    Path(args.out).write_text("\n".join(lines))

    for change in changes:
        print(f"{change.section}: {change.what} {change.old} -> {change.new}")
    print(f"{len(changes)} non-pub version(s) bumped")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
