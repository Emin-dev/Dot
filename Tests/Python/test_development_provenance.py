"""Execute both real development provenance gates in a disposable Git fixture."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

class DevelopmentProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = (ROOT / 'build.sh').read_text()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.root / 'icon.png').write_bytes(b'original fixture')
        self.git('add', 'icon.png')
        self.git('commit', '-qm', 'fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True)

    def initial(self):
        header = self.script.split('INTENTS_BUILD=', 1)[0]
        return subprocess.check_output(['bash', '-c', header + '\nprintf "%s" "$SOURCE_DIRTY"', str(self.root / 'build.sh')], cwd=self.root, text=True)

    def final(self, initial='false'):
        body = self.script.split("<<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0]
        app = self.root / 'app'; (app / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
        subprocess.run(['python3', '-c', body, str(app), self.commit, initial], cwd=self.root, check=True)
        return json.loads((app / 'Contents/Resources/build-provenance.json').read_text())['source_dirty']

    def test_clean_icon_is_clean_at_both_gates(self):
        self.assertEqual(self.initial(), 'false')
        self.assertFalse(self.final())

    def test_only_tracked_icon_modified_is_dirty_at_both_gates(self):
        (self.root / 'icon.png').write_bytes(b'changed fixture')
        self.assertEqual(self.initial(), 'true')
        self.assertTrue(self.final())

    def test_icon_changed_during_build_is_dirty_in_final_receipt(self):
        before = self.initial(); self.assertEqual(before, 'false')
        (self.root / 'icon.png').write_bytes(b'changed after initial capture')
        self.assertTrue(self.final(before))

    def test_ignored_untracked_icon_is_dirty_at_both_gates(self):
        self.git('rm', '--cached', 'icon.png')
        (self.root / '.gitignore').write_text('icon.png\n')
        self.git('add', '.gitignore'); self.git('commit', '-qm', 'ignore fixture icon')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        self.assertEqual(self.initial(), 'true')
        self.assertTrue(self.final())
