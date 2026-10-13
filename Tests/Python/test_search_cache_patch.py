"""Pinned source-delta and synthetic query/token disk canaries; no engine request."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((ROOT / "Resources/Search/searxng-transient-cache-patch.json").read_text())
loader = importlib.util.spec_from_file_location("patch_search_transient_cache", ROOT / "scripts/patch_search_transient_cache.py")
patcher = importlib.util.module_from_spec(loader)
loader.loader.exec_module(patcher)


class CachePatchTests(unittest.TestCase):
    def test_original_canary_writes_but_patched_function_never_accesses_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "query-token-canary"
            class Cache:
                def secret_hash(self, value):
                    return hashlib.sha256(value.encode()).hexdigest()
                def set(self, key, value, expire):
                    marker.write_text(f"{key}:{value}:{expire}")
            original = {"get_cache": Cache}
            exec(compile(SPEC["before"], "original_function_fixture", "exec"), original)
            original["set_vqd"]("synthetic-query-canary", "synthetic-token-canary", {"headers": {"User-Agent": "fixture"}})
            self.assertIn("synthetic-token-canary", marker.read_text())
            marker.unlink()
            def forbidden_cache():
                self.fail("patched page-one helper accessed persistent cache")
            patched = {"get_cache": forbidden_cache}
            exec(compile(SPEC["after"], "patched_function_fixture", "exec"), patched)
            for query in ("synthetic-query-canary", "界 😀", 123):
                patched["set_vqd"](query, "synthetic-token-canary", {"headers": {"User-Agent": "fixture"}})
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_unknown_source_and_wrong_patch_hash_are_rejected(self):
        with self.assertRaises(ValueError):
            patcher.patched_bytes(b"unexpected source", SPEC)
        synthetic = dict(SPEC)
        data = SPEC["before"].encode()
        synthetic["original_sha256"] = patcher.digest(data)
        with self.assertRaises(ValueError):
            patcher.patched_bytes(data, synthetic)

    def test_exact_delta_idempotency_and_atomic_file_patch_on_synthetic_source(self):
        synthetic = dict(SPEC)
        before, after = SPEC["before"].encode(), SPEC["after"].encode()
        synthetic["original_sha256"] = patcher.digest(before)
        synthetic["patched_sha256"] = patcher.digest(after)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / SPEC["path"]
            target.parent.mkdir(parents=True)
            target.write_bytes(before)
            self.assertEqual(patcher.patch_file(directory, synthetic), "patch_required")
            self.assertEqual(target.read_bytes(), before)
            self.assertEqual(patcher.patch_file(directory, synthetic, True), "patched")
            self.assertEqual(target.read_bytes(), after)
            self.assertEqual(patcher.patch_file(directory, synthetic, True), "already_patched")

    def test_patch_manifest_matches_runtime_gate(self):
        spec = importlib.util.spec_from_file_location("search_patch_gate_fixture", ROOT / "Resources/Search/dot_search.py")
        search = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(search)
        self.assertEqual(SPEC["patched_sha256"], search.DDG_TRANSIENT_SHA256)
        self.assertEqual(SPEC["upstream_revision"], search.SEARXNG_REVISION)

    @unittest.skipUnless(os.environ.get("DOT_SEARCH_SEARXNG_SOURCE"), "optional pinned SearXNG source not provided")
    def test_downloaded_full_pinned_file_matches_delta_and_hash(self):
        source = Path(os.environ["DOT_SEARCH_SEARXNG_SOURCE"])
        original = source.read_bytes()
        self.assertEqual(patcher.digest(original), SPEC["original_sha256"])
        patched = patcher.patched_bytes(original, SPEC)
        self.assertEqual(patcher.digest(patched), SPEC["patched_sha256"])
        self.assertEqual(patcher.patched_bytes(patched, SPEC), patched)
        self.assertIn(b"if len(query) >= 500:", patched)
        self.assertIn(b'if params["pageno"] == 1:', patched)


if __name__ == "__main__":
    unittest.main()
