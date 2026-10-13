from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import create_dmg


class DiskImageTests(unittest.TestCase):
    def test_modern_capability_selected_and_old_os_fallback_only(self):
        for version in ('26.4', '27.0.1'):
            self.assertEqual(create_dmg.select_backend(version, '--volumeName name --format format'), 'diskutil')
        self.assertEqual(create_dmg.select_backend('15.0', 'unrecognized verb'), 'hdiutil')
        with self.assertRaises(RuntimeError): create_dmg.select_backend('27.0.1', 'unrecognized verb')

    def test_fresh_image_atomically_replaces_and_preserves_previous(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'source'; source.mkdir()
            output = root / 'Dot.dmg'; output.write_bytes(b'previous')
            def run(command, **kwargs):
                self.assertEqual(command[:8], ['/usr/sbin/diskutil', 'image', 'create', 'from', '--volumeName', 'Dot', '--format', 'UDZO'])
                self.assertEqual(output.read_bytes(), b'previous')
                self.assertFalse(Path(command[-1]).exists())
                Path(command[-1]).write_bytes(b'new complete image')
            with patch.object(create_dmg.subprocess, 'run', side_effect=run):
                create_dmg.create_image(source, output, 'diskutil')
            self.assertEqual(output.read_bytes(), b'new complete image')
            backups = list(root.glob('Dot-previous-*/Dot.dmg'))
            self.assertEqual(len(backups), 1); self.assertEqual(backups[0].read_bytes(), b'previous')
            self.assertEqual(list(root.glob('.dot-dmg-*')), [])

    def test_failed_modern_creation_keeps_output_and_never_falls_back(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'source'; source.mkdir()
            output = root / 'Dot.dmg'; output.write_bytes(b'previous')
            with patch.object(create_dmg.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')) as run:
                with self.assertRaises(subprocess.CalledProcessError): create_dmg.create_image(source, output, 'diskutil')
            self.assertEqual(run.call_count, 1); self.assertEqual(output.read_bytes(), b'previous')
            self.assertEqual(list(root.glob('.dot-dmg-*')), [])

    def test_symlink_output_rejected_without_tool_execution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'source'; source.mkdir()
            target = root / 'saved'; target.write_bytes(b'private')
            output = root / 'Dot.dmg'; output.symlink_to(target)
            with patch.object(create_dmg.subprocess, 'run') as run:
                with self.assertRaises(ValueError): create_dmg.create_image(source, output, 'diskutil')
            run.assert_not_called(); self.assertEqual(target.read_bytes(), b'private')

    def test_old_backend_uses_fresh_path_without_overwrite_flag(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); source = root / 'source'; source.mkdir(); output = root / 'Dot.dmg'
            def run(command, **kwargs):
                self.assertEqual(command[:2], ['/usr/bin/hdiutil', 'create']); self.assertNotIn('-ov', command)
                Path(command[-1]).write_bytes(b'image')
            with patch.object(create_dmg.subprocess, 'run', side_effect=run): create_dmg.create_image(source, output, 'hdiutil')
            self.assertEqual(output.read_bytes(), b'image')
