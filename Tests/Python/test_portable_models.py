import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from copy_offline_models import copy_models


class PortableModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.source = self.root / 'source'; self.source.mkdir()
        (self.source / 'model').write_bytes(b'hello')
        self.manifest = self.root / 'plan.json'
        self.manifest.write_text(json.dumps({'schema_version': 1, 'total_bytes': 5, 'files': [
            {'path': 'model', 'bytes': 5, 'sha256': hashlib.sha256(b'hello').hexdigest()}]}))
        self.destination = self.root / 'copy'
    def test_copies_only_verified_data(self):
        (self.source / 'unrelated').write_text('do not copy')
        result = copy_models(self.source, self.destination, self.manifest)
        self.assertTrue(result['verified_after_copy'])
        self.assertEqual([x.name for x in self.destination.iterdir()], ['model'])
    def test_corruption_prevents_destination_creation(self):
        (self.source / 'model').write_bytes(b'HELLO')
        with self.assertRaises(ValueError): copy_models(self.source, self.destination, self.manifest)
        self.assertFalse(self.destination.exists())
    def test_symlink_not_portable_input(self):
        (self.source / 'model').unlink(); (self.root / 'external').write_bytes(b'hello')
        (self.source / 'model').symlink_to(self.root / 'external')
        with self.assertRaises(ValueError): copy_models(self.source, self.destination, self.manifest)
    def test_existing_destination_preserved(self):
        self.destination.mkdir(); (self.destination / 'owner').write_text('preserved')
        with self.assertRaises(ValueError): copy_models(self.source, self.destination, self.manifest)
        self.assertEqual((self.destination / 'owner').read_text(), 'preserved')
    def test_copy_time_symlink_swap_rejected_and_new_copy_removed(self):
        def swap(source, target, **kwargs):
            Path(target).symlink_to(source)
        with patch('copy_offline_models.shutil.copyfile', side_effect=swap):
            with self.assertRaises(ValueError): copy_models(self.source, self.destination, self.manifest)
        self.assertFalse(self.destination.exists())
        self.assertEqual((self.source / 'model').read_bytes(), b'hello')
