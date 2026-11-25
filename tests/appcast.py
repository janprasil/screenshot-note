import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).resolve().parents[1] / "scripts/appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIG = 'sparkle:edSignature="c2lnbmF0dXJl+/==" length="1234"'


def release(tag, published, prerelease=None, version=None, sparkle=True, draft=False):
    version = version or tag[1:].split("-")[0]
    dmg = f"Screenshot-Note-{version}.dmg"
    base = f"https://github.com/o/r/releases/download/{tag}/"
    assets = [{"name": dmg, "browser_download_url": base + dmg}, {"name": dmg + ".sha256", "browser_download_url": base + dmg + ".sha256"}]
    if sparkle:
        assets.append({"name": dmg + ".sparkle", "browser_download_url": base + dmg + ".sparkle"})
    return {"tag_name": tag, "published_at": published, "prerelease": "-rc." in tag if prerelease is None else prerelease,
            "draft": draft, "html_url": f"https://github.com/o/r/releases/tag/{tag}", "assets": assets}


def meta(rel, build, version=None):
    version = version or rel["tag_name"][1:].split("-")[0]
    url = next(a["browser_download_url"] for a in rel["assets"] if a["name"].endswith(".sparkle"))
    return {url: appcast.sparkle_meta(f"Screenshot-Note-{version}.dmg", version, str(build), SIG)}


class Metadata(unittest.TestCase):
    def test_sign_update_output(self):
        self.assertEqual(appcast.sparkle_meta("Screenshot-Note-4.5.0.dmg", "4.5.0", "120", SIG + "\n"),
                         {"file": "Screenshot-Note-4.5.0.dmg", "version": "4.5.0", "build": "120", "edSignature": "c2lnbmF0dXJl+/==", "length": 1234})
        for dmg, version, build, signed in [("Screenshot-Note-4.5.0.dmg", "4.5.0", "120", "garbage"),
                                            ("Screenshot-Note-4.5.0.dmg", "4.6.0", "120", SIG),
                                            ("Screenshot-Note.dmg", "4.5.0", "120", SIG),
                                            ("Screenshot-Note-4.5.0.dmg", "4.5.0", "0", SIG),
                                            ("Screenshot-Note-4.5.0.dmg", "4.5.0", "12a", SIG),
                                            ("Screenshot-Note-4.5.0.dmg", "4.5.0", "120", 'sparkle:edSignature="x"" length="1"')]:
            with self.subTest(dmg=dmg, version=version, build=build, signed=signed), self.assertRaises(ValueError):
                appcast.sparkle_meta(dmg, version, build, signed)


class Feed(unittest.TestCase):
    def test_channels_order_and_fields(self):
        rc1 = release("v4.5.0-rc.1", "2026-11-20T03:00:00Z")
        stable = release("v4.5.0", "2026-11-23T04:00:00Z")
        rc2 = release("v4.6.0-rc.1", "2026-11-24T03:00:00Z")
        staging = release("staging", "2026-11-24T03:01:00Z", prerelease=True, sparkle=False)
        old = release("v4.4.0", "2026-11-01T04:00:00Z", sparkle=False)
        draft = release("v4.7.0-rc.1", "2026-11-25T03:00:00Z", draft=True)
        data = {**meta(rc1, 120), **meta(stable, 120), **meta(rc2, 130), **meta(draft, 140)}
        entries = appcast.items([old, rc1, staging, stable, rc2, draft], data)
        self.assertEqual([(e["title"], e["channel"], e["version"]) for e in entries],
                         [("Screenshot Note 4.6.0-rc.1", "rc", "130"), ("Screenshot Note 4.5.0", "stable", "120"), ("Screenshot Note 4.5.0-rc.1", "rc", "120")])
        root = ET.fromstring(appcast.render(entries, "https://github.com/o/r/releases"))
        items = root.findall("channel/item")
        self.assertEqual([i.findtext(SP + "channel") for i in items], ["rc", None, "rc"])
        top = items[0]
        self.assertEqual(top.findtext(SP + "version"), "130")
        self.assertEqual(top.findtext(SP + "shortVersionString"), "4.6.0")
        self.assertEqual(top.findtext(SP + "minimumSystemVersion"), "13.0")
        self.assertEqual(top.findtext(SP + "fullReleaseNotesLink"), "https://github.com/o/r/releases/tag/v4.6.0-rc.1")
        self.assertEqual(top.findtext("pubDate"), "Tue, 24 Nov 2026 03:00:00 +0000")
        enclosure = top.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/o/r/releases/download/v4.6.0-rc.1/Screenshot-Note-4.6.0.dmg")
        self.assertEqual(enclosure.get("length"), "1234")
        self.assertEqual(enclosure.get(SP + "edSignature"), "c2lnbmF0dXJl+/==")

    def test_limits_and_mismatch(self):
        rels, data = [], {}
        for n in range(1, 9):
            rel = release(f"v4.5.0-rc.{n}", f"2026-11-{n:02d}T03:00:00Z")
            rels.append(rel)
            data.update(meta(rel, 100 + n))
        entries = appcast.items(rels, data)
        self.assertEqual([e["version"] for e in entries], ["108", "107", "106", "105", "104"])
        # Stabilní tag označený jako prerelease nebo RC bez příznaku se do feedu nedostane.
        odd = [release("v4.6.0", "2026-11-10T00:00:00Z", prerelease=True), release("v4.6.0-rc.1", "2026-11-11T00:00:00Z", prerelease=False)]
        self.assertEqual(appcast.items(odd, {**meta(odd[0], 1), **meta(odd[1], 2)}), [])
        wrong = release("v4.7.0", "2026-11-12T00:00:00Z", version="4.6.0")
        with self.assertRaises(ValueError):
            appcast.items([wrong], meta(wrong, 3, version="4.6.0"))

    def test_escaping(self):
        entry = {"title": "A & <B>", "channel": "stable", "published": "2026-11-24T03:00:00Z", "notes": "https://x.invalid/?a=1&b=2",
                 "url": 'https://x.invalid/"q".dmg', "version": "1", "short": "1.0.0", "signature": "s", "length": 1}
        root = ET.fromstring(appcast.render([entry], "https://x.invalid"))
        self.assertEqual(root.findtext("channel/item/title"), "A & <B>")
        self.assertEqual(root.find("channel/item/enclosure").get("url"), 'https://x.invalid/"q".dmg')


unittest.main()
