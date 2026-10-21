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
        self.assertIn('policy.arm(now: ProcessInfo.processInfo.systemUptime)', approver)
        self.assertNotIn('forceNext', approver)
        policy = read('src/InteractionCore.swift')
        self.assertIn('public struct ForceOverridePolicy', policy)
        self.assertIn('strikes[action] = 0', policy)
        self.assertIn('forceExpiresAt = now + lifetime', policy)
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
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U\n"
            "eyJhbGciOiJub25lIn0.e30.\n"
            "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..aaaa.bbbb.cccc\n"
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
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                       "eyJhbGciOiJub25lIn0.e30.",
                       "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..aaaa.bbbb.cccc",
                       "dXNlcjpwYXNzd29yZA==", "wJalrXUtnFEMI", "shhh-do-not-upload",
                       "PGPKEYBODY"):
            self.assertNotIn(secret, result.stdout)
        self.assertIn("[REDACTED_PRIVATE_KEY]", result.stdout)
        self.assertIn("[REDACTED_JWT]", result.stdout)

    def test_swift_redactor_masks_jwts_like_the_shell_redactor(self):
        redactor = read('src/InteractionCore.swift')
        self.assertIn(r'\beyJ[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]*){2,4}(?![A-Za-z0-9_.-])', redactor)
        self.assertIn('[REDACTED_JWT]', redactor)

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



class Phase6ReviewContractTests(unittest.TestCase):
    """Source guardrails for the Phase 6 multi-model review fixes."""

    def test_proactive_fallback_returns_to_idle_before_speaking(self):
        source = read('src/ChatView.swift')
        fallback = source.split('DiagnosticChatLogger.record(role: "dot (proactive fallback)"', 1)[1]
        fallback = fallback.split('} else {', 1)[0]
        self.assertIn('self.phase = .idle', fallback)
        self.assertLess(fallback.index('self.phase = .idle'), fallback.index('self.speakDirect(tip)'))

    def test_direct_replies_cannot_overwrite_a_newer_turn(self):
        source = read('src/ChatView.swift')
        method = source.split('private func respondDirectly(', 1)[1]
        method = method.split('\n    }', 1)[0]
        self.assertIn('guard gate.accepts(id) else { return }', method)
        for marker in ('let expanded = (path as NSString).expandingTildeInPath',
                       'var removed = 0', 'var lines: [String] = []'):
            task = source.split(marker, 1)[0].rsplit('Task { [weak self] in', 1)[1]
            self.assertIn('self.gate.accepts(id)', task)

    def test_interpreters_are_treated_as_command_wrappers(self):
        source = read('src/InteractionCore.swift')
        wrappers = source.split('private static let wrapperExecutables', 1)[1].split(']', 1)[0]
        for name in ('python3', 'osascript', 'perl', 'ruby', 'node', 'env'):
            self.assertIn(f'"{name}"', wrappers)
        self.assertIn('private static let launcherExecutables', source)
        self.assertIn('launcherExecutables.contains(first)', source)
        self.assertIn('isAssignment(tokens[cursor])', source)

    def test_installer_clones_the_payload_before_fetching_voice_or_aux(self):
        script = read('scripts/install_local.sh')
        self.assertNotIn('It never downloads anything', script)
        clone = script.index('for item in Offline OfflineModels; do')
        voice = script.index('VOICE_DIR="$STAGE/Dot.app/Contents/Resources/Offline/Voice/model"')
        aux = script.index('AUX_DIR="$STAGE/Dot.app/Contents/Resources/OfflineModels/aux"')
        self.assertLess(clone, voice)
        self.assertLess(clone, aux)

    def test_publish_script_does_not_put_the_token_in_argv(self):
        script = read('scripts/publish_public_release.sh')
        self.assertNotIn('-H "Authorization: Bearer $TOKEN"', script)
        self.assertIn('curl -sS --config -', script)
        self.assertIn('header = "Authorization: Bearer %s"', script)

    def test_model_part_split_verifies_each_written_part(self):
        script = read('scripts/model_parts.py')
        self.assertIn('if sha256_file(destination) != part_digest.hexdigest():', script)
        self.assertIn('did not verify after writing', script)

    def test_joiner_refuses_ambiguous_manifest_sets(self):
        script = read('packaging/join-dot-dmg.command')
        self.assertIn('MANIFESTS=(*.parts.json)', script)
        self.assertIn('Multiple *.parts.json files are present', script)
        self.assertNotIn('| head -n 1', script)


if __name__ == '__main__':
    unittest.main()


class Phase6RealLaunchContractTests(unittest.TestCase):
    """The real-launch lane must refuse honestly, not bypass the gate."""

    def test_real_launch_workflow_is_dispatch_only_and_uses_the_real_bundle(self):
        workflow = read('.github/workflows/real-app-check.yml')
        self.assertIn('workflow_dispatch:', workflow)
        self.assertNotIn('pull_request:', workflow)
        self.assertNotIn('push:', workflow)
        self.assertIn('DONOR_SHA256', workflow)
        self.assertIn('scripts/package_default_release.sh', workflow)
        self.assertIn('scripts/real_app_launch_check.sh', workflow)
        self.assertIn('build/Dot.app', workflow)
        for bypass in ('DOT_SKIP_HARDWARE', 'DOT_BYPASS', 'forceLaunch', 'gateBypass'):
            self.assertNotIn(bypass, workflow)

    def test_refusal_is_logged_before_the_blocking_alert(self):
        source = read('src/InteractionCore.swift')
        gate = source.split('public static func verifyOnLaunch()', 1)[1]
        refused = gate.split('case .refuseImpossible(let plan):', 1)[1].split('case .proceed', 1)[0]
        self.assertIn('DiagnosticChatLogger.record', refused)
        self.assertLess(refused.index('DiagnosticChatLogger.record'), refused.index('makeAlert(from: plan).runModal()'))
        self.assertIn('Launch refused.', refused)

    def test_launch_script_asserts_the_exact_minimum_and_no_fallback_text(self):
        script = read('scripts/real_app_launch_check.sh')
        self.assertIn("Hardware Does Not Meet Dot's Minimum", script)
        self.assertIn('Dot needs Apple Silicon M5 Pro class or newer, 48 GB Unified Memory and macOS 27.0 or newer.', script)
        self.assertIn('The exact Qwen3.8 27B Q4 model runs locally and has no smaller fallback, so Dot cannot start on this Mac.', script)
        self.assertIn('Not met:', script)
        self.assertNotIn('--override', script)
