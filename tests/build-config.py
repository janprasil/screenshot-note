import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("build_config", Path(__file__).resolve().parents[1] / "scripts/configure-build.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class BuildConfiguration(unittest.TestCase):
    def test_defaults_and_origins(self):
        self.assertEqual(config.configuration("production", None), ("production", "https://screenshotnote.com"))
        self.assertEqual(config.configuration("local", None), ("local", "http://localhost:5173"))
        self.assertEqual(config.configuration("local", "http://127.0.0.1:6000/"), ("local", "http://127.0.0.1:6000"))
        self.assertEqual(config.configuration("local", "http://[::1]:5173"), ("local", "http://[::1]:5173"))
        self.assertEqual(config.configuration("test", "https://fixture.invalid"), ("test", "https://fixture.invalid"))

        self.assertEqual(config.configuration("test", "HTTPS://FIXTURE.invalid/"), ("test", "https://fixture.invalid"))

    def test_reject_wrong_environment_and_unsafe_origins(self):
        for environment, origin in [("stage", None), ("test", None), ("production", "https://other.invalid"), ("local", "http://remote.invalid"), ("test", "http://fixture.invalid"), ("test", "https://localhost"), ("test", "https://screenshotnote.com"), ("test", "https://screenshotnote.com.")]:
            with self.subTest(environment=environment, origin=origin), self.assertRaises(ValueError):
                config.configuration(environment, origin)
        for origin in ["https://user:password@fixture.invalid", "https://fixture.invalid/path", "https://fixture.invalid?", "https://fixture.invalid#", "https://fixture.invalid:0", "https://fixture.invalid:bad", "https://fixture.invalid\n", "https://fixture.invalid\\x", "https://%73creenshotnote.com"]:
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                config.configuration("test", origin)

    def test_release_version(self):
        self.assertEqual(config.version(None, None), {})
        self.assertEqual(config.version("4.5.0", "123"), {"CFBundleShortVersionString": "4.5.0", "CFBundleVersion": "123"})
        for short, build in [("4.5.0", None), (None, "1"), ("4.5.0-rc.1", "1"), ("4.5", "1"), ("04.5.0", "1"), ("4.5.0", "0"), ("4.5.0", "1a")]:
            with self.subTest(short=short, build=build), self.assertRaises(ValueError):
                config.version(short, build)

    def test_update_feed(self):
        key = "A" * 43 + "="
        self.assertEqual(config.updates("production", None, None), {})
        self.assertEqual(config.updates("production", "https://example.invalid/appcast.xml", key),
                         {"SUFeedURL": "https://example.invalid/appcast.xml", "SUPublicEDKey": key, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True})
        for environment, feed, public in [("production", "https://example.invalid/appcast.xml", None), ("production", None, key),
                                          ("test", "https://example.invalid/appcast.xml", key), ("local", "https://example.invalid/appcast.xml", key),
                                          ("production", "http://example.invalid/appcast.xml", key), ("production", "https://user@example.invalid/a.xml", key),
                                          ("production", "https://example.invalid/a.xml?x=1", key), ("production", "https://example.invalid/a.xml?", key), ("production", "https://example.invalid/a.xml#", key), ("production", "https://example.invalid/a.xml\n", key),
                                          ("production", "https://example.invalid/appcast.xml", "short"), ("production", "https://example.invalid/appcast.xml", "!" * 44)]:
            with self.subTest(environment=environment, feed=feed, key=public), self.assertRaises(ValueError):
                config.updates(environment, feed, public)


unittest.main()
