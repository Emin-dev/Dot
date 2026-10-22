"""Phase 7s — sandboxed, trace-free, per-user Dot.

Source-level guardrails. The real install/launch/uninstall/snapshot proof runs
in .github/workflows/privacy-clean.yml on a hosted macOS runner.
"""
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ("curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/"
           "install-dot.sh | bash")
UNINSTALL = ("curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/"
             "uninstall-dot.sh | bash")


def read(relative):
    return (ROOT / relative).read_text()


class Phase7sContractTests(unittest.TestCase):
    def test_entitlements_are_minimal_and_sandboxed(self):
        entitlements = plistlib.loads((ROOT / "Resources/Dot.entitlements").read_bytes())
        self.assertIs(entitlements["com.apple.security.app-sandbox"], True)
        self.assertIs(entitlements["com.apple.security.network.client"], True)
        self.assertIs(entitlements["com.apple.security.network.server"], True)
        self.assertIs(entitlements["com.apple.security.device.audio-input"], True)
        self.assertIs(entitlements["com.apple.security.files.user-selected.read-write"], True)
        self.assertIs(entitlements["com.apple.security.personal-information.calendars"], True)
        self.assertIs(entitlements["com.apple.security.automation.apple-events"], True)
        self.assertEqual(set(entitlements), {
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "com.apple.security.device.audio-input",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.personal-information.calendars",
            "com.apple.security.automation.apple-events",
        })

    def test_every_packaging_path_signs_with_entitlements_and_runtime(self):
        signer = read("scripts/sign_sandbox_app.sh")
        self.assertIn("--entitlements", signer)
        self.assertIn("--options runtime", signer)
        self.assertIn("com.apple.security.app-sandbox", signer)
        self.assertNotIn("--deep \"$APP\"", signer)
        for script in ("build.sh", "scripts/package_default_release.sh",
                       "scripts/build_complete.sh", "scripts/build-and-sign-on-mac.sh",
                       "scripts/install_local.sh", "scripts/package_public_release.sh"):
            self.assertIn("sign_sandbox_app.sh", read(script), script)

    def test_installer_is_per_user_and_never_needs_admin(self):
        script = read("scripts/install-dot.sh")
        self.assertIn('INSTALL_DIR="${DOT_INSTALL_DIR:-$HOME/Applications}"', script)
        self.assertIn('fail "Dot installs per-user', script)
        for forbidden in ("osascript -e 'do shell script", "defaults write", "/Library/LaunchAgents"):
            self.assertNotIn(forbidden, script)
        self.assertIsNone(re.search(r"^\s*sudo\b", script, re.M), "installer must not run sudo")
        self.assertIn('xattr -dr "$ATTR" "$STAGED"', script)
        self.assertIn("xattr -p \"$ATTR\" \"$STAGED\"", script)
        self.assertIn("com.apple.security.app-sandbox", script)
        self.assertIn("macOS refused to open Dot", script)
        self.assertIn("Gatekeeper:", script)
        self.assertIn("PASS: Dot is installed at $APP", script)
        self.assertIn(UNINSTALL, script)

    def test_uninstaller_removes_every_documented_trace(self):
        script = read("scripts/uninstall-dot.sh")
        for required in (
            "tccutil reset All \"$BUNDLE_ID\"",
            "Library/Containers/$BUNDLE_ID",
            "Library/Group Containers/group.$BUNDLE_ID",
            "Library/Caches/$BUNDLE_ID",
            "Library/Saved Application State/$BUNDLE_ID.savedState",
            "Library/Preferences/$BUNDLE_ID.plist",
            "Library/HTTPStorages/$BUNDLE_ID",
            "Library/WebKit/$BUNDLE_ID",
            "Library/Application Support/Dot",
            ".dot-install-created-applications",
            "PASS: your Mac is back to how it was",
            "FAIL:",
        ):
            self.assertIn(required, script)
        self.assertIsNone(re.search(r"^\s*sudo\b", script, re.M), "uninstaller must not run sudo")

    def test_app_offers_the_same_complete_removal_and_sandbox_self_check(self):
        app = read("src/App.swift")
        self.assertIn('NSMenuItem(title: "Remove Dot completely…"', app)
        self.assertIn("func removeDotCompletely()", app)
        self.assertIn("uninstall-dot", app)
        self.assertIn("DOT_SANDBOX_SELF_CHECK", app)
        self.assertIn("outside_write_denied", app)
        self.assertIn("APP_SANDBOX_CONTAINER_ID", app)
        # The in-app path must not install a helper or ask for a privileged tool.
        for forbidden in ("SMAppService", "SMJobBless", "AuthorizationCreate"):
            self.assertNotIn(forbidden, app)

    def test_ci_proves_sandbox_smoke_and_zero_trace(self):
        workflow = read(".github/workflows/privacy-clean.yml")
        for required in (
            "runs-on: macos-26",
            "privacy_snapshot.py .tmp/snapshot-before.json",
            'install-dot.sh" | bash',
            "com.apple.security.app-sandbox",
            "DOT_SANDBOX_SELF_CHECK=1",
            "install_acceptance_check.sh",
            'uninstall-dot.sh" | bash',
            "PASS: your Mac is back to how it was",
            "privacy_snapshot.py .tmp/snapshot-after.json",
            "privacy_diff.py .tmp/snapshot-before.json .tmp/snapshot-after.json",
        ):
            self.assertIn(required, workflow)
        allowlist = read("scripts/privacy_allowlist.txt")
        self.assertNotIn("app.dot.local", allowlist)
        self.assertIn("|", allowlist)
        self.assertIn("Dot-owned paths are never listed", allowlist)

    def test_release_ships_the_uninstaller_and_docs_show_both_lines(self):
        workflow = read(".github/workflows/release.yml")
        self.assertIn("scripts/uninstall-dot.sh", workflow)
        self.assertIn("cp scripts/install-dot.sh scripts/uninstall-dot.sh", workflow)
        test_today = read("docs/TEST_TODAY.md")
        self.assertEqual(test_today.splitlines()[0], INSTALL)
        self.assertIn(UNINSTALL, test_today)
        self.assertIn("PASS: your Mac is back to how it was", test_today)
        readme = read("README.md")
        self.assertIn(INSTALL, readme)
        self.assertIn(UNINSTALL, readme)
        self.assertIn("~/Applications", readme)
        self.assertIn("App Sandbox", readme)

    def test_sandbox_runtime_execs_python_once(self):
        runtime = read("Resources/Runtime/dot_runtime.py")
        self.assertIn("child_arguments = [str(python)", runtime)
        self.assertIn("command = child_arguments", runtime)
        self.assertIn("command.extend(child_arguments)", runtime)
        self.assertNotIn("command = [str(python)]\n        else:", runtime)

    def test_no_background_or_system_write_paths_were_added(self):
        workflow = read(".github/workflows/privacy-clean.yml")
        for forbidden in ("LaunchAgents", "LaunchDaemons", "sudo", "launchctl load"):
            self.assertNotIn(forbidden, workflow)
        entitlements = plistlib.loads((ROOT / "Resources/Dot.entitlements").read_bytes())
        self.assertFalse(any(key.startswith("com.apple.security.temporary-exception")
                             for key in entitlements))


class PrivacySnapshotDiffTests(unittest.TestCase):
    """Exercise the no-trace snapshot and diff against a disposable home."""

    def run_script(self, name, *arguments, env):
        return subprocess.run(
            [sys.executable, "-B", str(ROOT / "scripts" / name), *map(str, arguments)],
            env=env, capture_output=True, text=True,
        )

    def test_snapshot_diff_fails_for_dot_owned_leftovers_and_passes_when_clean(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            (home / "Documents").mkdir(parents=True)
            (home / "Documents/keep.txt").write_text("keep\n")
            # Pre-create the Apple-owned parents and one Apple cache directory
            # so the only unexplained difference later is the Dot leftover.
            (home / "Library/Caches/com.apple.transient").mkdir(parents=True)

            # Deterministic stand-ins so the OS listings never vary between the
            # two snapshots on a real Mac.
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for command in ("launchctl", "defaults", "sfltool", "pkgutil"):
                stub = bin_dir / command
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)

            env = dict(os.environ)
            env["HOME"] = str(home)
            env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
            env["DOT_SNAPSHOT_EXCLUDES"] = "/Applications:/Library"
            allowlist = ROOT / "scripts/privacy_allowlist.txt"
            before = root / "before.json"
            after = root / "after.json"

            first = self.run_script("privacy_snapshot.py", before, env=env)
            self.assertEqual(first.returncode, 0, first.stderr)
            second = self.run_script("privacy_snapshot.py", after, env=env)
            self.assertEqual(second.returncode, 0, second.stderr)
            clean = self.run_script("privacy_diff.py", before, after,
                                    "--allowlist", allowlist, env=env)
            self.assertEqual(clean.returncode, 0, clean.stderr)
            self.assertIn("PASS: no trace remains", clean.stdout)

            apple = home / "Library/Caches/com.apple.transient/blob"
            apple.write_text("os\n")
            with_apple = root / "with-apple.json"
            self.assertEqual(
                self.run_script("privacy_snapshot.py", with_apple, env=env).returncode, 0)
            allowed = self.run_script("privacy_diff.py", before, with_apple,
                                      "--allowlist", allowlist, env=env)
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            self.assertIn("allowed transient change", allowed.stdout)

            leftover = home / "Library/Caches/app.dot.local/trace.bin"
            leftover.parent.mkdir(parents=True)
            leftover.write_text("trace\n")
            changed = root / "changed.json"
            third = self.run_script("privacy_snapshot.py", changed, env=env)
            self.assertEqual(third.returncode, 0, third.stderr)
            failing = self.run_script("privacy_diff.py", before, changed,
                                      "--allowlist", allowlist, env=env)
            self.assertEqual(failing.returncode, 1, failing.stdout + failing.stderr)
            self.assertIn("app.dot.local", failing.stderr)
            self.assertIn("FAIL: the install/uninstall cycle was not trace-free",
                          failing.stderr)


if __name__ == "__main__":
    unittest.main()
