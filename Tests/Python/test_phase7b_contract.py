"""Phase 7b Gatekeeper contract.

These are source-level guardrails. The real install, quarantine, spctl and
60-second launch evidence is produced by .github/workflows/release.yml on a
macOS runner.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMAND = ("curl -fsSL https://github.com/Emin-dev/Dot/releases/latest/download/"
           "install-dot.sh | bash")


def read(relative):
    return (ROOT / relative).read_text()


class Phase7bContractTests(unittest.TestCase):
    def test_the_one_line_command_is_first_in_the_owner_docs(self):
        self.assertEqual(read("docs/TEST_TODAY.md").splitlines()[0], COMMAND)
        self.assertIn(COMMAND, read("README.md"))
        self.assertIn(COMMAND, read(".github/workflows/release.yml"))

    def test_installer_verifies_every_part_and_clears_quarantine(self):
        script = read("scripts/install-dot.sh")
        for required in (
            "curl -fsSL",
            "Dot.dmg.parts.sha256",
            "shasum -a 256 -c Dot.dmg.parts.sha256",
            "shasum -a 256 \"$DMG\"",
            "cat \"$part\" >> \"$DMG\"",
            "hdiutil attach",
            "hdiutil detach",
            "xattr -dr \"$ATTR\"",
            "codesign --verify --deep --strict",
            "open \"$APP\"",
            "PASS:",
            "FAIL:",
            "/Applications",
            "sudo",
        ):
            self.assertIn(required, script)
        self.assertIn("curl never adds quarantine", script)
        self.assertIn("idempotent", script)

    def test_local_build_script_uses_apple_development_with_adhoc_fallback(self):
        script = read("scripts/build-and-sign-on-mac.sh")
        self.assertIn("security find-identity -v -p codesigning", script)
        self.assertIn("Apple Development", script)
        self.assertIn('SIGN_IDENTITY="-"', script)
        self.assertIn("ad-hoc", script)
        self.assertIn("/Applications", script)
        self.assertIn('open "$APP"', script)

    def test_release_is_draft_until_three_acceptance_jobs_pass(self):
        workflow = read(".github/workflows/release.yml")
        for job in ("installer-one-liner:", "quarantine-install:", "spctl-codesign:"):
            self.assertIn(job, workflow)
        self.assertIn("needs: [installer-one-liner, quarantine-install, spctl-codesign]", workflow)
        self.assertIn("--draft", workflow)
        self.assertIn("gh release download", workflow)
        self.assertIn("--draft=false --latest", workflow)
        self.assertIn("spctl --assess -vv /Applications/Dot.app", workflow)
        self.assertIn("GITHUB_STEP_SUMMARY", workflow)
        self.assertIn("*rejected*", workflow)
        self.assertIn("DOT_TEST_QUARANTINE=1", workflow)
        self.assertIn("com.apple.quarantine", workflow)
        self.assertIn("install_acceptance_check.sh", workflow)
        self.assertIn("60", workflow)

    def test_readme_asset_puts_the_one_line_command_first(self):
        workflow = read(".github/workflows/release.yml")
        marker = "cat > release-assets/README.txt <<'EOF'\n"
        self.assertIn(marker, workflow)
        body = workflow.split(marker, 1)[1]
        first = body.splitlines()[0].strip()
        self.assertEqual(first, COMMAND)
        self.assertIn("Developer ID", body)
        self.assertIn("notarisation", body)


if __name__ == "__main__":
    unittest.main()
