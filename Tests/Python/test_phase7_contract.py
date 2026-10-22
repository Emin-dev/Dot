import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative):
    return (ROOT / relative).read_text()


class Phase7ContractTests(unittest.TestCase):
    def test_model_parts_workflow_is_owner_free(self):
        workflow = read(".github/workflows/model-parts.yml")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("permissions:\n  contents: write", workflow)
        self.assertIn("GH_TOKEN: ${{ github.token }}", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertIn("scripts/fetch_model_parts.py", workflow)
        self.assertIn("gh release upload", workflow)
        self.assertIn("--latest=false", workflow)
        self.assertIn('if [ -f .tmp/parts-published ]', workflow)
        self.assertNotIn('--json tagName,isLatest', workflow)

    def test_fetch_script_verifies_and_splits_below_two_gb(self):
        script = read("scripts/fetch_model_parts.py")
        self.assertIn("MAX_PART = 2_000_000_000", script)
        self.assertIn("DEFAULT_PART = 1_900_000_000", script)
        self.assertIn("SHA-256 mismatch for {relative}; refusing to publish parts", script)
        self.assertIn("sha256_file(destination) != part_digest.hexdigest()", script)
        self.assertIn("10c35caafbb80f7dc6a7a432cdd11af10a6d4818", script)
        self.assertIn("015e795645c74b1a0eeef3b570031fb62e769bc5", script)
        self.assertIn("d0976223747697cb51e056d85c532013931fe52e", script)
        self.assertIn("https://github.com/Emin-dev/Dot/releases/download/", script)

    def test_release_uses_parts_and_checks_quarantined_first_open(self):
        workflow = read(".github/workflows/release.yml")
        self.assertIn("model-parts.json", workflow)
        self.assertIn("Resources/model-parts.json", workflow)
        self.assertIn("scripts/quarantine_launch_check.sh build-public/Dot.dmg", workflow)
        self.assertIn("--notes-file release-assets/TEST_TODAY.md", workflow)
        script = read("scripts/quarantine_launch_check.sh")
        self.assertIn("com.apple.quarantine", script)
        self.assertIn("DOT_MINIMUM_ALIVE_SECONDS=60", script)
        self.assertIn("DOT_REQUIRE_QUARANTINE=1", script)

    def test_first_open_instructions_cover_both_supported_paths(self):
        for relative in ["docs/TEST_TODAY.md", "packaging/join-dot-dmg.command"]:
            text = read(relative)
            self.assertIn("quarantine", text.lower())
        self.assertIn("complete offline app", read("packaging/join-dot-dmg.command"))
        self.assertIn("~/Applications", read("packaging/join-dot-dmg.command"))
        today = read("docs/TEST_TODAY.md")
        self.assertIn("22.4 GB", today)
        self.assertIn("shasum -a 256 -c Dot.dmg.sha256", today)
        self.assertIn("force it", today)
        self.assertIn("Screen awareness", today)


if __name__ == "__main__":
    unittest.main()
