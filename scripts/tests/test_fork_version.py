"""Exercise fork versions against real, isolated Git histories (no network)."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "fork-version.py"


class ForkVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trio-fork-version-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo with spaces"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Version Test")
        self.git("config", "user.email", "version-test@example.invalid")
        self.commit("Base")
        self.base = self.git("rev-parse", "HEAD")
        self.config = self.repo / "ForkVersion.json"
        self.config.write_text(json.dumps({"series": "0.1", "base_commit": self.base}))
        self.git("add", "ForkVersion.json")
        self.commit("Introduce fork version")

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], env=self.env, text=True
        ).strip()

    def commit(self, message):
        self.git("commit", "--quiet", "--allow-empty", "-m", message)

    def version(self, *args, repo=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(repo or self.repo), *args],
            env=self.env, text=True, capture_output=True
        )

    def assertVersion(self, revision, suffix=""):
        result = self.version()
        self.assertEqual(result.returncode, 0, result.stderr)
        sha = self.git("rev-parse", "HEAD")[:10]
        self.assertEqual(result.stdout.strip(), f"0.1.{revision}+{sha}{suffix}")
        return result.stdout

    def test_new_commits_increment_and_repeated_builds_are_stable(self):
        first = self.assertVersion(1)
        self.assertEqual(self.assertVersion(1), first)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.commit("Second change")
        self.assertVersion(2)

    def test_merges_count_once_without_importing_upstream_commit_counts(self):
        self.git("checkout", "-q", "-b", "upstream")
        self.commit("Upstream one")
        self.commit("Upstream two")
        self.git("checkout", "-q", "main")
        self.commit("Fork change")
        self.git("merge", "--no-ff", "--quiet", "upstream", "-m", "Merge upstream")
        self.assertVersion(3)

    def test_equal_revision_on_two_branches_has_distinct_commit_identity(self):
        self.git("checkout", "-q", "-b", "feature")
        self.commit("Feature")
        feature = self.assertVersion(2)
        self.git("checkout", "-q", "main")
        self.commit("Main")
        self.assertNotEqual(self.assertVersion(2), feature)

    def test_detached_checkout_preserves_version(self):
        expected = self.assertVersion(1)
        self.git("checkout", "-q", "--detach")
        self.assertEqual(self.assertVersion(1), expected)

    def test_tracked_and_untracked_changes_are_marked_as_dirty(self):
        with self.config.open("a") as handle:
            handle.write("\n")
        self.assertVersion(1, ".dirty")
        self.git("add", "ForkVersion.json")
        self.assertVersion(1, ".dirty")
        self.commit("Whitespace")
        (self.repo / "new-source.swift").write_text("// Local change\n")
        self.assertVersion(2, ".dirty")

    def test_committed_mode_reports_source_revision_despite_build_changes(self):
        expected = self.assertVersion(1)
        (self.repo / "generated-signing-settings").write_text("Build configuration")
        result = self.version("--committed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)

    def test_committed_mode_uses_the_committed_version_configuration(self):
        expected = self.assertVersion(1)
        self.config.write_text(json.dumps({"series": "9.9", "base_commit": self.git("rev-parse", "HEAD")}))
        result = self.version("--committed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)

    def test_introducing_uncommitted_versioning_is_always_marked_dirty(self):
        self.git("checkout", "-q", "--detach", self.base)
        self.config.write_text(json.dumps({"series": "0.1", "base_commit": self.base}))
        result = self.version("--committed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"0.1.0+{self.base[:10]}.dirty")

    def test_shallow_history_fails_instead_of_restarting_numbering(self):
        clone = Path(self.temp.name) / "shallow"
        self.git("clone", "--quiet", "--depth=1", self.repo.as_uri(), str(clone))
        result = self.version(repo=clone)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fetch-depth: 0", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_unknown_base_fails_instead_of_making_up_a_version(self):
        self.config.write_text(json.dumps({"series": "0.1", "base_commit": "a" * 40}))
        result = self.version()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("first-parent", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_invalid_version_series_is_rejected(self):
        self.config.write_text(json.dumps({"series": "invalid", "base_commit": self.base}))
        result = self.version()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("series", result.stderr)


if __name__ == "__main__":
    unittest.main()
