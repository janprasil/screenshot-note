#!/usr/bin/env python3
"""Bake the web origin into the application before signing."""
import os
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit

PRODUCTION = "https://screenshotnote.com"


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


if __name__ == "__main__":
    try:
        environment, origin = configuration(os.environ.get("SCREENSHOT_NOTE_ENV", "production"), os.environ.get("SCREENSHOT_NOTE_WEB_ORIGIN"))
        path = Path(sys.argv[1])
        data = plistlib.loads(path.read_bytes())
        data.update(ScreenshotNoteEnvironment=environment, ScreenshotNoteWebOrigin=origin)
        path.write_bytes(plistlib.dumps(data))
        print(f"Build environment: {environment}; web origin: {origin}")
    except (ValueError, IndexError) as error:
        sys.exit(str(error))
