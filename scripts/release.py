#!/usr/bin/env python3
"""Plan nightly release candidates and weekly promotions from Conventional Commits.

  release.py rc                       -> next vX.Y.Z-rc.N if HEAD has releasable changes
  release.py promote --min-age-days 7 -> oldest-enough newest RC to promote to vX.Y.Z

Results are printed as key=value lines (and appended to $GITHUB_OUTPUT when set).
Release notes are written to the file given by --notes.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
RC = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-rc\.(\d+)$")
HEADER = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?: (?P<subject>.+)$")
RELEASABLE = {"feat", "fix", "perf", "revert"}
SECTIONS = [("breaking", "Breaking Changes"), ("feat", "Features"), ("fix", "Bug Fixes"), ("perf", "Performance"), ("revert", "Reverts")]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def parse_commit(subject, body):
    """Return (type, scope, subject, breaking) or None for non-conventional commits."""
    match = HEADER.match(subject.strip())
    if not match:
        return None
    breaking = bool(match["bang"]) or bool(re.search(r"^BREAKING[ -]CHANGE:", body, re.M))
    return match["type"], match["scope"], match["subject"], breaking


def bump(version, commits):
    """Semver bump from parsed commits; None when nothing is releasable."""
    major, minor, patch = version
    if any(c[3] for c in commits):
        return (major + 1, 0, 0)
    if any(c[0] == "feat" for c in commits):
        return (major, minor + 1, 0)
    if any(c[0] in RELEASABLE for c in commits):
        return (major, minor, patch + 1)
    return None


def notes(commits, title):
    lines = [f"## {title}", ""]
    for key, heading in SECTIONS:
        items = [c for c in commits if (c[3] if key == "breaking" else c[0] == key and not c[3])]
        if items:
            lines += [f"### {heading}", ""]
            lines += [f"- {f'**{c[1]}:** ' if c[1] else ''}{c[2]}" for c in items]
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def commits_between(start, end):
    """Parsed non-merge commits in start..end (start may be None)."""
    rng = f"{start}..{end}" if start else end
    raw = git("log", "--no-merges", "--format=%s%x1f%b%x1e", rng)
    parsed = [parse_commit(*entry.strip("\n").split("\x1f", 1)) for entry in raw.split("\x1e") if entry.strip()]
    return [c for c in parsed if c]


def tags():
    return git("tag", "--list", "v*").split()


def latest_stable(all_tags):
    stable = sorted((tuple(map(int, m.groups())), t) for t in all_tags if (m := STABLE.match(t)))
    return stable[-1] if stable else ((0, 0, 0), None)


def fmt(version):
    return ".".join(map(str, version))


def notarized(tag):
    """Only commits that carry the packaging script produce notarized DMGs."""
    return subprocess.run(["git", "cat-file", "-e", f"{tag}:scripts/package-dmg.sh"], capture_output=True).returncode == 0


def build_number(ref):
    return git("rev-list", "--count", "--first-parent", ref).strip()


def plan_rc(head):
    all_tags = tags()
    if any(t for t in git("tag", "--points-at", head).split() if STABLE.match(t) or RC.match(t)):
        return {"release": "false", "reason": "HEAD is already tagged"}
    stable_version, stable_tag = latest_stable(all_tags)
    try:
        previous = git("describe", "--tags", "--abbrev=0", "--match", "v*", head).strip()
    except subprocess.CalledProcessError:
        previous = None
    if not bump((0, 0, 0), commits_between(previous, head)):
        return {"release": "false", "reason": f"no feat/fix/perf/revert since {previous}"}
    version = bump(stable_version, commits_between(stable_tag, head))
    rc = max((int(m[4]) for t in all_tags if (m := RC.match(t)) and tuple(map(int, m.groups()[:3])) == version), default=0) + 1
    tag = f"v{fmt(version)}-rc.{rc}"
    return {
        "release": "true", "tag": tag, "version": fmt(version), "build": build_number(head), "sha": git("rev-parse", head).strip(),
        "notes_body": notes(commits_between(previous, head), f"Changes since {previous}" if previous else "Changes"),
    }


def plan_promote(min_age_days, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    stable_version, stable_tag = latest_stable(tags())
    releases = json.loads(subprocess.run(["gh", "release", "list", "--limit", "200", "--json", "tagName,isPrerelease,publishedAt"], check=True, capture_output=True, text=True).stdout)
    candidates = []
    for release in releases:
        match = RC.match(release["tagName"])
        if not (match and release["isPrerelease"] and release["publishedAt"]):
            continue
        version, number = tuple(map(int, match.groups()[:3])), int(match[4])
        published = dt.datetime.fromisoformat(release["publishedAt"].replace("Z", "+00:00"))
        if version > stable_version and now - published >= dt.timedelta(days=min_age_days) and notarized(release["tagName"]):
            candidates.append((version, number, release["tagName"]))
    if not candidates:
        return {"release": "false", "reason": f"no notarized release candidate newer than v{fmt(stable_version)} is {min_age_days}+ days old"}
    version, _, rc_tag = max(candidates)
    sha = git("rev-list", "-n", "1", rc_tag).strip()
    title = f"Changes since {stable_tag}" if stable_tag else "Changes"
    return {"release": "true", "tag": f"v{fmt(version)}", "version": fmt(version), "rc_tag": rc_tag, "sha": sha,
            "notes_body": notes(commits_between(stable_tag, sha), title)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["rc", "promote"])
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--min-age-days", type=float, default=7)
    parser.add_argument("--notes", default="release-notes.md")
    args = parser.parse_args()
    result = plan_rc(args.head) if args.mode == "rc" else plan_promote(args.min_age_days)
    body = result.pop("notes_body", None)
    if body is not None:
        with open(args.notes, "w") as handle:
            handle.write(body)
        result["notes"] = args.notes
    output = "\n".join(f"{key}={value}" for key, value in result.items())
    print(output)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            handle.write(output + "\n")


if __name__ == "__main__":
    sys.exit(main())
