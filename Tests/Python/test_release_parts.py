import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def run(*args):
    return subprocess.run([sys.executable, "-B", *map(str, args)],
                          cwd=ROOT, text=True, capture_output=True)


class ReleasePartsTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".tmp").mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="dot-parts-", dir=ROOT / ".tmp"))

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def test_split_and_join_round_trip(self):
        source = self.work / "Dot-all-in-one.dmg"
        source.write_bytes(b"dot-installer" * 5000)
        split = run(SCRIPTS / "split_release.py", source,
                    "--output", self.work / "parts", "--part-size", "8192")
        self.assertEqual(split.returncode, 0, split.stderr)
        manifest_path = self.work / "parts" / "Dot-all-in-one.dmg.parts.json"
        manifest = json.loads(manifest_path.read_text())
        self.assertEqual(manifest["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
        self.assertEqual(sum(p["bytes"] for p in manifest["parts"]), source.stat().st_size)
        self.assertTrue(all(p["bytes"] <= 8192 for p in manifest["parts"]))
        self.assertTrue(all(len(p["sha256"]) == 64 for p in manifest["parts"]))
        output = self.work / "joined.dmg"
        join = run(SCRIPTS / "join_release.py", manifest_path, "--output", output)
        self.assertEqual(join.returncode, 0, join.stderr)
        self.assertEqual(output.read_bytes(), source.read_bytes())

    def test_tampered_part_is_rejected(self):
        source = self.work / "file.bin"
        source.write_bytes(b"x" * 10000)
        self.assertEqual(run(SCRIPTS / "split_release.py", source,
                             "--output", self.work / "parts", "--part-size", "2048").returncode, 0)
        manifest_path = self.work / "parts" / "file.bin.parts.json"
        manifest = json.loads(manifest_path.read_text())
        part = self.work / "parts" / manifest["parts"][0]["name"]
        part.write_bytes(b"y" * part.stat().st_size)
        join = run(SCRIPTS / "join_release.py", manifest_path,
                   "--output", self.work / "joined.bin")
        self.assertNotEqual(join.returncode, 0)
        self.assertIn("SHA-256 mismatch", join.stderr)
        self.assertFalse((self.work / "joined.bin").exists())

    def _payload(self):
        models = self.work / "models" / "llm-target"
        models.mkdir(parents=True)
        data = b"qwen-weights" * 3000
        (models / "model.bin").write_bytes(data)
        manifest = {
            "schema_version": 1,
            "total_bytes": len(data),
            "files": [{
                "path": "llm-target/model.bin",
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }],
        }
        manifest_path = self.work / "bundled-models.json"
        manifest_path.write_text(json.dumps(manifest))
        return manifest_path, data

    def test_model_parts_builds_ready_plan(self):
        manifest_path, data = self._payload()
        result = run(SCRIPTS / "model_parts.py",
                     "--models", self.work / "models",
                     "--manifest", manifest_path,
                     "--output", self.work / "out",
                     "--part-size", "20000")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads((self.work / "out" / "model-parts.json").read_text())
        self.assertEqual(plan["schema_version"], 1)
        self.assertEqual(plan["status"], "ready")
        self.assertTrue(plan["base_url"].startswith(
            "https://github.com/Emin-dev/Dot/releases/download/"))
        offsets = [part["offset"] for part in plan["parts"]]
        self.assertEqual(offsets, sorted(offsets))
        self.assertEqual(plan["parts"][0]["offset"], 0)
        self.assertEqual(sum(part["bytes"] for part in plan["parts"]), len(data))
        joined = b"".join((self.work / "out" / p["asset"]).read_bytes() for p in plan["parts"])
        self.assertEqual(joined, data)
        for part in plan["parts"]:
            self.assertEqual(hashlib.sha256((self.work / "out" / part["asset"]).read_bytes()).hexdigest(),
                             part["sha256"])

    def _manifest(self, **overrides):
        data = b"part-data"
        manifest = {
            "schema_version": 1,
            "output": "joined.bin",
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "parts": [{
                "name": "part000",
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "url": None,
            }],
        }
        manifest.update(overrides)
        path = self.work / "parts" / "release.parts.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(manifest))
        return path, data

    def test_join_rejects_path_traversal_in_part_name(self):
        manifest_path, _ = self._manifest()
        manifest = json.loads(manifest_path.read_text())
        manifest["parts"][0]["name"] = "../escape"
        manifest_path.write_text(json.dumps(manifest))
        result = run(SCRIPTS / "join_release.py", manifest_path,
                     "--output", self.work / "joined.bin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe file name", result.stderr)

    def test_join_rejects_a_foreign_part_url(self):
        manifest_path, _ = self._manifest()
        manifest = json.loads(manifest_path.read_text())
        manifest["parts"][0]["url"] = "https://example.com/part000"
        manifest_path.write_text(json.dumps(manifest))
        result = run(SCRIPTS / "join_release.py", manifest_path, "--download",
                     "--output", self.work / "joined.bin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing a part URL", result.stderr)

    def test_join_rejects_manifest_output_path(self):
        manifest_path, _ = self._manifest(output="../escape.bin")
        result = run(SCRIPTS / "join_release.py", manifest_path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe file name", result.stderr)

    def test_model_parts_rejects_hash_mismatch(self):
        manifest_path, _ = self._payload()
        manifest = json.loads(manifest_path.read_text())
        manifest["files"][0]["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest))
        result = run(SCRIPTS / "model_parts.py",
                     "--models", self.work / "models",
                     "--manifest", manifest_path,
                     "--output", self.work / "out")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)


if __name__ == "__main__":
    unittest.main()
