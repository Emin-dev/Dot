"""Offline runtime contract.

After the first-launch model download, core conversation, speech, memory and
placement must not make an outbound request. The only network-capable surfaces
are the documented optional ones: GitHub log sync, Hugging Face model
provisioning, user-requested own-source/research reads, and the keyed research
providers. This is a source contract; native disconnected acceptance remains an
owner-run gate (docs/reference/offline-acceptance.md).
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'src'


def read(name):
    return (SRC / name).read_text()


def without_comment_lines(text):
    """Drop whole-line Swift comments but keep string literals (including URLs)."""
    return '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('//'))


def code(name):
    return without_comment_lines(read(name))


class OfflineRuntimeContractTests(unittest.TestCase):
    def test_comment_filter_preserves_url_string_literals(self):
        self.assertIn('https://example.test/x', without_comment_lines('let s = "https://example.test/x" // note\n'))
        self.assertNotIn('URLSession', without_comment_lines('/// URLSession is not used\nlet value = 1\n'))

    def test_speech_and_inference_are_local_and_loopback_only(self):
        for name in ('BionicVoice.swift', 'Speech.swift', 'WhisperRecognizer.swift'):
            self.assertNotIn('URLSession', code(name), name)
            self.assertIsNone(re.search(r'https?://', read(name)), name)
        self.assertNotIn('SFSpeechRecognizer', code('Speech.swift'))
        self.assertIn('dot-voice', read('BionicVoice.swift'))
        self.assertIn('https://127.0.0.1:', read('BundledSplash.swift'))
        self.assertIn('host == "127.0.0.1"', read('Engine.swift'))

    def test_model_files_are_reused_offline_and_always_rehashed(self):
        text = read('OfflinePreparation.swift')
        reuse = text.index('if let size = try? destination.resourceValues')
        download = text.index('try await downloadWholeFile')
        self.assertLess(reuse, download, 'size-complete files must skip the network')
        self.assertIn('Int64(size) == asset.bytes', text)
        self.assertIn('OfflinePayload.verifyHash(path, bytes: asset.bytes, expected: asset.sha256)', text)
        self.assertIn('ModelProvisioner.shared.ensureModels', text)
        # Every launch re-hashes after provisioning, and only then becomes ready.
        self.assertLess(text.index('ModelProvisioner.shared.ensureModels'),
                        text.index('try await OfflinePayload.verifyHash(path, bytes: asset.bytes, expected: asset.sha256)'))
        self.assertLess(text.index('try await self.verifyModels(token: token)'),
                        text.index('self.state = .ready'))

    def test_optional_log_sync_is_token_gated_and_silent(self):
        text = read('DotLogSync.swift')
        self.assertIn('guard let token = token() else {', text)
        self.assertIn('state.failed(remotePath: entry.remotePath, now: now)', text)
        self.assertIn('LogSyncPolicy.backoff', read('InteractionCore.swift'))
        for user_facing in ('NSAlert', 'issue =', 'presentError'):
            self.assertNotIn(user_facing, text)
        for marker in ('private func recordStartup()', 'private func syncNow()'):
            self.assertIn(marker, text)
        startup = text.split('private func recordStartup()')[1].split('private func syncNow()')[0]
        self.assertEqual(startup.count('DiagnosticChatLogger.record('), 1,
                         'uploader diagnostics belong in dot-sync.log, not the uploaded chat log')

    def test_no_cloud_stt_tts_or_llm_endpoint_is_referenced(self):
        combined = ''.join(read(path.name) for path in sorted(SRC.glob('*.swift')))
        for endpoint in ('api.openai.com', 'api.anthropic.com', 'api.elevenlabs.io',
                         'speech.googleapis.com', 'api.deepgram.com'):
            self.assertNotIn(endpoint, combined)
        self.assertNotIn('SFSpeechURLRecognitionRequest', combined)

    def test_only_documented_optional_surfaces_create_url_sessions(self):
        combined = ''.join(code(path.name) for path in sorted(SRC.glob('*.swift')))
        for api in ('NSURLConnection', 'NWConnection', 'CFStream', 'URLSessionWebSocketTask',
                    'webSocketTask'):
            self.assertNotIn(api, combined)
        sockets = {path.name for path in SRC.glob('*.swift') if re.search(r'\bsocket\(', code(path.name))}
        self.assertEqual(sockets, {
            'ResearchHTTPTransport.swift',  # bounded user-requested source reading
            'WebSearchProviders.swift',     # optional keyed research providers
        })
        sessions = {path.name for path in SRC.glob('*.swift') if 'URLSession' in code(path.name)}
        self.assertEqual(sessions, {
            'DotLogSync.swift',        # optional GitHub text-log sync
            'Engine.swift',            # loopback Splash inference, TLS-pinned
            'OfflinePreparation.swift',  # first-launch only, hash-verified
            'SourceReference.swift',   # user-requested own-source reading
            'WebSearchProviders.swift',  # optional keyed research providers
        })
        self.assertIn('https://api.github.com', read('DotLogSync.swift'))
        self.assertIn('https://huggingface.co/mlx-community/Qwen3.8-27B-4bit', read('OfflinePreparation.swift'))
        self.assertIn('https://raw.githubusercontent.com/Emin-dev/Dot/', read('SourceReference.swift'))
        self.assertIn('https://api.tavily.com/search', read('WebSearchProviders.swift'))


if __name__ == '__main__':
    unittest.main()
