#!/usr/bin/env python3
"""Bake the web origin and release version into the application before signing."""
import base64
import binascii
import os
import re
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit

PRODUCTION = "https://screenshotnote.com"
UPDATE_KEYS = ("SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction")


def configuration(environment, override):
    if environment not in ("local", "test", "production"):
        raise ValueError("SCREENSHOT_NOTE_ENV must be local, test or production")
    if environment == "production":
        if override is not None and override != PRODUCTION:
            raise ValueError("Production origin is fixed")
        return environment, PRODUCTION
    origin = override if override is not None else "http://localhost:5173" if environment == "local" else ""
    url = urlsplit(origin)
    port = url.port
    if (not origin or not origin.isascii() or any(c.isspace() or ord(c) < 32 for c in origin)
            or url.username is not None or url.password is not None
            or not url.hostname or url.path not in ("", "/")
            or "?" in origin or "#" in origin or "\\" in origin or "%" in origin
            or port is not None and not 1 <= port <= 65535):
        raise ValueError("Supply a plain web origin without credentials, path, query or fragment")
    if environment == "local":
        if url.scheme != "http" or url.hostname not in ("localhost", "127.0.0.1", "::1"):
            raise ValueError("Local builds require an HTTP loopback origin")
    elif url.scheme != "https" or url.hostname.rstrip(".") in ("localhost", "127.0.0.1", "::1", "screenshotnote.com"):
        raise ValueError("Test builds require an explicit HTTPS test origin")
    return environment, url._replace(scheme=url.scheme, netloc=url.netloc.lower()).geturl().rstrip("/")


def version(short, build):
    """Release builds pass X.Y.Z and a numeric build; local builds keep Info.plist values."""
    if short is None and build is None:
        return {}
    if short is None or build is None:
        raise ValueError("Set both SCREENSHOT_NOTE_VERSION and SCREENSHOT_NOTE_BUILD")
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", short) or not re.fullmatch(r"[1-9]\d{0,8}", build):
        raise ValueError("Version must be X.Y.Z and build a positive integer")
    return {"CFBundleShortVersionString": short, "CFBundleVersion": build}


def updates(environment, feed, key):
    """Sparkle běží jen v produkčním buildu s HTTPS feedem a veřejným EdDSA klíčem."""
    if feed is None and key is None:
        return {}
    if feed is None or key is None:
        raise ValueError("Set both SCREENSHOT_NOTE_FEED_URL and SCREENSHOT_NOTE_ED_PUBLIC_KEY")
    if environment != "production":
        raise ValueError("Update feed is allowed only in production builds")
    url = urlsplit(feed)
    if (url.scheme != "https" or not url.hostname or not feed.isascii() or any(c.isspace() or ord(c) < 32 for c in feed)
            or url.username is not None or url.password is not None or "?" in feed or "#" in feed or "\\" in feed):
        raise ValueError("Update feed must be a plain HTTPS URL")
    try:
        raw = base64.b64decode(key, validate=True)
    except binascii.Error:
        raw = b""
    if len(raw) != 32:
        raise ValueError("SCREENSHOT_NOTE_ED_PUBLIC_KEY must be a base64 Ed25519 public key")
    # Podepsaný appcast a ověření archivu před rozbalením zpřísňují kontrolu aktualizací.
    return {"SUFeedURL": feed, "SUPublicEDKey": key, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}


if __name__ == "__main__":
    try:
        environment, origin = configuration(os.environ.get("SCREENSHOT_NOTE_ENV", "production"), os.environ.get("SCREENSHOT_NOTE_WEB_ORIGIN"))
        path = Path(sys.argv[1])
        data = plistlib.loads(path.read_bytes())
        release = version(os.environ.get("SCREENSHOT_NOTE_VERSION"), os.environ.get("SCREENSHOT_NOTE_BUILD"))
        feed = updates(environment, os.environ.get("SCREENSHOT_NOTE_FEED_URL"), os.environ.get("SCREENSHOT_NOTE_ED_PUBLIC_KEY"))
        # Kopie produkčního bundlu (staging) nesmí zdědit jeho update feed.
        for name in UPDATE_KEYS:
            data.pop(name, None)
        data.update(ScreenshotNoteEnvironment=environment, ScreenshotNoteWebOrigin=origin, **release, **feed)
        path.write_bytes(plistlib.dumps(data))
        print(f"Build environment: {environment}; web origin: {origin}; version: {data['CFBundleShortVersionString']} ({data['CFBundleVersion']}); update feed: {feed.get('SUFeedURL', 'none')}")
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
