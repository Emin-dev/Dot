import hashlib
import http.server
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def load_joiner():
    spec = importlib.util.spec_from_file_location("dot_join_release", SCRIPTS / "join_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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

    def test_split_refuses_to_overwrite_existing_parts(self):
        source = self.work / "file.bin"
        source.write_bytes(b"x" * 5000)
        output = self.work / "parts"
        self.assertEqual(run(SCRIPTS / "split_release.py", source,
                             "--output", output, "--part-size", "2048").returncode, 0)
        again = run(SCRIPTS / "split_release.py", source,
                    "--output", output, "--part-size", "2048")
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("refusing to overwrite existing part output", again.stderr)
        forced = run(SCRIPTS / "split_release.py", source,
                     "--output", output, "--part-size", "2048", "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)

    def test_forced_split_replaces_the_whole_part_set(self):
        source = self.work / "file.bin"
        source.write_bytes(b"x" * 5000)
        output = self.work / "parts"
        self.assertEqual(run(SCRIPTS / "split_release.py", source,
                             "--output", output, "--part-size", "1024").returncode, 0)
        self.assertTrue((output / "file.bin.part004").is_file())
        forced = run(SCRIPTS / "split_release.py", source,
                     "--output", output, "--part-size", "4096", "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(sorted(path.name for path in output.iterdir()),
                         ["file.bin.part000", "file.bin.part001",
                          "file.bin.parts.json", "file.bin.parts.sha256"],
                         "A forced re-split must not leave parts from the old set "
                         "for package_all_in_one.sh to upload")

    def test_forced_split_removes_parts_from_a_renamed_dmg(self):
        output = self.work / "parts"
        old = self.work / "Dot-1.0.dmg"
        old.write_bytes(b"x" * 5000)
        self.assertEqual(run(SCRIPTS / "split_release.py", old,
                             "--output", output, "--part-size", "1024").returncode, 0)
        new = self.work / "Dot-1.1.dmg"
        new.write_bytes(b"y" * 5000)
        forced = run(SCRIPTS / "split_release.py", new,
                     "--output", output, "--part-size", "4096", "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        names = sorted(path.name for path in output.iterdir())
        self.assertTrue(all(name.startswith("Dot-1.1.dmg") for name in names), names)
        self.assertNotIn("Dot-1.0.dmg.parts.json", names)

    def test_join_refuses_to_replace_an_existing_output(self):
        source = self.work / "file.bin"
        source.write_bytes(b"x" * 5000)
        self.assertEqual(run(SCRIPTS / "split_release.py", source,
                             "--output", self.work / "parts", "--part-size", "2048").returncode, 0)
        manifest_path = self.work / "parts" / "file.bin.parts.json"
        output = self.work / "joined.bin"
        output.write_bytes(b"keep me")
        refused = run(SCRIPTS / "join_release.py", manifest_path, "--output", output)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("refusing to replace existing output", refused.stderr)
        self.assertEqual(output.read_bytes(), b"keep me")
        forced = run(SCRIPTS / "join_release.py", manifest_path, "--output", output, "--force")
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertEqual(output.read_bytes(), source.read_bytes())

    def test_redirects_may_not_leave_github_release_hosting(self):
        joiner = load_joiner()
        handler = joiner.SafeRedirectHandler()
        request = urllib.request.Request(
            "https://github.com/Emin-dev/Dot/releases/download/v1/part000")
        with self.assertRaises(urllib.error.HTTPError):
            handler.redirect_request(request, None, 302, "Found", {},
                                     "https://example.com/part000")
        with self.assertRaises(urllib.error.HTTPError):
            handler.redirect_request(request, None, 302, "Found", {},
                                     "http://objects.githubusercontent.com/part000")
        allowed = handler.redirect_request(
            request, None, 302, "Found", {},
            "https://objects.githubusercontent.com/github-production-release-asset/part000")
        self.assertIsNotNone(allowed)

    def test_download_installs_the_redirect_guard(self):
        class RedirectAway(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/release/"):
                    self.send_response(302)
                    self.send_header("Location", "/payload")
                    self.end_headers()
                else:
                    body = b"leaked-payload!!"
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), RedirectAway)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            joiner = load_joiner()
            destination = self.work / "downloaded.part"
            with self.assertRaises(urllib.error.HTTPError) as caught:
                joiner.download(f"http://127.0.0.1:{server.server_port}/release/part000",
                                destination, 16)
            self.assertIn("refusing redirect outside GitHub release hosting",
                          str(caught.exception))
            self.assertFalse(destination.exists(),
                             "A refused redirect must not write the payload")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

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

    def test_join_refuses_existing_output_before_any_download(self):
        manifest_path, _ = self._manifest()
        manifest = json.loads(manifest_path.read_text())
        manifest["parts"][0]["url"] = (
            "https://github.com/Emin-dev/Dot/releases/download/all-in-one-v1/part000")
        manifest_path.write_text(json.dumps(manifest))
        output = self.work / "joined.bin"
        output.write_bytes(b"keep me")
        joiner = load_joiner()
        calls = []
        original = joiner.download
        joiner.download = lambda *args, **kwargs: calls.append(args)
        try:
            with self.assertRaises(SystemExit) as refused:
                joiner.join(manifest_path, output, True)
        finally:
            joiner.download = original
        self.assertIn("refusing to replace existing output", str(refused.exception))
        self.assertEqual(calls, [], "the existing-output check must run before any download")
        self.assertEqual(output.read_bytes(), b"keep me")

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
