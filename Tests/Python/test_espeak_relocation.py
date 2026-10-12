"""Model-free startup-path regressions; actual eSpeak/PCM remains a Mac gate."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / 'Resources/Voice/bionic_helper.py'
SPEC = importlib.util.spec_from_file_location('relocation_helper', HELPER)
helper = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(helper)
SUFFIX = 'python/lib/python3.11/site-packages/espeakng_loader/espeak-ng-data'


class EspeakRelocationTests(unittest.TestCase):
    def make_data(self, root):
        data = root / SUFFIX; data.mkdir(parents=True)
        (data / 'phontab').write_bytes(b'inert fixture, not native phoneme data')
        return data.resolve(strict=True)

    def test_isolated_startup_handles_native_boundary_and_unicode_without_mutation(self):
        original_cwd = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory).resolve(strict=True)
            for length in (159, 160, 176, 240):
                with self.subTest(utf8_bytes=length):
                    prefix = 'Voice, İstanbul '
                    padding = length - len(os.fsencode(base / prefix / SUFFIX))
                    self.assertGreaterEqual(padding, 0)
                    root = base / (prefix + 'x' * padding)
                    data = self.make_data(root)
                    self.assertEqual(len(os.fsencode(data)), length)
                    before = hashlib.sha256((data / 'phontab').read_bytes()).hexdigest()
                    code = '''import importlib.util,json,os,pathlib,sys
spec=importlib.util.spec_from_file_location('helper',sys.argv[1])
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
os.environ['PHONEMIZER_ESPEAK_DATA_PATH']='/not/the/bundled/path'
os.environ['ESPEAK_DATA_PATH']='/not/the/bundled/path'
selected=h.configure_espeak_data(sys.argv[2])
print(json.dumps({'cwd':str(pathlib.Path.cwd()),'selected':str(selected),
 'native':os.environ['ESPEAK_DATA_PATH'],'wrapper_override':'PHONEMIZER_ESPEAK_DATA_PATH' in os.environ}))
'''
                    result = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(HELPER), str(root)],
                        capture_output=True, text=True, timeout=5, check=True)
                    value = json.loads(result.stdout)
                    self.assertEqual(value, {'cwd': str(data), 'selected': str(data),
                        'native': '.', 'wrapper_override': False})
                    self.assertEqual(result.stderr, '')
                    self.assertEqual(before, hashlib.sha256((data / 'phontab').read_bytes()).hexdigest())
                    self.assertEqual(list(data.iterdir()), [data / 'phontab'])
        self.assertEqual(Path.cwd(), original_cwd)

    def test_external_python_link_fails_before_environment_or_cwd_change(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); root = base / 'voice'; root.mkdir()
            external = base / 'external'; self.make_data(external)
            (root / 'python').symlink_to(external / 'python', target_is_directory=True)
            with patch.object(helper.os, 'chdir') as change, patch.dict(helper.os.environ, {}, clear=True):
                with self.assertRaisesRegex(RuntimeError, 'invalid_bundled_espeak_data'):
                    helper.configure_espeak_data(root)
                change.assert_not_called(); self.assertEqual(dict(helper.os.environ), {})

    def test_external_data_link_fails_before_cwd_change(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); root = base / 'voice'; data = self.make_data(root)
            outside = base / 'outside'; outside.mkdir(); (outside / 'phontab').write_bytes(b'fixture')
            (data / 'phontab').unlink(); data.rmdir(); data.symlink_to(outside, target_is_directory=True)
            with patch.object(helper.os, 'chdir') as change:
                with self.assertRaisesRegex(RuntimeError, 'invalid_bundled_espeak_data'):
                    helper.configure_espeak_data(root)
                change.assert_not_called()

    def test_linked_phoneme_file_fails_before_cwd_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = self.make_data(root)
            saved = data / 'saved'; (data / 'phontab').rename(saved)
            (data / 'phontab').symlink_to(saved.name)
            with patch.object(helper.os, 'chdir') as change:
                with self.assertRaisesRegex(RuntimeError, 'invalid_bundled_espeak_data'):
                    helper.configure_espeak_data(root)
                change.assert_not_called()

    def test_missing_phonemes_fail_before_cwd_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = self.make_data(root); (data / 'phontab').unlink()
            with patch.object(helper.os, 'chdir') as change:
                with self.assertRaises(FileNotFoundError): helper.configure_espeak_data(root)
                change.assert_not_called()

    def test_shared_process_threads_reject_cwd_setup(self):
        with patch.object(helper.threading, 'active_count', return_value=2), patch.object(helper.os, 'chdir') as change:
            with self.assertRaisesRegex(RuntimeError, 'espeak_setup_requires_single_thread'):
                helper.configure_espeak_data('/not/read')
            change.assert_not_called()


if __name__ == '__main__': unittest.main()
