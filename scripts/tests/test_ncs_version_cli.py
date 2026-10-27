#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""CLI contract tests for the NCS version guard and bump command."""

import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
GIT = shutil.which("git")
OLD = "v1.2.3"
NEW = "v1.2.4"


class NcsCommandsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        for name in ("check-ncs-version.sh", "bump-ncs.sh", "ncs-version-lib.sh", "ncs-version-refs.py"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        self.write("west.yml", "manifest:\n  projects:\n    - name: nrf\n      revision: v1.2.3\n")
        self.write("README.md", "nRF Connect SDK 1.2.3\nNCS\n v1.2.3\n")
        self.write("docs/build.md", "sdk-nrf-toolchain:v1.2.3\n")
        self.write("docs/hardware.md", "NCS 1.2.3\n")
        self.write("docs/contributing.md", "sdk-nrf @ v1.2.3\n")
        self.write(".github/workflows/ci.yml", "ncs-ws-v1.2.3\nNCS_VERSION_1_2_3\n")
        self.write(".github/release-notes/old.md", "NCS v9.9.9\n")
        self.write("docs/adr/0001.md", "NCS v9.9.9\n")
        self.write("docs/bench.md", "- RTT: `*** Booting nRF Connect SDK v9.9.9 ***`\n")
        self.write("scripts/tests/fixture.txt", "NCS v9.9.9\n")
        self.write("bin/gh", "#!/bin/sh\nif [ \"$1\" = repo ]; then echo main; exit 0; fi\nif [ \"${FAIL_PR:-0}\" = 1 ]; then exit 1; fi\necho https://example.invalid/pr/1\n")
        self.write("bin/docker", "#!/bin/sh\n[ \"${IMAGE_EXISTS:-1}\" = 1 ]\n")
        self.write("bin/git", f"#!/bin/sh\nif [ \"$1\" = ls-remote ]; then [ \"${{TAG_EXISTS:-1}}\" = 1 ]; exit $?; fi\nif [ \"$1\" = -C ] && [ \"$3\" = push ]; then exit 0; fi\nexec {GIT} \"$@\"\n")
        for name in ("gh", "docker", "git"):
            (self.root / "bin" / name).chmod(0o755)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.root / "bin") + os.pathsep + self.env["PATH"])
        for key in ("GITHUB_ACTIONS", "ENFORCE_NCS_VAR", "NCS_VERSION"):
            self.env.pop(key, None)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def git(self, *args):
        return subprocess.run([GIT, *args], cwd=self.root, text=True, capture_output=True, check=True)

    def command(self, name, *args, **env):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / name), *args], cwd=self.root,
            env={**self.env, **env}, text=True, capture_output=True,
        )

    def test_guard_accepts_live_refs_and_ignores_historical_records(self):
        result = self.command("check-ncs-version.sh")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_guard_rejects_every_live_reference_form(self):
        cases = {
            "README.md": "nRF Connect SDK 9.9.9\n",
            "docs/hardware.md": "NCS\n v9.9.9\n",
            "docs/contributing.md": "sdk-nrf @ 9.9.9\n",
            "docs/build.md": "sdk-nrf-toolchain:v9.9.9\n",
            ".github/workflows/ci.yml": "ncs-ws-v9.9.9\nNCS_VERSION_9_9_9\n",
        }
        for path, content in cases.items():
            with self.subTest(path=path):
                original = (self.root / path).read_text()
                self.write(path, content)
                result = self.command("check-ncs-version.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(path, result.stderr)
                self.write(path, original)

    def test_dry_run_rewrites_only_live_versions(self):
        result = self.command("bump-ncs.sh", NEW, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("revision: v1.2.4", (self.root / "west.yml").read_text())
        self.assertIn("nRF Connect SDK 1.2.4", (self.root / "README.md").read_text())
        self.assertIn("NCS_VERSION_1_2_4", (self.root / ".github/workflows/ci.yml").read_text())
        self.assertIn("NCS\n v1.2.4", (self.root / "README.md").read_text())
        self.assertIn("v9.9.9", (self.root / "docs/bench.md").read_text())
        self.assertIn("v9.9.9", (self.root / "docs/adr/0001.md").read_text())
        self.assertIn("v9.9.9", (self.root / ".github/release-notes/old.md").read_text())
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")

    def test_bump_refuses_preconditions_without_edits(self):
        cases = (
            ("dirty", lambda: self.write("untracked", "x"), {}),
            ("branch", lambda: self.git("checkout", "-qb", "feature"), {}),
            ("tag", lambda: None, {"TAG_EXISTS": "0"}),
            ("image", lambda: None, {"IMAGE_EXISTS": "0"}),
        )
        for name, setup, env in cases:
            with self.subTest(name=name):
                setup()
                result = self.command("bump-ncs.sh", NEW, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("revision: v1.2.3", (self.root / "west.yml").read_text())
                if name == "dirty":
                    (self.root / "untracked").unlink()
                if name == "branch":
                    self.git("checkout", "-q", "main")

    def test_failed_guard_restores_worktree(self):
        result = self.command("bump-ncs.sh", NEW, "--dry-run", GITHUB_ACTIONS="true", NCS_VERSION=OLD)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_already_pinned_target_is_noop(self):
        result = self.command("bump-ncs.sh", OLD, TAG_EXISTS="0", IMAGE_EXISTS="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to do", result.stdout)

    def test_failed_pr_creation_reports_failure(self):
        reason = self.root / "reason.txt"
        reason.write_text("DRGN-29129 and DRGN-29277 are fixed.\n")
        self.git("add", "reason.txt")
        self.git("commit", "-qm", "fixture reason")
        result = self.command("bump-ncs.sh", NEW, "--reason-file", str(reason), FAIL_PR="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("PR opened", result.stdout)
        committed = self.git("show", "--pretty=format:", "--name-only", "HEAD").stdout.splitlines()
        self.assertEqual(set(filter(None, committed)), {
            "west.yml", "README.md", "docs/build.md", "docs/hardware.md",
            "docs/contributing.md", ".github/workflows/ci.yml",
        })
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertIn("DRGN-29129 and DRGN-29277", self.git("log", "-1", "--format=%B").stdout)

    def test_guard_checks_ci_variable_when_enforced(self):
        for value in ("", NEW):
            with self.subTest(value=value):
                result = self.command("check-ncs-version.sh", GITHUB_ACTIONS="true", NCS_VERSION=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("NCS_VERSION", result.stderr)


if __name__ == "__main__":
    unittest.main()
