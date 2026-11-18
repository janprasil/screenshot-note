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


unittest.main()
