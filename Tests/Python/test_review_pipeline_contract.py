"""Review-pipeline static contracts for the Phase 5 fixes.

These are source-level guardrails; Swift and workflow execution stay in CI.
Each check names the promise it protects, so a regression fails here first.
"""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
read = lambda p: (ROOT / p).read_text()


class ReviewPipelineContractTests(unittest.TestCase):
    def test_default_dmg_safety_approver_checks_downloaded_root(self):
        source = read('src/SafetyApprover.swift')
        self.assertIn('OfflinePreparation.shared.root', source)
        self.assertIn('OfflineModels', source)
        self.assertIn('aux/gemma-3-4b-it-Q4_K_M.gguf', source)
        self.assertIn('await modelURL()', source)

    def test_uploader_masks_bytes_at_the_upload_boundary(self):
        self.assertIn('LogRedaction.masked(raw)', read('src/DotLogSync.swift'))
        self.assertIn('public static func masked(_ data: Data) -> Data',
                      read('src/InteractionCore.swift'))

    def test_release_never_clobbers_and_manual_runs_are_main_only(self):
        workflow = read('.github/workflows/release.yml')
        self.assertNotIn('--clobber', workflow)
        self.assertIn('refs/heads/main', workflow)
        self.assertIn('git merge-base --is-ancestor HEAD refs/remotes/origin/main', workflow)

    def test_provenance_reflects_pending_parts(self):
        script = read('scripts/package_default_release.sh')
        self.assertIn("parts.get('status') == 'ready'", script)
        self.assertIn("Emin-dev/Dot parts pending", script)
        self.assertIn("schema_version') == 1", script)
        self.assertIn("releases/download/{tag}/", script)

    def test_manual_override_requires_three_refusals(self):
        approver = read('src/SafetyApprover.swift')
        self.assertIn('func armForce() -> Bool', approver)
        self.assertIn('consumeForce(for action: String)', approver)
        self.assertIn('strikes[action] = 0', approver)
        self.assertNotIn('forceNext', approver)
        self.assertIn('SafetyApprover.shared.armForce()', read('src/ChatView.swift'))

    def test_manual_log_script_refuses_non_log_branches(self):
        script = read('scripts/dot_log_sync.sh')
        self.assertIn('refusing to push logs to branch', script)
        self.assertIn('dot-logs|dot-*)', script)

    def test_manual_redactor_masks_multiline_pem_and_tokens(self):
        text = (
            "-----BEGIN RSA PRIVATE KEY-----\n"
            "MIIEowIBAAKCAQEA\n"
            "-----END RSA PRIVATE KEY-----\n"
            "Authorization: Bearer abc123def456\n"
            "sk-live-abcdefghijklmnop1234\n"
            "Authorization: Basic dXNlcjpwYXNzd29yZA==\n"
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI\n"
            '"client_secret": "shhh-do-not-upload"\n'
            "-----BEGIN PGP PRIVATE KEY BLOCK-----\n"
            "PGPKEYBODY\n"
            "-----END PGP PRIVATE KEY BLOCK-----\n"
        )
        result = subprocess.run(["perl", str(ROOT / "scripts/redact_log.pl")],
                                input=text, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for secret in ("MIIEowIBAAKCAQEA", "abc123def456", "sk-live-abcdefghijklmnop1234",
                       "dXNlcjpwYXNzd29yZA==", "wJalrXUtnFEMI", "shhh-do-not-upload",
                       "PGPKEYBODY"):
            self.assertNotIn(secret, result.stdout)
        self.assertIn("[REDACTED_PRIVATE_KEY]", result.stdout)

    def test_release_tag_must_match_the_built_commit(self):
        workflow = read('.github/workflows/release.yml')
        self.assertIn('git ls-remote --tags origin', workflow)
        self.assertIn('refs/remotes/origin/main', workflow)
        self.assertIn('case "$OUTPUT" in', read('packaging/join-dot-dmg.command'))
        self.assertIn('$GITHUB_SHA', workflow)
        self.assertIn('not the built commit', workflow)
        self.assertIn('--target "$GITHUB_SHA"', workflow)
        self.assertIn('git ls-remote --tags origin', workflow)
        self.assertIn('refs/remotes/origin/main', workflow)
        self.assertIn('case "$OUTPUT" in', read('packaging/join-dot-dmg.command'))

    def test_all_in_one_upload_does_not_clobber(self):
        self.assertNotIn('--clobber', read('scripts/package_all_in_one.sh'))

    def test_joiner_rejects_traversal_and_foreign_urls(self):
        joiner = read('scripts/join_release.py')
        self.assertIn('def safe_name(', joiner)
        self.assertIn('def safe_url(', joiner)
        self.assertIn('refusing a part URL', joiner)
        self.assertIn('for _ in range(8):', joiner)

    def test_part_download_is_cancellation_aware(self):
        source = read('src/OfflinePreparation.swift')
        self.assertIn('withTaskCancellationHandler', source)
        self.assertIn('PartDownloadCancellation', source)
        self.assertIn('cancellation.cancel()', source)


if __name__ == '__main__':
    unittest.main()
