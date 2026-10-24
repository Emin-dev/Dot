"""Phase 7s — sandboxed, trace-free, per-user Dot.

Source-level guardrails. The real install/launch/uninstall/snapshot proof runs
in .github/workflows/privacy-clean.yml on a hosted macOS runner.
"""
import hashlib
import os
import plistlib
import re
import shutil
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
            # R21 (owner answer 2026-10-22): narrow exceptions so the documented
            # page reader, dark mode/sleep, media pausing and file awareness work.
            "com.apple.security.files.downloads.read-only",
            "com.apple.security.temporary-exception.files.home-relative-path.read-only",
            "com.apple.security.temporary-exception.apple-events",
            # R22 (owner answer 2026-10-23): keep the chosen folder across launches.
            "com.apple.security.files.bookmarks.app-scope",
        })
        self.assertEqual(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"],
                         ["/Desktop/", "/Documents/"])
        self.assertEqual(entitlements["com.apple.security.temporary-exception.apple-events"], [
            "com.apple.systemevents", "com.apple.Safari", "com.google.Chrome",
            "com.apple.TextEdit", "com.apple.Music", "com.spotify.client",
        ])

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
        # R21 allows only the two read-only/Apple-event exceptions, never a write path.
        exceptions = {key for key in entitlements if key.startswith("com.apple.security.temporary-exception")}
        self.assertEqual(exceptions, {
            "com.apple.security.temporary-exception.files.home-relative-path.read-only",
            "com.apple.security.temporary-exception.apple-events",
        })


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


# macOS keeps bash 3.2 at /bin/bash; the scripts must run there.
BASH = "/bin/bash" if Path("/bin/bash").exists() else (shutil.which("bash") or "bash")
DOT_ID = "app.dot.local"


def write_shell_stub(directory, name, body):
    path = directory / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


def write_python_stub(directory, name, body):
    path = directory / name
    path.write_text(f"#!{sys.executable}\n" + body)
    path.chmod(0o755)
    return path


def rewrite_once(test, text, old, new):
    """Point one hard-coded macOS path at the disposable test tree."""
    test.assertEqual(text.count(old), 1, old)
    return text.replace(old, new)


def make_app(path, bundle_id):
    (path / "Contents/MacOS").mkdir(parents=True)
    executable = path / "Contents/MacOS/Dot"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    if bundle_id is not None:
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
    return path


PLISTBUDDY_STUB = """import plistlib, sys
args = sys.argv[1:]
if len(args) != 3 or args[0] != "-c" or not args[1].startswith("Print :"):
    sys.exit(1)
try:
    with open(args[2], "rb") as handle:
        value = plistlib.load(handle)
    for key in args[1][len("Print :"):].split(":"):
        value = value[key]
except Exception:
    sys.exit(1)
print(value)
"""


class DisposableTree:
    def make_tree(self):
        base = ROOT / ".tmp"
        base.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        (self.root / "tmp").mkdir()


class UninstallerOnlyRemovesDotTests(DisposableTree, unittest.TestCase):
    """Audit S12: run the real uninstaller against a disposable home.

    Every macOS tool that could touch the real Mac (Keychain, TCC, the Dock,
    LaunchServices, /Applications, /var/folders) is a stub or a test path.
    """

    def setUp(self):
        self.make_tree()
        self.home = self.root / "home"
        (self.home / "Library").mkdir(parents=True)
        for name, body in (("uname", "echo Darwin"), ("pgrep", "exit 1"), ("pkill", "exit 0"),
                           ("osascript", "exit 0"), ("defaults", "exit 1"), ("killall", "exit 0"),
                           ("launchctl", "exit 0"), ("getconf", "exit 1"), ("security", "exit 1"),
                           ("sqlite3", "exit 1"), ("tccutil", "exit 0")):
            write_shell_stub(self.stubs, name, body)
        plistbuddy = write_python_stub(self.stubs, "PlistBuddy", PLISTBUDDY_STUB)
        script = read("scripts/uninstall-dot.sh")
        self.assertIn("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier'", script)
        script = script.replace("/usr/libexec/PlistBuddy", str(plistbuddy))
        script = rewrite_once(self, script, 'LEGACY_APP="/Applications/Dot.app"',
                              f'LEGACY_APP="{self.root}/system-applications/Dot.app"')
        script = rewrite_once(self, script, 'LSREGISTER="/System/Library/Frameworks/CoreServices.framework/'
                              'Frameworks/LaunchServices.framework/Support/lsregister"',
                              f'LSREGISTER="{self.root}/no-lsregister"')
        self.script = self.root / "uninstall-dot.sh"
        self.script.write_text(script)

    def uninstall(self, **environment):
        env = {"HOME": str(self.home), "PATH": f"{self.stubs}:/usr/bin:/bin",
               "TMPDIR": str(self.root / "tmp"), **environment}
        return subprocess.run([BASH, str(self.script)], env=env, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=120)

    def assertPassed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip().splitlines()[-1], "PASS: your Mac is back to how it was")

    def test_a_bundle_id_that_is_not_plain_reverse_dns_removes_nothing(self):
        documents = self.home / "Documents"
        documents.mkdir()
        (documents / "keep.txt").write_text("keep\n")
        # The parent exists, so Containers/../../Documents really is ~/Documents.
        (self.home / "Library/Containers").mkdir()
        app = make_app(self.home / "Applications/Dot.app", DOT_ID)
        for bad in ("../../Documents", "app.dot..local", "app.dot.local/../..", "/tmp", "app/dot",
                    "1app.dot", "-rf", "app dot", "app.dot.local\n", "app.dot.local*"):
            with self.subTest(bundle_id=bad):
                result = self.uninstall(DOT_BUNDLE_ID=bad)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("FAIL: DOT_BUNDLE_ID is not a valid bundle id", result.stderr)
                self.assertTrue((documents / "keep.txt").is_file())
                self.assertTrue(app.is_dir())
                self.assertTrue((self.home / "Library/Containers").is_dir())

    def test_an_app_that_is_not_dot_is_left_alone(self):
        for bundle_id, shown in (("com.example.other-dot", "com.example.other-dot"), (None, "missing")):
            with self.subTest(bundle_id=bundle_id):
                app = make_app(self.home / "Applications/Dot.app", bundle_id)
                result = self.uninstall()
                self.assertPassed(result)
                self.assertIn(f"note: leaving {app} alone; its bundle id is {shown}, not {DOT_ID}",
                              result.stdout)
                self.assertTrue((app / "Contents/MacOS/Dot").is_file())
                shutil.rmtree(app)

    def test_dot_and_its_marked_folders_go_and_lookalikes_stay(self):
        app = make_app(self.home / "Applications/Dot.app", DOT_ID)
        (self.home / "Applications/.dot-install-created-applications").write_text("")
        container = self.home / f"Library/Containers/{DOT_ID}/Data"
        container.mkdir(parents=True)
        legacy_logs = self.home / "Library/Application Support/Dot/Logs"
        legacy_logs.mkdir(parents=True)
        (legacy_logs / "dot_chat_log.txt").write_text("user: hi\n")
        other_logs = self.home / "Library/Logs/Dot"
        other_logs.mkdir(parents=True)
        (other_logs / "another-app.log").write_text("not Dot\n")
        reports = self.home / "Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        ours = reports / "Dot-2026-10-24-101010.ips"
        ours.write_text('{"app_name":"Dot","bundleID":"app.dot.local"}\n{}\n')
        theirs = reports / "Dot-2026-10-24-111111.ips"
        theirs.write_text('{"app_name":"Dot","bundleID":"com.example.dot"}\n{}\n')
        lookalike = reports / "DotHelper-2026-10-24-121212.ips"
        lookalike.write_text('{"app_name":"DotHelper","bundleID":"app.dot.local.helper"}\n{}\n')

        result = self.uninstall()

        self.assertPassed(result)
        self.assertFalse(app.exists())
        self.assertFalse((self.home / "Applications").exists())
        self.assertFalse((self.home / f"Library/Containers/{DOT_ID}").exists())
        self.assertFalse((self.home / "Library/Application Support/Dot").exists())
        self.assertTrue((other_logs / "another-app.log").is_file())
        self.assertIn(f"note: leaving {other_logs} alone; it holds none of Dot's own files", result.stdout)
        self.assertFalse(ours.exists())
        self.assertTrue(theirs.is_file())
        self.assertTrue(lookalike.is_file())

    def test_generic_dot_folders_need_one_of_dots_own_files(self):
        support = self.home / "Library/Application Support/Dot"
        support.mkdir(parents=True)
        (support / "settings.json").write_text("{}\n")
        logs = self.home / "Library/Logs/Dot"
        logs.mkdir(parents=True)
        (logs / "dot-sync.log").write_text("sync\n")
        result = self.uninstall()
        self.assertPassed(result)
        self.assertTrue((support / "settings.json").is_file())
        self.assertIn(f"note: leaving {support} alone; it holds none of Dot's own files", result.stdout)
        self.assertFalse(logs.exists())

        # A symlink named Dot is never followed into another folder.
        shutil.rmtree(support)
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "install-id").write_text("someone-else\n")
        support.symlink_to(elsewhere, target_is_directory=True)
        result = self.uninstall()
        self.assertPassed(result)
        self.assertTrue((elsewhere / "install-id").is_file())
        self.assertTrue(support.is_symlink())


CURL_STUB = """import os, shutil, sys
args = sys.argv[1:]
url = args[-1]
with open(os.environ["FAKE_CURL_LOG"], "a") as log:
    log.write(url + "\\n")
base = os.environ["FAKE_RELEASE_BASE"] + "/"
if "-o" not in args or not url.startswith(base):
    sys.exit(6)
source = os.path.join(os.environ["FAKE_RELEASE_DIR"], url[len(base):])
if not os.path.isfile(source):
    sys.exit(22)
shutil.copyfile(source, args[args.index("-o") + 1])
"""
SHASUM_STUB = """import hashlib, sys
args = sys.argv[1:]
if len(args) != 3 or args[:2] != ["-a", "256"]:
    sys.exit(2)
with open(args[2], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest() + "  " + args[2])
"""
HDIUTIL_STUB = """import os, shutil, sys
args = sys.argv[1:]
if args[:1] == ["attach"]:
    mount = args[args.index("-mountpoint") + 1]
    shutil.copytree(os.environ["FAKE_APP"], os.path.join(mount, "Dot.app"), symlinks=True)
"""
DITTO_STUB = """import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2], symlinks=True)
"""
CODESIGN_STUB = """import os, sys
args = sys.argv[1:]
if "-d" in args and ("--xml" in args or ":-" in args):
    with open(os.environ["FAKE_ENTITLEMENTS"], "rb") as handle:
        sys.stdout.buffer.write(handle.read())
"""
# Used only where macOS' own /usr/bin/plutil is missing: plutil writes XML with
# the dictionary keys sorted, so key order never decides the comparison.
PLUTIL_STUB = """import plistlib, sys
args = sys.argv[1:]
if len(args) != 5 or args[:4] != ["-convert", "xml1", "-o", "-"]:
    sys.exit(2)
try:
    with open(args[4], "rb") as handle:
        value = plistlib.load(handle)
except Exception:
    sys.exit(1)
sys.stdout.buffer.write(plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True))
"""


class InstallerEntitlementTests(DisposableTree, unittest.TestCase):
    """Audit S11: the real installer, piped into bash as documented, with macOS
    tools stubbed and DOT_RELEASE_BASE pointing at a local release like CI."""

    BASE = "http://127.0.0.1:8765"

    def setUp(self):
        self.make_tree()
        release = self.root / "release"
        release.mkdir()
        dmg = b"stand-in disk image\n"
        (release / "Dot.dmg").write_bytes(dmg)
        (release / "Dot.dmg.sha256").write_text(hashlib.sha256(dmg).hexdigest() + "  Dot.dmg\n")
        self.app_source = make_app(self.root / "dmg/Dot.app", DOT_ID)
        state = self.root / "state"
        state.mkdir()
        for name, body in (("uname", "echo Darwin"), ("sw_vers", "echo 27.0"),
                           ("sysctl", 'case "$2" in machdep.cpu.brand_string) echo "Apple M5 Pro" ;; '
                                      '*) echo 51539607552 ;; esac'),
                           ("xattr", 'case "$1" in -p) exit 1 ;; esac'),
                           ("osascript", "exit 0"), ("pkill", "exit 0"), ("spctl", "exit 0"),
                           ("open", f'touch "{state}/running"'),
                           ("pgrep", f'[ -f "{state}/running" ]')):
            write_shell_stub(self.stubs, name, body)
        for name, body in (("curl", CURL_STUB), ("shasum", SHASUM_STUB), ("hdiutil", HDIUTIL_STUB),
                           ("ditto", DITTO_STUB), ("codesign", CODESIGN_STUB)):
            write_python_stub(self.stubs, name, body)
        if not Path("/usr/bin/plutil").exists():
            write_python_stub(self.stubs, "plutil", PLUTIL_STUB)
        script = read("scripts/install-dot.sh")
        script = rewrite_once(self, script, "\nexport PATH=/usr/bin:/bin:/usr/sbin:/sbin\n",
                              f"\nexport PATH={self.stubs}:/usr/bin:/bin:/usr/sbin:/sbin\n")
        self.script = rewrite_once(self, script, 'LEGACY_APP="/Applications/Dot.app"',
                                   f'LEGACY_APP="{self.root}/system-applications/Dot.app"')
        self.release = release
        self.state = state
        self.runs = 0

    def install(self, entitlements):
        self.runs += 1
        home = self.root / f"home-{self.runs}"
        home.mkdir()
        signed = self.root / f"signed-{self.runs}.entitlements"
        signed.write_bytes(entitlements)
        (self.state / "running").unlink(missing_ok=True)
        curl_log = self.root / f"curl-{self.runs}.log"
        env = {"HOME": str(home), "PATH": f"{self.stubs}:/usr/bin:/bin", "TMPDIR": str(self.root / "tmp"),
               "DOT_RELEASE_BASE": self.BASE, "FAKE_RELEASE_BASE": self.BASE,
               "FAKE_RELEASE_DIR": str(self.release), "FAKE_CURL_LOG": str(curl_log),
               "FAKE_APP": str(self.app_source), "FAKE_ENTITLEMENTS": str(signed)}
        # stdin is the script, exactly like `curl -fsSL .../install-dot.sh | bash`.
        result = subprocess.run([BASH], input=self.script, env=env, capture_output=True, text=True,
                                timeout=120)
        return result, home / "Applications/Dot.app", curl_log

    def test_the_installer_runs_only_macos_own_tools(self):
        script = read("scripts/install-dot.sh")
        strict = "\nset -euo pipefail\n"
        self.assertIn(strict, script)
        after_set = script.split(strict, 1)[1]
        first_command = next(line for line in after_set.splitlines()
                             if line.strip() and not line.lstrip().startswith("#"))
        self.assertEqual(first_command, "export PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(len(re.findall(r"(?m)^\s*(?:export\s+)?PATH=", script)), 1)

    def test_the_embedded_entitlements_are_exactly_the_signed_set(self):
        script = read("scripts/install-dot.sh")
        embedded = script.split("<<'DOT_EXPECTED_ENTITLEMENTS'\n", 1)[1].split("\nDOT_EXPECTED_ENTITLEMENTS\n", 1)[0]
        expected = plistlib.loads((ROOT / "Resources/Dot.entitlements").read_bytes())
        self.assertEqual(plistlib.loads(embedded.encode()), expected)
        self.assertEqual(len(expected), 11)

    def test_installer_accepts_only_the_exact_entitlement_set(self):
        exact = (ROOT / "Resources/Dot.entitlements").read_bytes()
        result, app, curl_log = self.install(exact)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: sandbox entitlements and code signature verified", result.stdout)
        self.assertIn(f"PASS: Dot is installed at {app}", result.stdout)
        self.assertTrue((app / "Contents/MacOS/Dot").is_file())
        requested = curl_log.read_text().splitlines()
        self.assertIn(f"{self.BASE}/Dot.dmg", requested)
        self.assertIn(f"{self.BASE}/Dot.dmg.sha256", requested)

        entitlements = plistlib.loads(exact)
        reordered = plistlib.dumps(dict(reversed(list(entitlements.items()))), sort_keys=False)
        result, app, _ = self.install(reordered)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(app.is_dir())

        extra = dict(entitlements, **{"com.apple.security.cs.disable-library-validation": True})
        missing = {k: v for k, v in entitlements.items() if k != "com.apple.security.network.server"}
        wider = dict(entitlements)
        wider["com.apple.security.temporary-exception.files.home-relative-path.read-only"] = [
            "/Desktop/", "/Documents/", "/Library/"]
        switched_off = dict(entitlements, **{"com.apple.security.app-sandbox": False})
        unsandboxed = {k: v for k, v in entitlements.items() if k != "com.apple.security.app-sandbox"}
        for name, signed, message in (
                ("extra", plistlib.dumps(extra), "are not exactly Dot's 11 App Sandbox entitlements"),
                ("missing", plistlib.dumps(missing), "are not exactly Dot's 11 App Sandbox entitlements"),
                ("wider", plistlib.dumps(wider), "are not exactly Dot's 11 App Sandbox entitlements"),
                ("switched off", plistlib.dumps(switched_off), "are not exactly Dot's 11 App Sandbox entitlements"),
                ("unsandboxed", plistlib.dumps(unsandboxed), "is not signed for the Apple App Sandbox"),
                ("unsigned", b"", "is not signed for the Apple App Sandbox")):
            with self.subTest(entitlements=name):
                result, app, _ = self.install(signed)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("FAIL: ", result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(app.parent.exists(), "a refused install leaves no ~/Applications")
        self.assertEqual(list((self.root / "tmp").glob("dot-install.*")), [])


if __name__ == "__main__":
    unittest.main()
