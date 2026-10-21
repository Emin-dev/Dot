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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


def load_fetcher():
    spec = importlib.util.spec_from_file_location("dot_fetch_model_parts", SCRIPTS / "fetch_model_parts.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args):
    return subprocess.run([sys.executable, "-B", *map(str, args)],
                          cwd=ROOT, text=True, capture_output=True)


class SourceServer:
    def __init__(self, root):
        self.root = Path(root)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(self_path[0]), **kwargs)

            def log_message(self, *args):
                pass

        self_path = [self.root]
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


class ModelPartsFetchTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".tmp").mkdir(exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="dot-fetch-parts-", dir=ROOT / ".tmp"))
        self.source = self.work / "source"
        self.payload = {
            "llm-target/config.json": b'{"model":"qwen"}' * 700,
            "aux/safety.bin": b"dot-safety" * 1500,
        }
        files = []
        for relative, data in self.payload.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            files.append({
                "path": relative,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            })
        self.manifest = self.work / "bundled-models.json"
        self.manifest.write_text(json.dumps({
            "schema_version": 1,
            "total_bytes": sum(len(data) for data in self.payload.values()),
            "files": files,
        }))

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def fetch(self, *extra):
        output = self.work / "parts"
        with SourceServer(self.source) as root:
            result = run(SCRIPTS / "fetch_model_parts.py",
                         "--manifest", self.manifest, "--output", output,
                         "--part-size", "4096", "--source-root", root, *extra)
        return result, output

    def test_streams_parts_and_writes_a_ready_plan(self):
        result, output = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads((output / "model-parts.json").read_text())
        self.assertEqual(plan["schema_version"], 1)
        self.assertEqual(plan["status"], "ready")
        self.assertEqual(plan["release_tag"], "model-parts-v1")
        self.assertTrue(plan["base_url"].startswith(
            "https://github.com/Emin-dev/Dot/releases/download/model-parts-v1/"))
        for relative, data in self.payload.items():
            parts = sorted((p for p in plan["parts"] if p["file"] == relative),
                           key=lambda part: part["offset"])
            self.assertTrue(parts)
            offset = 0
            joined = b""
            for part in parts:
                self.assertEqual(part["offset"], offset)
                self.assertLessEqual(part["bytes"], 2_000_000_000)
                blob = (output / part["asset"]).read_bytes()
                self.assertEqual(hashlib.sha256(blob).hexdigest(), part["sha256"])
                joined += blob
                offset += part["bytes"]
            self.assertEqual(offset, len(data))
            self.assertEqual(joined, data)
        digest = hashlib.sha256((output / "model-parts.json").read_bytes()).hexdigest()
        self.assertIn(digest, (output / "model-parts.json.sha256").read_text())
        self.assertEqual(len((output / "model-parts.sha256").read_text().splitlines()), len(plan["parts"]))

    def test_rejects_a_payload_that_does_not_match_the_pinned_hash(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["files"][0]["sha256"] = "0" * 64
        self.manifest.write_text(json.dumps(manifest))
        result, output = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse((output / "model-parts.json").exists())
        self.assertFalse(list(output.glob("*.part*")))

    def test_rejects_an_unknown_prefix(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["files"][0]["path"] = "other/config.json"
        self.manifest.write_text(json.dumps(manifest))
        result, _ = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown model path prefix", result.stderr)

    def test_remote_url_maps_the_three_pinned_repositories(self):
        module = load_fetcher()
        target = module.remote_url("llm-target/model.safetensors")
        draft = module.remote_url("llm-draft/model.safetensors")
        safety = module.remote_url("aux/model.gguf")
        self.assertIn("mlx-community/Qwen3.8-27B-4bit/resolve/10c35caa", target)
        self.assertIn("incoai/Qwen3.8-27B-DFlash2/resolve/015e7956", draft)
        self.assertIn("ggml-org/gemma-3-4b-it-GGUF/resolve/d0976223", safety)
        with self.assertRaises(SystemExit):
            module.remote_url("llm-target/../escape")


if __name__ == "__main__":
    unittest.main()
