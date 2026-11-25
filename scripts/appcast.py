#!/usr/bin/env python3
"""Build the Sparkle appcast from GitHub releases and their .sparkle metadata assets.

  appcast.py sparkle-meta DMG VERSION BUILD < sign_update-output > DMG.sparkle
  appcast.py feed --repo OWNER/NAME --out appcast.xml

Stable releases (vX.Y.Z) become items without a channel, release candidates
(vX.Y.Z-rc.N) items in the "rc" channel. Releases without a .sparkle asset
(older ones, the rolling staging build) are skipped. The feed is signed afterwards
with sign_update, so it must not change after this script writes it.
"""
import argparse
import email.utils
import datetime as dt
import json
import os
import re
import sys
import urllib.request
from xml.sax.saxutils import escape, quoteattr

STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
RC = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-rc\.(\d+)$")
SIGNATURE = re.compile(r'^sparkle:edSignature="([A-Za-z0-9+/=]+)" length="(\d+)"$')
DMG = re.compile(r"^Screenshot-Note-(\d+\.\d+\.\d+)\.dmg$")
MINIMUM_SYSTEM = "13.0"
KEEP = {"stable": 10, "rc": 5}


def sparkle_meta(dmg, version, build, signed):
    """Metadata JSON from sign_update output; checks it matches the DMG name and version."""
    match = SIGNATURE.match(signed.strip())
    name = DMG.match(dmg)
    if not match:
        raise ValueError("Unexpected sign_update output")
    if not name or name[1] != version:
        raise ValueError("DMG name must be Screenshot-Note-<version>.dmg")
    if not re.fullmatch(r"[1-9]\d{0,8}", build):
        raise ValueError("Build must be a positive integer")
    return {"file": dmg, "version": version, "build": build, "edSignature": match[1], "length": int(match[2])}


def channel(tag):
    if STABLE.match(tag):
        return "stable"
    if RC.match(tag):
        return "rc"
    return None


def items(releases, metadata):
    """Appcast entries, newest first, limited per channel.

    releases: GitHub release objects; metadata: {asset download URL: parsed .sparkle JSON}.
    """
    picked = {"stable": [], "rc": []}
    for release in sorted(releases, key=lambda r: r["published_at"] or "", reverse=True):
        kind = channel(release["tag_name"])
        if release.get("draft") or kind is None or release["prerelease"] != (kind == "rc"):
            continue
        assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
        meta = next((metadata[url] for name, url in assets.items() if name.endswith(".dmg.sparkle") and url in metadata), None)
        if meta is None or meta["file"] not in assets or len(picked[kind]) >= KEEP[kind]:
            continue
        if not release["tag_name"].startswith(f"v{meta['version']}"):
            raise ValueError(f"{release['tag_name']}: metadata is for {meta['version']}")
        picked[kind].append({
            "title": f"Screenshot Note {release['tag_name'][1:]}",
            "channel": kind,
            "published": release["published_at"],
            "notes": release["html_url"],
            "url": assets[meta["file"]],
            "version": meta["build"],
            "short": meta["version"],
            "signature": meta["edSignature"],
            "length": meta["length"],
        })
    return sorted(picked["stable"] + picked["rc"], key=lambda i: i["published"], reverse=True)


def render(entries, link):
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
           "<channel>", "<title>Screenshot Note</title>", f"<link>{escape(link)}</link>"]
    for e in entries:
        date = email.utils.format_datetime(dt.datetime.fromisoformat(e["published"].replace("Z", "+00:00")))
        out += ["<item>", f"<title>{escape(e['title'])}</title>", f"<pubDate>{date}</pubDate>"]
        if e["channel"] == "rc":
            out.append("<sparkle:channel>rc</sparkle:channel>")
        out += [f"<sparkle:version>{escape(e['version'])}</sparkle:version>",
                f"<sparkle:shortVersionString>{escape(e['short'])}</sparkle:shortVersionString>",
                f"<sparkle:minimumSystemVersion>{MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>",
                f"<sparkle:fullReleaseNotesLink>{escape(e['notes'])}</sparkle:fullReleaseNotesLink>",
                f"<enclosure url={quoteattr(e['url'])} length=\"{e['length']}\" type=\"application/octet-stream\" sparkle:edSignature={quoteattr(e['signature'])}/>",
                "</item>"]
    out += ["</channel>", "</rss>"]
    return "\n".join(out) + "\n"


def fetch(url, token, accept="application/vnd.github+json"):
    request = urllib.request.Request(url, headers={"Accept": accept, "Authorization": f"Bearer {token}", "User-Agent": "screenshot-note-appcast"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def feed(repo, token):
    releases = []
    for page in range(1, 6):
        batch = json.loads(fetch(f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}", token))
        releases += batch
        if len(batch) < 100:
            break
    metadata = {}
    for release in releases:
        for asset in release["assets"]:
            if asset["name"].endswith(".dmg.sparkle"):
                # Asset API vrací obsah i u čerstvých vydání, kde CDN ještě nemusí mít soubor.
                metadata[asset["browser_download_url"]] = json.loads(fetch(asset["url"], token, "application/octet-stream"))
    return render(items(releases, metadata), f"https://github.com/{repo}/releases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    meta = sub.add_parser("sparkle-meta")
    meta.add_argument("dmg")
    meta.add_argument("version")
    meta.add_argument("build")
    cast = sub.add_parser("feed")
    cast.add_argument("--repo", required=True)
    cast.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        if args.command == "sparkle-meta":
            print(json.dumps(sparkle_meta(os.path.basename(args.dmg), args.version, args.build, sys.stdin.read())))
        else:
            xml = feed(args.repo, os.environ["GH_TOKEN"])
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(xml)
            print(f"Appcast: {xml.count('<item>')} items")
    except ValueError as error:
        sys.exit(str(error))
