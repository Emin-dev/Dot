"""Portable lock-digest regressions; no payload/native code is executed."""
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import ast
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import search_proxy_canary_support as support

spec = importlib.util.spec_from_file_location("proxy_transport_lock_test", ROOT / "Tests/Fixtures/search_proxy_transport_fixture.py")
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def canonical(lock):
    # Exact contract of scripts/search_payload.py's assembly-input-receipt writer.
    return hashlib.sha256(json.dumps(lock, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class ProbeReached(Exception):
    """Stop before any dependency import, socket, certificate or native work."""


class LockIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dot-proxy-lock-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.payload = self.root / "payload"
        (self.payload / "python/bin").mkdir(parents=True)
        (self.payload / "python/bin/python3").write_bytes(b"never execute this synthetic interpreter")
        (self.payload / "dot_search.py").write_bytes(b"never import this synthetic helper")
        (self.payload / "evidence").mkdir()
        self.lock = {"schema": 1, "runtime": {"version": "3.11.17", "sha256": "a" * 64},
                     "inputs": ["first", "second"], "label": "fixture ü"}
        self.lock_path = self.root / "lock.json"
        self.write_lock()
        self.receipt_path = self.payload / "evidence/assembly-input-receipt.json"
        self.write_receipt(canonical(self.lock))

    def write_lock(self, value=None, **kwargs):
        self.lock_path.write_text(json.dumps(self.lock if value is None else value, indent=2, **kwargs) + "\n")

    def write_receipt(self, lock_hash):
        receipt = {"schema": 1, "status": "unaccepted-static-assembly", "native_executed": False,
                   "lock_sha256": lock_hash, "files": [{"path": name, "sha256": support.sha_file(self.payload / name),
                   "size": (self.payload / name).stat().st_size} for name in ("dot_search.py", "python/bin/python3")]}
        self.receipt_path.write_text(json.dumps(receipt))
        self.receipt_hash = support.sha_file(self.receipt_path)

    def equivalent_bytes(self):
        return (json.dumps(self.lock, indent=2).encode() + b"\n",
                json.dumps(self.lock, sort_keys=True, separators=(",", ":")).encode(),
                json.dumps(dict(reversed(list(self.lock.items()))), indent=4, ensure_ascii=False).encode() + b"\r\n")

    def wrapper_preflight(self):
        source = (ROOT / "scripts/verify_search_proxy_native_fixture.sh").read_text()
        match = re.search(r"/usr/bin/python3 -I -S -B -c '(.*?)' ", source, re.S)
        self.assertIsNotNone(match, "extract only the exact hash-only OS-controller script")
        return subprocess.run([sys.executable, "-I", "-S", "-B", "-c", match.group(1), str(ROOT),
            str(self.payload), self.receipt_hash, str(self.lock_path)], capture_output=True, timeout=10)

    def fixture_preflight(self):
        args = SimpleNamespace(payload=self.payload, expected_receipt_sha256=self.receipt_hash,
                               report=self.root / "never-written.json", lock=self.lock_path)
        # Exercise the actual preflight, stopping before native dependency work.
        # This narrow instrumentation does not run or certify the native fixture.
        with mock.patch.object(transport, "require_native"), mock.patch.object(transport, "probe", side_effect=ProbeReached):
            try:
                transport.run(args)
            finally:
                self.assertFalse(args.report.exists())

    def test_wrapper_accepts_equivalent_json(self):
        for data in self.equivalent_bytes():
            with self.subTest(data=data):
                self.lock_path.write_bytes(data)
                result = self.wrapper_preflight()
                self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_fixture_accepts_equivalent_json(self):
        for data in self.equivalent_bytes():
            with self.subTest(data=data):
                self.lock_path.write_bytes(data)
                with self.assertRaises(ProbeReached):
                    self.fixture_preflight()

    def test_wrapper_rejects_semantic_mutation(self):
        self.lock["runtime"]["version"] = "changed"
        self.write_lock()
        self.assertNotEqual(self.wrapper_preflight().returncode, 0)

    def test_fixture_rejects_semantic_mutation_before_probe(self):
        self.lock["runtime"]["sha256"] = "b" * 64
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "lock"):
            self.fixture_preflight()

    def test_wrapper_rejects_raw_file_digest_as_assembly_identity(self):
        self.write_receipt(support.sha_file(self.lock_path))
        self.assertNotEqual(self.wrapper_preflight().returncode, 0)

    def test_fixture_rejects_raw_file_digest_as_assembly_identity(self):
        self.write_receipt(support.sha_file(self.lock_path))
        with self.assertRaisesRegex(ValueError, "lock"):
            self.fixture_preflight()

    def test_shared_verifier_preserves_both_digest_domains(self):
        raw_hashes = set()
        for data in self.equivalent_bytes():
            self.lock_path.write_bytes(data)
            lock, identity = support.verify_source_lock(self.lock_path, canonical(self.lock))
            self.assertEqual(lock, self.lock)
            self.assertEqual(identity["lock_sha256"], canonical(self.lock))
            self.assertEqual(identity["lock_file_sha256"], hashlib.sha256(data).hexdigest())
            raw_hashes.add(identity["lock_file_sha256"])
        self.assertEqual(len(raw_hashes), 3)

    def test_shared_verifier_rejects_semantic_mutations(self):
        for changed in ({**self.lock, "schema": 2}, {**self.lock, "inputs": ["second", "first"]},
                        {**self.lock, "runtime": {**self.lock["runtime"], "version": "changed"}}):
            with self.subTest(lock=changed):
                self.write_lock(changed)
                with self.assertRaisesRegex(ValueError, "lock"):
                    support.verify_source_lock(self.lock_path, canonical(self.lock))

    def test_shared_verifier_rejects_raw_digest_and_malformed_json(self):
        with self.assertRaisesRegex(ValueError, "lock"):
            support.verify_source_lock(self.lock_path, support.sha_file(self.lock_path))
        self.lock_path.write_bytes(b"{not JSON")
        with self.assertRaises(ValueError):
            support.verify_source_lock(self.lock_path, canonical(self.lock))

    def test_report_uses_verified_identity_and_rechecks_lock_bytes(self):
        # Inspect the real final verification/report statements without executing
        # any macOS-only or transport operation.
        tree = ast.parse((ROOT / "Tests/Fixtures/search_proxy_transport_fixture.py").read_text())
        run = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "run")
        start = next(index for index, node in enumerate(run.body) if isinstance(node, ast.Assign)
                     and any("final_identity" in ast.unparse(target) for target in node.targets))
        finish = next(index for index in range(start, len(run.body)) if isinstance(run.body[index], ast.With))
        code = compile(ast.Module(body=run.body[start:finish], type_ignores=[]), "<actual-report-statements>", "exec")
        _, identity = support.verify_payload(self.payload, self.receipt_hash)
        _, lock_identity = support.verify_source_lock(self.lock_path, identity["assembly_lock_sha256"])
        values = {**vars(transport), "verify_payload": support.verify_payload, "verify_source_lock": support.verify_source_lock,
                  "fixture_hashes": lambda root, paths: {}, "native_host_identity": lambda: {"test": "not-native"},
                  "payload": self.payload, "args": SimpleNamespace(expected_receipt_sha256=self.receipt_hash),
                  "identity": identity, "lock_path": self.lock_path, "lock_identity": lock_identity,
                  "sources": [], "host_identity": {}, "details": {}, "scenarios": []}
        exec(code, values)
        self.assertEqual(values["result"]["lock_sha256"], canonical(self.lock))
        self.assertEqual(values["result"]["lock_file_sha256"], support.sha_file(self.lock_path))
        self.assertFalse(values["result"]["production_acceptance"])
        self.lock_path.write_bytes(self.equivalent_bytes()[1])
        with self.assertRaisesRegex(transport.CanaryFailure, "lock"):
            exec(code, values)
        self.lock["schema"] = 2
        self.write_lock()
        with self.assertRaisesRegex(ValueError, "lock"):
            exec(code, values)


if __name__ == "__main__":
    unittest.main(verbosity=2)
