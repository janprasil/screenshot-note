import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class Parsing(unittest.TestCase):
    def test_headers(self):
        self.assertEqual(release.parse_commit("feat(cloud): sync (#12)", ""), ("feat", "cloud", "sync (#12)", False))
        self.assertEqual(release.parse_commit("fix!: drop old format", ""), ("fix", None, "drop old format", True))
        self.assertEqual(release.parse_commit("chore: x", "BREAKING CHANGE: y"), ("chore", None, "x", True))
        self.assertIsNone(release.parse_commit("Merge pull request #7 from x", ""))
        self.assertIsNone(release.parse_commit("Fix things", ""))

    def test_bump(self):
        c = lambda t, b=False: (t, None, "s", b)
        self.assertIsNone(release.bump((4, 4, 0), [c("docs"), c("ci"), c("chore")]))
        self.assertEqual(release.bump((4, 4, 0), [c("fix"), c("docs")]), (4, 4, 1))
        self.assertEqual(release.bump((4, 4, 0), [c("fix"), c("feat")]), (4, 5, 0))
        self.assertEqual(release.bump((4, 4, 0), [c("feat"), c("docs", True)]), (5, 0, 0))

    def test_notes(self):
        text = release.notes([("feat", "ui", "a", False), ("fix", None, "b", False), ("docs", None, "c", False), ("feat", None, "d", True)], "T")
        self.assertIn("### Breaking Changes\n\n- d", text)
        self.assertIn("### Features\n\n- **ui:** a", text)
        self.assertIn("### Bug Fixes\n\n- b", text)
        self.assertNotIn("- c", text)


class Planning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = os.getcwd()
        os.chdir(self.tmp.name)
        for args in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["config", "commit.gpgsign", "false"], ["config", "tag.gpgsign", "false"]):
            subprocess.run(["git", *args], check=True)
        self.commit("feat: first")
        subprocess.run(["git", "tag", "v4.4.0"], check=True)

    def tearDown(self):
        os.chdir(self.cwd)
        self.tmp.cleanup()

    def commit(self, message):
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", message], check=True)

    def test_rc_sequence(self):
        self.assertEqual(release.plan_rc("HEAD")["release"], "false")
        self.commit("docs: only docs")
        self.assertEqual(release.plan_rc("HEAD")["release"], "false")
        self.commit("fix: bug")
        plan = release.plan_rc("HEAD")
        self.assertEqual((plan["tag"], plan["version"]), ("v4.4.1-rc.1", "4.4.1"))
        subprocess.run(["git", "tag", plan["tag"]], check=True)
        self.assertEqual(release.plan_rc("HEAD")["release"], "false")
        self.commit("feat: thing")
        plan = release.plan_rc("HEAD")
        self.assertEqual(plan["tag"], "v4.5.0-rc.1")
        self.assertIn("thing", plan["notes_body"])
        self.assertNotIn("bug", plan["notes_body"])
        subprocess.run(["git", "tag", plan["tag"]], check=True)
        self.commit("fix: another")
        self.assertEqual(release.plan_rc("HEAD")["tag"], "v4.5.0-rc.2")

    def test_staging_version_follows_nearest_tag(self):
        plan = release.plan_staging("HEAD")
        self.assertEqual((plan["release"], plan["tag"], plan["version"]), ("true", "staging", "4.4.0"))
        self.commit("feat: next")
        subprocess.run(["git", "tag", "v4.5.0-rc.3"], check=True)
        self.commit("fix: more")
        self.assertEqual(release.plan_staging("HEAD")["version"], "4.5.0")

    def test_only_notarized_tags_can_be_promoted(self):
        self.assertFalse(release.notarized("v4.4.0"))
        os.mkdir("scripts")
        Path("scripts/package-dmg.sh").write_text("")
        subprocess.run(["git", "add", "scripts"], check=True)
        self.commit("feat: notarize")
        subprocess.run(["git", "tag", "v4.5.0-rc.1"], check=True)
        self.assertTrue(release.notarized("v4.5.0-rc.1"))


unittest.main()
