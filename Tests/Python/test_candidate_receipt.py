"""Portable receipts use synthetic files; they do not build or launch a Mac app."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("candidate_receipt", ROOT / "scripts/write_candidate_receipt.py")
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)


class CandidateReceiptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "build/Dot.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        self.commit = "a" * 40
        self.provenance = {"commit": self.commit, "source_dirty": False, "signing": "ad-hoc",
                           "notarized": False, "runtime_bundled": False, "models_bundled": False,
                           "llm_weights_download_on_first_launch": False}
        self.write_provenance()
        self.dmg = self.root / "build/Dot.dmg"
        self.dmg.write_bytes(b"synthetic DMG fixture; not installable")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "15.0"}))
        self.binary = self.app / "Contents/MacOS/Dot"
        self.binary.parent.mkdir()
        self.binary.write_bytes(b"synthetic binary fixture; not executable")
        # The development app always carries its native Rust runtimes.
        for native in ("dot-search", "dot-voice"):
            runtime = self.app / "Contents/MacOS" / native
            runtime.write_bytes(b"synthetic native runtime fixture")
            runtime.chmod(0o700)

    def write_provenance(self):
        (self.resources / "build-provenance.json").write_text(json.dumps(self.provenance))

    def make(self, **overrides):
        args = dict(root=self.root, commit=self.commit, host_arch="arm64", macos_version="15.7",
                    sdk_version="26.4", app_archs=["arm64"])
        args.update(overrides)
        return receipt.candidate_receipt(**args)

    def test_exact_dmg_checksum_commit_and_platform(self):
        result = self.make()
        self.assertEqual(result["commit"], self.commit)
        self.assertEqual(result["dmg"], {"file": "Dot.dmg", "bytes": self.dmg.stat().st_size,
                         "sha256": hashlib.sha256(self.dmg.read_bytes()).hexdigest()})
        self.assertEqual(result["platform"], {"os": "macOS", "minimum_version": "15.0",
            "executable_architectures": ["arm64"], "build_host_architecture": "arm64",
            "build_host_macos_version": "15.7", "sdk_version": "26.4"})
        self.assertFalse(result["final_installer"])
        self.assertFalse(result["runtime_bundled"])
        self.assertFalse(result["models_bundled"])
        self.assertTrue(result["search_runtime_bundled"])
        self.assertFalse(result["notarized"])
        self.assertEqual(result["hardware_acceptance"], "not-performed-by-CI")
        self.assertGreaterEqual(len(result["limitations"]), 6)

    def test_missing_non_executable_or_linked_native_runtime_fails(self):
        for native in ("dot-search", "dot-voice"):
            runtime = self.app / "Contents/MacOS" / native
            original = runtime.read_bytes()
            runtime.unlink()
            with self.subTest(native=native, state="missing"), self.assertRaises(ValueError): self.make()
            runtime.write_bytes(original); runtime.chmod(0o600)
            with self.subTest(native=native, state="not executable"), self.assertRaises(ValueError): self.make()
            runtime.chmod(0o700); runtime.unlink()
            runtime.symlink_to(self.binary)
            with self.subTest(native=native, state="linked"), self.assertRaises(ValueError): self.make()
            runtime.unlink(); runtime.write_bytes(original); runtime.chmod(0o700)

    def test_records_intel_build_without_claiming_arm_support(self):
        self.assertEqual(self.make(host_arch="x86_64", app_archs=["x86_64"])
                         ["platform"]["executable_architectures"], ["x86_64"])

    def test_missing_empty_or_linked_dmg_fails(self):
        self.dmg.unlink()
        with self.assertRaises(ValueError): self.make()
        self.dmg.touch()
        with self.assertRaises(ValueError): self.make()
        self.dmg.unlink(); self.dmg.symlink_to(self.binary)
        with self.assertRaises(ValueError): self.make()

    def test_provenance_does_not_accept_dirty_stale_or_complete_build(self):
        for key, value in [("commit", "b" * 40), ("source_dirty", True), ("notarized", True),
                           ("signing", "Developer ID"), ("runtime_bundled", True),
                           ("models_bundled", True), ("llm_weights_download_on_first_launch", True),
                           ("source_dirty", 0)]:
            with self.subTest(key=key, value=value):
                original = self.provenance[key]
                self.provenance[key] = value; self.write_provenance()
                with self.assertRaises(ValueError): self.make()
                self.provenance[key] = original; self.write_provenance()

    def test_missing_provenance_claim_fails(self):
        del self.provenance["models_bundled"]; self.write_provenance()
        with self.assertRaises(ValueError): self.make()

    def test_invalid_commit_architecture_or_platform_fails(self):
        for override in [{"commit": "main"}, {"app_archs": ["x86_64"]}, {"host_arch": "unknown"},
                         {"app_archs": []}, {"macos_version": ""}, {"sdk_version": ""}]:
            with self.subTest(override=override), self.assertRaises(ValueError): self.make(**override)

    def test_unexpected_payloads_fail(self):
        for relative in ["Resources/Offline", "Resources/OfflineModels", "Frameworks/whisper.framework",
                         "Resources/Search"]:
            path = self.app / "Contents" / relative
            path.parent.mkdir(parents=True, exist_ok=True); path.touch()
            with self.subTest(path=relative), self.assertRaises(ValueError): self.make()
            path.unlink()

    def test_invalid_deployment_target_fails(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "unknown"}))
        with self.assertRaises(ValueError): self.make()

    def run_main(self, dirty="", workflow_sha=None):
        answers = {("git", "rev-parse", "HEAD"): self.commit,
                   ("git", "status", "--porcelain", "--untracked-files=all"): dirty,
                   ("uname", "-m"): "arm64", ("sw_vers", "-productVersion"): "15.7",
                   ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "26.4",
                   ("lipo", "-archs", str(self.binary.resolve())): "arm64"}
        original_cwd = Path.cwd()
        try:
            with mock.patch.object(receipt, "__file__", str(self.root / "scripts/write_candidate_receipt.py")), \
                 mock.patch.object(receipt, "output", side_effect=lambda *args: answers[args]), \
                 mock.patch.dict(os.environ, {"GITHUB_SHA": workflow_sha or self.commit}), \
                 mock.patch("builtins.print"):
                receipt.main()
        finally:
            os.chdir(original_cwd)

    def test_main_writes_machine_readable_receipt_without_modifying_dmg(self):
        before = self.dmg.read_bytes()
        self.run_main()
        result = json.loads((self.root / "build/Dot-candidate-receipt.json").read_text())
        self.assertEqual(result, self.make())
        self.assertEqual(self.dmg.read_bytes(), before)

    def test_main_resolves_symlinked_fixture_root_before_lipo(self):
        actual_root = self.root
        alias = actual_root / "fixture-alias"
        alias.symlink_to(actual_root, target_is_directory=True)
        self.root = alias
        self.binary = alias / "build/Dot.app/Contents/MacOS/Dot"
        self.run_main()
        result = json.loads((actual_root / "build/Dot-candidate-receipt.json").read_text())
        self.assertEqual(result["dmg"]["sha256"], hashlib.sha256(self.dmg.read_bytes()).hexdigest())
        self.assertEqual(result["commit"], self.commit)

    def test_main_rejects_dirty_checkout_and_workflow_commit_mismatch(self):
        for kwargs in [{"dirty": " M src/App.swift"}, {"workflow_sha": "b" * 40}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): self.run_main(**kwargs)
            self.assertFalse((self.root / "build/Dot-candidate-receipt.json").exists())

    def test_workflow_validates_receipt_after_successful_full_native_gate(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("      - name: Test, compile and package with zero warnings\n"
                      "        run: bash scripts/verify_macos.sh\n"
                      "      - name: Record development packaging receipt\n"
                      "        run: python3 -B scripts/write_candidate_receipt.py\n", workflow)
        self.assertNotIn("always()", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertIn("timeout-minutes: 20", workflow)
        self.assertIn("  cancel-in-progress: false", workflow)
        self.assertIn("  group: dot-native-${{ github.head_ref || github.ref_name }}", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        gates = (ROOT / "scripts/verify_macos.sh").read_text()
        for required in ["set -euo pipefail", "unittest discover -s Tests/Python",
                         "scripts/test_splash_sandbox.py",
                         "scripts/check_contracts.py", "swift test", "CODE_SIGNING_ALLOWED=NO test",
                         "CODE_SIGNING_ALLOWED=NO build", "bash build.sh",
                         "FAIL: warning detected", "codesign --verify --strict build/Dot.app"]:
            with self.subTest(gate=required): self.assertIn(required, gates)

    def test_workflow_keeps_diagnostics_without_automatic_artifact_delivery(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertNotIn("upload-artifact", workflow)
        self.assertNotIn("build/Dot.dmg", workflow)
        self.assertNotIn("build/Dot.app", workflow)
        gates = (ROOT / "scripts/verify_macos.sh").read_text()
        for log in ["python", "splash-sandbox", "swift", "test", "release", "package"]:
            with self.subTest(log=log): self.assertIn(f'2>&1 | tee "$LOGS/{log}.log"', gates)
        self.assertIn('print(text, end="")', (ROOT / "scripts/write_candidate_receipt.py").read_text())

    def test_complete_release_gate_remains_closed(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("Require complete native acceptance before distribution", release)
        self.assertIn("exit 1", release)
        self.assertNotIn("upload-artifact", release)
